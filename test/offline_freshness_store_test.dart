import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart'
    show QueryExecutor, QueryExecutorUser, OpeningDetails;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:getbible/data/database/local_database.dart';
import 'package:getbible/domain/models/offline_resource.dart';

OfflineResourceDescriptor resource({String host = 'api.getbible.net'}) =>
    OfflineResourceDescriptor(
      kind: OfflineResourceKind.bible,
      id: 'kjv',
      title: 'King James Version',
      sourceUri: Uri.parse('https://$host/v3'),
      revision: 'verified',
    );

Future<void> activate(LocalDatabase db, String generation) async {
  final store = SqlOfflineResourceStore(db);
  await store.begin(resource(), generation, quotaBytes: 10000);
  await store.writeDocument(
    generation,
    'chapter',
    '{"original":true}',
    quotaBytes: 10000,
  );
  await store.activate(generation);
}

void main() {
  test(
    'freshness and exclusions persist across restart with exact source scopes',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'offline-freshness-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/store.sqlite');
      var db = await LocalDatabase.fromExecutor(NativeDatabase(file));
      await activate(db, 'first');
      var store = SqlOfflineFreshnessStore(db);
      final date = DateTime.utc(2026, 10, 10);
      final key = resource().key;
      await store.recordSuccess(key, 'first', date);
      await store.recordAttempt(
        key,
        date.add(const Duration(days: 30)),
        date.add(const Duration(days: 31)),
      );
      await store.setExcluded(key, true);
      await store.saveAutomaticResources(
        resource().kind,
        resource().sourceUri,
        [resource()],
      );
      await db.close();
      db = await LocalDatabase.fromExecutor(NativeDatabase(file));
      addTearDown(db.close);
      store = SqlOfflineFreshnessStore(db);
      final value = (await store.read(key))!;
      expect(value.checkedAt, date);
      expect(value.checkedGeneration, 'first');
      expect(value.lastAttemptAt, date.add(const Duration(days: 30)));
      expect(value.retryAfter, date.add(const Duration(days: 31)));
      expect(await store.read(resource(host: 'another.example').key), isNull);
      expect(await store.readExcludedKeys(), {key});
      expect((await store.readAutomaticResources()).single.key, key);
      await store.clear();
      expect(await store.read(key), isNull);
      expect(await store.readExcludedKeys(), {key});
      expect((await store.readAutomaticResources()).single.key, key);
      expect(
        (await SqlOfflineResourceStore(db).listInstalled()).single.generation,
        'first',
      );
    },
  );

  test(
    'successful checks require the same active generation and reset retry state',
    () async {
      final db = await LocalDatabase.memory();
      addTearDown(db.close);
      final store = SqlOfflineFreshnessStore(db);
      final date = DateTime.utc(2026, 10, 10);
      final key = resource().key;
      await activate(db, 'first');
      await store.recordAttempt(key, date, date.add(const Duration(hours: 1)));
      await store.recordSuccess(key, 'first', date);
      expect((await store.read(key))!.retryAfter, isNull);
      await activate(db, 'second');
      await store.recordSuccess(
        key,
        'first',
        date.add(const Duration(days: 30)),
      );
      expect((await store.read(key))!.checkedAt, date);
      await store.recordSuccess(
        key,
        'second',
        date.add(const Duration(days: 30)),
      );
      expect((await store.read(key))!.checkedGeneration, 'second');
      await SqlOfflineResourceStore(db).remove(key);
      await store.remove(key);
      await store.recordSuccess(
        key,
        'second',
        date.add(const Duration(days: 31)),
      );
      expect(await store.read(key), isNull);
    },
  );

  test(
    'catalogue plans replace only their scope and validate before writes',
    () async {
      final db = await LocalDatabase.memory();
      addTearDown(db.close);
      final store = SqlOfflineFreshnessStore(db);
      final first = resource();
      final other = resource(host: 'another.example');
      await store.saveAutomaticResources(first.kind, first.sourceUri, [first]);
      await store.saveAutomaticResources(other.kind, other.sourceUri, [other]);
      expect(
        () =>
            store.saveAutomaticResources(first.kind, first.sourceUri, [other]),
        throwsArgumentError,
      );
      expect(await store.readAutomaticResources(), hasLength(2));
      await store.saveAutomaticResources(first.kind, first.sourceUri, []);
      expect((await store.readAutomaticResources()).single.key, other.key);
      const key = 'catalogue|https://dictionaries.getbible.net/v1|dictionary';
      final date = DateTime.utc(2026);
      await store.recordAttempt(key, date, date.add(const Duration(hours: 1)));
      await store.recordCatalogueSuccess(key, date);
      expect((await store.read(key))!.checkedAt, date);
      expect((await store.read(key))!.retryAfter, isNull);
    },
  );

  test(
    'schema five upgrade preserves installed generation and private records',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'offline-schema5-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/store.sqlite');
      final old = NativeDatabase(file);
      await old.ensureOpen(_VersionFive());
      await old.close();
      final db = await LocalDatabase.fromExecutor(NativeDatabase(file));
      addTearDown(db.close);
      expect(localDatabaseSchemaVersion, 6);
      final installed = SqlOfflineResourceStore(db);
      expect((await installed.listInstalled()).single.generation, 'released');
      expect(
        await installed.readDocument(resource().key, 'chapter'),
        '{"original":true}',
      );
      expect((await db.getNotes()).single.text, 'Private note unchanged');
      expect(jsonDecode((await db.readSetting('position'))!), {'verse': 3});
      final freshness = SqlOfflineFreshnessStore(db);
      expect(await freshness.read(resource().key), isNull);
      await freshness.recordSuccess(
        resource().key,
        'released',
        DateTime.utc(2026),
      );
      expect(
        (await freshness.read(resource().key))!.checkedGeneration,
        'released',
      );
    },
  );

  test(
    'failed schema six upgrade rolls back its new tables and version',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'offline-schema6-rollback-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/store.sqlite');
      final old = NativeDatabase(file);
      await old.ensureOpen(_VersionFive());
      // Simulate failure midway through the additive migration. The first new
      // table must roll back with the version, without affecting released data.
      await old.runCustom('CREATE TABLE offline_exclusions(collision TEXT)');
      await old.close();
      await expectLater(
        LocalDatabase.fromExecutor(NativeDatabase(file)),
        throwsA(
          predicate(
            (Object error) => error.toString().contains('offline_exclusions'),
          ),
        ),
      );
      final reopened = NativeDatabase(file);
      addTearDown(reopened.close);
      await reopened.ensureOpen(_InspectVersionFive());
      expect(
        (await reopened.runSelect(
          'PRAGMA user_version',
          [],
        )).single['user_version'],
        5,
      );
      expect(
        await reopened.runSelect(
          "SELECT name FROM sqlite_master WHERE name='offline_freshness'",
          [],
        ),
        isEmpty,
      );
      expect(
        (await reopened.runSelect('SELECT text FROM notes', [])).single['text'],
        'Private note unchanged',
      );
      expect(
        (await reopened.runSelect(
          'SELECT generation FROM offline_active',
          [],
        )).single['generation'],
        'released',
      );
    },
  );
}

