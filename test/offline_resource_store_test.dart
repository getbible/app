import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart'
    show QueryExecutor, QueryExecutorUser, OpeningDetails;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:getbible_live/application/offline_controller.dart';
import 'package:getbible_live/core/request_cancellation.dart';
import 'package:getbible_live/data/database/local_database.dart';
import 'package:getbible_live/domain/models/offline_resource.dart';
import 'package:getbible_live/domain/repositories/offline_resource_repository.dart';

final _source = Uri.parse('https://example.test/v3');
OfflineResourceDescriptor _resource({String revision = 'one', Uri? source}) =>
    OfflineResourceDescriptor(
      kind: OfflineResourceKind.bible,
      id: 'test',
      title: 'Test Bible',
      sourceUri: source ?? _source,
      revision: revision,
    );

void main() {
  test(
    'close drains cancellation and rejects new downloads until resume',
    () async {
      final database = await LocalDatabase.memory();
      addTearDown(database.close);
      final store = SqlOfflineResourceStore(database);
      final started = Completer<void>();
      var requests = 0;
      final controller = OfflineController(
        store: store,
        installers: [
          _Installer((resource, sink, cancellation) async {
            requests++;
            await sink.writeDocument('chapter', '{"saved":true}');
            if (requests == 1) {
              started.complete();
              await cancellation.bind(Completer<void>().future);
            }
          }),
        ],
      );
      addTearDown(controller.dispose);
      final pending = controller.install(_resource());
      await started.future;
      final closing = controller.close();
      await controller.install(_resource(revision: 'blocked'));
      await closing;
      await pending;
      expect(requests, 1);
      expect(await store.usedBytes(), 0);
      expect(
        (await store.listAttempts()).single.state,
        OfflineAttemptState.cancelled,
      );
      controller.resume();
      await controller.install(_resource(revision: 'resumed'));
      expect(requests, 2);
      expect((await store.listInstalled()).single.resource.revision, 'resumed');
    },
  );

  test(
    'staging is invisible and activation replaces all documents atomically',
    () async {
      final database = await LocalDatabase.memory();
      addTearDown(database.close);
      final store = SqlOfflineResourceStore(database);
      await store.begin(_resource(), 'first', quotaBytes: 10000);
      await store.writeDocument(
        'first',
        'chapter:1',
        '{"text":"old"}',
        quotaBytes: 10000,
      );
      expect(await store.readDocument(_resource().key, 'chapter:1'), isNull);
      await store.activate('first');
      await store.begin(
        _resource(revision: 'two'),
        'second',
        quotaBytes: 10000,
      );
      await store.writeDocument(
        'second',
        'chapter:2',
        '{"text":"new"}',
        quotaBytes: 10000,
      );
      expect(
        await store.readDocument(_resource().key, 'chapter:1'),
        contains('old'),
      );
      expect(await store.readDocument(_resource().key, 'chapter:2'), isNull);
      await store.activate('second');
      expect(await store.readDocument(_resource().key, 'chapter:1'), isNull);
      expect(
        await store.readDocument(_resource().key, 'chapter:2'),
        contains('new'),
      );
      expect(
        await store.readDocument(
          _resource().key,
          'chapter:2',
          generation: 'first',
        ),
        isNull,
      );
      expect((await store.listInstalled()).single.resource.revision, 'two');
    },
  );

  test(
    'source scopes never reuse installations from a different origin',
    () async {
      final database = await LocalDatabase.memory();
      addTearDown(database.close);
      final store = SqlOfflineResourceStore(database);
      await _activate(store);
      expect(
        await store.find(OfflineResourceKind.bible, 'test', _source),
        isNotNull,
      );
      expect(
        await store.find(
          OfflineResourceKind.bible,
          'test',
          Uri.parse('https://other.test/v3'),
        ),
        isNull,
      );
      expect(
        await store.find(
          OfflineResourceKind.bible,
          'test',
          Uri.parse('https://example.test/v2'),
        ),
        isNull,
      );
    },
  );

  test(
    'exact hash mismatch and failed update retain last known good snapshot',
    () async {
      final database = await LocalDatabase.memory();
      addTearDown(database.close);
      final store = SqlOfflineResourceStore(database);
      await _activate(store);
      final controller = OfflineController(
        store: store,
        installers: [
          _Installer((resource, sink, cancellation) async {
            await sink.writeDocument(
              'new',
              '{"bad":"payload"}',
              sha256: '0' * 64,
            );
          }),
        ],
      );
      addTearDown(controller.dispose);
      await controller.install(_resource(revision: 'two'));
      expect(controller.error, contains('integrity'));
      expect((await store.listInstalled()).single.generation, 'first');
      expect(
        await store.readDocument(_resource().key, 'chapter'),
        contains('saved'),
      );
      expect(
        (await store.listAttempts()).single.state,
        OfflineAttemptState.failed,
      );
      expect(await store.usedBytes(), utf8.encode('{"saved":true}').length);
    },
  );

  test(
    'bounded quota failure rolls back staged data and preserves private notes',
    () async {
      final database = await LocalDatabase.memory();
      addTearDown(database.close);
      await database.writeSetting('private_test', {'text': 'personal'});
      final store = SqlOfflineResourceStore(database);
      await _activate(store);
      final controller = OfflineController(
        store: store,
        quotaBytes: 30,
        installers: [
          _Installer((resource, sink, cancellation) async {
            await sink.writeDocument('first', '{"one":1}');
            await sink.writeDocument(
              'second',
              '{"long":"payload exceeding quota"}',
            );
          }),
        ],
      );
      addTearDown(controller.dispose);
      await controller.install(_resource(revision: 'two'));
      expect(controller.error, contains('budget'));
      expect((await store.listInstalled()).single.generation, 'first');
      expect(await store.usedBytes(), 14);
      expect(jsonDecode((await database.readSetting('private_test'))!), {
        'text': 'personal',
      });
    },
  );

  test(
    'cancellation is durable, invisible and retry creates a complete snapshot',
    () async {
      final database = await LocalDatabase.memory();
      addTearDown(database.close);
      final store = SqlOfflineResourceStore(database);
      var cancel = true;
      final controller = OfflineController(
        store: store,
        installers: [
          _Installer((resource, sink, cancellation) async {
            await sink.writeDocument('chapter', '{"saved":true}');
            if (cancel) cancellation.cancel();
            cancellation.throwIfCancelled();
          }),
        ],
      );
      addTearDown(controller.dispose);
      await controller.install(_resource());
      expect(await store.listInstalled(), isEmpty);
      expect(await store.usedBytes(), 0);
      expect(
        (await store.listAttempts()).single.state,
        OfflineAttemptState.cancelled,
      );
      cancel = false;
      await controller.install(_resource());
      expect(await store.listInstalled(), hasLength(1));
      expect(await store.listAttempts(), isEmpty);
    },
  );

  test(
    'restart recovers expired download while protecting another live window',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'getbible-offline-restart-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/store.sqlite');
      var now = DateTime.utc(2026);
      var database = await LocalDatabase.fromExecutor(NativeDatabase(file));
      var store = SqlOfflineResourceStore(database, clock: () => now);
      await _activate(store);
      await store.begin(
        _resource(revision: 'two'),
        'crashed',
        quotaBytes: 10000,
      );
      await store.writeDocument('crashed', 'staged', '{}', quotaBytes: 10000);
      await database.close();
      database = await LocalDatabase.fromExecutor(NativeDatabase(file));
      addTearDown(database.close);
      store = SqlOfflineResourceStore(database, clock: () => now);
      await store.recoverInterrupted();
      expect(
        (await store.listAttempts()).single.state,
        OfflineAttemptState.running,
      );
      await expectLater(
        store.begin(_resource(), 'competing', quotaBytes: 10000),
        throwsException,
      );
      now = now.add(const Duration(minutes: 3));
      await store.recoverInterrupted();
      expect(
        (await store.listAttempts()).single.state,
        OfflineAttemptState.interrupted,
      );
      expect((await store.listInstalled()).single.generation, 'first');
      expect(await store.usedBytes(), 14);
      await store.begin(_resource(), 'retry', quotaBytes: 10000);
      await store.abandon('retry', OfflineAttemptState.cancelled, 'Cancelled');
    },
  );

  test('physical database write failure cannot destroy active content', () async {
    final executor = NativeDatabase.memory();
    final database = await LocalDatabase.fromExecutor(executor);
    addTearDown(database.close);
    final store = SqlOfflineResourceStore(database);
    await _activate(store);
    await executor.runCustom(
      "CREATE TRIGGER simulate_full_storage BEFORE INSERT ON offline_documents BEGIN SELECT RAISE(FAIL, 'database or disk is full'); END",
    );
    final controller = OfflineController(
      store: store,
      installers: [
        _Installer((resource, sink, cancellation) async {
          await sink.writeDocument('chapter', '{"new":true}');
        }),
      ],
    );
    addTearDown(controller.dispose);
    await controller.install(_resource(revision: 'two'));
    expect(controller.error, contains('Free device or browser storage'));
    expect(
      await store.readDocument(_resource().key, 'chapter'),
      '{"saved":true}',
    );
    expect(await store.usedBytes(), 14);
  });

  test(
    'search pages preserve Unicode and treat SQL wildcard characters literally',
    () async {
      final database = await LocalDatabase.memory();
      addTearDown(database.close);
      final store = SqlOfflineResourceStore(database);
      await store.begin(_resource(), 'indexed', quotaBytes: 10000);
      await store.writeDocument('indexed', 'catalog', '{}', quotaBytes: 10000);
      await store.writeSearchVerses('indexed', [
        _verse(1, 'Élan 100% _ retained'),
        _verse(2, 'ÉLAN no wildcard'),
        _verse(3, 'Other'),
        _verse(4, '𐐀' * 500),
      ], quotaBytes: 10000);
      await store.activate('indexed');
      expect(
        (await store.readSearchVerses(
          _resource().key,
          terms: ['élan'],
        )).map((v) => v.verse),
        [1, 2],
      );
      expect(
        (await store.readSearchVerses(
          _resource().key,
          terms: ['%'],
        )).single.verse,
        1,
      );
      expect(
        (await store.readSearchVerses(
          _resource().key,
          terms: ['ÉLAN'],
          caseSensitive: true,
        )).single.verse,
        2,
      );
      expect(
        (await store.readSearchVerses(
          _resource().key,
          offset: 1,
          limit: 1,
        )).single.verse,
        2,
      );
      expect((await store.readSearchVerses(_resource().key, terms: ['𐐀' * 500])).single.verse, 4);
      await expectLater(
        store.readSearchVerses(_resource().key, limit: 501),
        throwsArgumentError,
      );
    },
  );

  test(
    'public removal and ordinary cache cleanup preserve each other and private data',
    () async {
      final database = await LocalDatabase.memory();
      addTearDown(database.close);
      final store = SqlOfflineResourceStore(database);
      await _activate(store);
      await database.writeSetting('private_test', 'personal');
      await database.writeCache(
        key: 'bible:v3:s2:chapter:x:1:1',
        kind: 'chapter',
        sha: 'sha',
        payload: {'saved': true},
        checkedAt: DateTime.utc(2026),
      );
      await database.clearScriptureCache();
      expect(await store.listInstalled(), hasLength(1));
      await store.remove(_resource().key);
      expect(await store.usedBytes(), 0);
      expect(
        jsonDecode((await database.readSetting('private_test'))!),
        'personal',
      );
      expect(await database.getGroups(), isNotEmpty);
    },
  );

  test('schema four migration keeps all private source provenance', () async {
    final directory = await Directory.systemTemp.createTemp(
      'getbible-schema4-offline-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/store.sqlite');
    final old = NativeDatabase(file);
    await old.ensureOpen(_VersionFour());
    await old.close();
    final database = await LocalDatabase.fromExecutor(NativeDatabase(file));
    addTearDown(database.close);
    final store = SqlOfflineResourceStore(database);
    expect(await store.listInstalled(), isEmpty);
    final notes = await database.getNotes();
    expect(notes, isNotEmpty);
    expect(
      (await database.getGroups()).map((g) => g.id),
      contains('schema-4-group'),
    );
    expect((await database.getGroups()).single.source?.topicId, 'grace');
    expect(notes.single.text, 'Personal');
    expect(notes.single.createdAt.millisecondsSinceEpoch, 10);
    await _activate(store);
    expect(await store.listInstalled(), hasLength(1));
  });
}