final class _InspectVersionFive extends QueryExecutorUser {
  @override
  int get schemaVersion => 5;
  @override
  Future<void> beforeOpen(QueryExecutor executor, OpeningDetails details) =>
      executor.ensureOpen(this);
}

final class _VersionFive extends QueryExecutorUser {
  @override
  int get schemaVersion => 5;
  @override
  Future<void> beforeOpen(
    QueryExecutor executor,
    OpeningDetails details,
  ) async {
    await executor.ensureOpen(this);
    for (final statement in (await File(
      'test/fixtures/database_schema_v5.sql',
    ).readAsString()).split(';')) {
      if (statement.trim().isNotEmpty) await executor.runCustom(statement);
    }
    await executor.runCustom(
      'INSERT INTO offline_generations VALUES(?,?,?,?,?)',
      ['released', resource().key, jsonEncode(resource().toJson()), 17, 1],
    );
    await executor.runCustom('INSERT INTO offline_active VALUES(?,?,?)', [
      resource().key,
      'released',
      1,
    ]);
    await executor.runCustom('INSERT INTO offline_documents VALUES(?,?,?,?)', [
      'released',
      'chapter',
      '{"original":true}',
      17,
    ]);
    await executor.runCustom('INSERT INTO notes VALUES(?,?,?,?,?,?,?,?,?,?)', [
      'note',
      '1:1:1',
      'kjv',
      1,
      1,
      1,
      'Genesis 1:1',
      'Private note unchanged',
      1,
      2,
    ]);
    await executor.runCustom('INSERT INTO settings VALUES(?,?,?)', [
      'position',
      '{"verse":3}',
      1,
    ]);
  }
}