OfflineSearchVerse _verse(int verse, String text) => OfflineSearchVerse(
  book: 1,
  chapter: 1,
  verse: verse,
  bookName: 'Genesis',
  direction: 'LTR',
  verseJson: jsonEncode({'verse': verse, 'text': text}),
  text: text,
  normalizedText: text.toLowerCase(),
);
Future<void> _activate(OfflineResourceStore store) async {
  await store.begin(_resource(), 'first', quotaBytes: 10000);
  await store.writeDocument(
    'first',
    'chapter',
    '{"saved":true}',
    quotaBytes: 10000,
  );
  await store.activate('first');
}

final class _Installer implements OfflineResourceInstaller {
  _Installer(this.action);
  final Future<void> Function(
    OfflineResourceDescriptor,
    OfflineInstallSink,
    RequestCancellation,
  )
  action;
  @override
  Set<OfflineResourceKind> get supportedKinds => {OfflineResourceKind.bible};
  @override
  Future<List<OfflineResourceDescriptor>> discover(
    RequestCancellation cancellation,
  ) async => [_resource()];
  @override
  Future<void> install(
    OfflineResourceDescriptor resource,
    OfflineInstallSink sink,
    RequestCancellation cancellation,
  ) => action(resource, sink, cancellation);
}

final class _VersionFour extends QueryExecutorUser {
  @override
  int get schemaVersion => 4;
  @override
  Future<void> beforeOpen(
    QueryExecutor executor,
    OpeningDetails details,
  ) async {
    await executor.ensureOpen(this);
    final source = await File(
      'test/fixtures/database_schema_v4.sql',
    ).readAsString();
    for (final statement in source.split(';')) {
      if (statement.trim().isNotEmpty) await executor.runCustom(statement);
    }
    await executor.runCustom(
      'INSERT INTO marking_groups VALUES(?,?,?,?,?,?,?)',
      [
        'schema-4-group',
        'My public copy',
        '#112233',
        0,
        0,
        42,
        jsonEncode({'type': 'shared-bookmark', 'topicId': 'grace'}),
      ],
    );
    await executor.runCustom('INSERT INTO notes VALUES(?,?,?,?,?,?,?,?,?,?)', [
      'note',
      '1:1:1',
      'test',
      1,
      1,
      1,
      'Genesis 1:1',
      'Personal',
      10,
      20,
    ]);
  }
}
