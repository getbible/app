import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart'
    show QueryExecutor, QueryExecutorUser, OpeningDetails;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:getbible_live/data/database/local_database.dart';
import 'package:getbible_live/domain/models/cache.dart';

void main() {
  test(
    'literal cache prefixes preserve neighbouring numeric IDs and wildcard names',
    () async {
      final database = await LocalDatabase.memory();
      addTearDown(database.close);
      final keys = [
        'bible:v3:s2:chapter:fx:1:1',
        'bible:v3:s2:chapter:fx:1:10',
        'bible:v3:s2:chapter:fx:10:1',
        'bible:v3:s2:chapter:fx:11:1',
        'bible:v3:s2:chapter:f_x:1:1',
        'bible:v3:s2:chapter:f%x:1:1',
        'bible:v3:s2:chapter:fzx:1:1',
      ];
      for (final key in keys) {
        await database.writeCache(
          key: key,
          kind: 'chapter',
          sha: 'source',
          payload: {'text': 'saved'},
          checkedAt: DateTime.utc(2026),
        );
      }
      await database.deleteCachePrefix('bible:v3:s2:chapter:fx:1:1');
      expect(await database.readCache(keys[0]), isNull);
      expect(await database.readCache(keys[1]), isNotNull);
      await database.deleteCachePrefix('bible:v3:s2:chapter:fx:1:');
      expect(await database.readCache(keys[1]), isNull);
      expect(await database.readCache(keys[2]), isNotNull);
      expect(await database.readCache(keys[3]), isNotNull);
      await database.deleteCachePrefix('bible:v3:s2:chapter:f_x');
      expect(await database.readCache(keys[4]), isNull);
      expect(await database.readCache(keys[5]), isNotNull);
      expect(await database.readCache(keys[6]), isNotNull);
      await database.deleteCachePrefix('bible:v3:s2:chapter:f%x');
      expect(await database.readCache(keys[5]), isNull);
      expect(await database.readCache(keys[6]), isNotNull);
    },
  );
  test(
    'source expiry keeps last-known-good bytes and only expires matching chapter',
    () async {
      final database = await LocalDatabase.memory();
      addTearDown(database.close);
      for (final chapter in [1, 10]) {
        await database.writeCache(
          key: 'bible:v3:s2:chapter:fx:1:$chapter',
          kind: 'chapter',
          sha: 'source',
          payload: {'text': 'saved $chapter'},
          checkedAt: DateTime.utc(2026),
        );
      }
      await database.invalidateCachePrefix('bible:v3:s2:chapter:fx:1:1');
      expect(
        (await database.readCache('bible:v3:s2:chapter:fx:1:1'))!.sha,
        isEmpty,
      );
      expect(
        jsonDecode(
          (await database.readCache('bible:v3:s2:chapter:fx:1:1'))!.json,
        ),
        {'text': 'saved 1'},
      );
      expect(
        (await database.readCache('bible:v3:s2:chapter:fx:1:10'))!.sha,
        'source',
      );
    },
  );
  test(
    'a failed migration rolls back new columns, provenance and schema version',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'getbible-failed-migration-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/getbible_life.sqlite');
      final old = NativeDatabase(file);
      await old.ensureOpen(_SchemaOneUser());
      for (final key in ['chapter:fx:1:1', 'bible:v2:s1:chapter:fx:1:1']) {
        await old.runCustom(
          'INSERT INTO cache_entries VALUES(?, ?, ?, ?, ?, ?)',
          [key, 'chapter', 'saved', '{}', 1, 1],
        );
      }
      await old.close();
      final failed = NativeDatabase(file);
      await expectLater(
        LocalDatabase.fromExecutor(failed),
        throwsA(isA<Exception>()),
      );
      await failed.close();
      final inspect = NativeDatabase(file);
      await inspect.ensureOpen(_SchemaOneUser());
      addTearDown(inspect.close);
      final columns = await inspect.runSelect(
        'PRAGMA table_info(cache_entries)',
        [],
      );
      expect(columns.map((row) => row['name']), isNot(contains('fresh_until')));
      final rows = await inspect.runSelect(
        'SELECT cache_key FROM cache_entries ORDER BY cache_key',
        [],
      );
      expect(rows.map((row) => row['cache_key']), [
        'bible:v2:s1:chapter:fx:1:1',
        'chapter:fx:1:1',
      ]);
      expect(
        (await inspect.runSelect(
          'PRAGMA user_version',
          [],
        )).single['user_version'],
        1,
      );
    },
  );

  test(
    'schema one upgrades cache provenance while preserving every private table',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'getbible-v1-migration-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/getbible_life.sqlite');
      final old = NativeDatabase(file);
      await old.ensureOpen(_SchemaOneUser());
      final now = DateTime.utc(2026, 1, 1).millisecondsSinceEpoch;
      await old.runCustom(
        'INSERT INTO marking_groups VALUES(?, ?, ?, ?, ?, ?)',
        ['mine', 'My group', '#123456', 0, 0, now],
      );
      await old.runCustom(
        'INSERT INTO markings VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
        [
          'mark',
          'fx',
          900000123,
          3,
          7,
          2,
          5,
          'A😀',
          'Extended Book 3:7',
          'mine',
          now,
        ],
      );
      await old
          .runCustom('INSERT INTO notes VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?)', [
            'note',
            '900000123:3:7',
            'fx',
            900000123,
            3,
            7,
            'Extended Book 3:7',
            'My private note',
            now,
            now,
          ]);
      await old.runCustom('INSERT INTO settings VALUES(?, ?, ?)', [
        'lastPassage',
        jsonEncode({
          'translation': 'fx',
          'book': 900000123,
          'chapter': 3,
          'verse': 7,
        }),
        now,
      ]);
      await old.runCustom('INSERT INTO settings VALUES(?, ?, ?)', [
        'preferences',
        '{"textSize":24}',
        now,
      ]);
      await old
          .runCustom('INSERT INTO cache_entries VALUES(?, ?, ?, ?, ?, ?)', [
            'chapter:fx:900000123:3',
            'chapter',
            'legacy-sha',
            '{"legacy":"original"}',
            now,
            now,
          ]);
      await old.close();
      final database = await LocalDatabase.fromExecutor(NativeDatabase(file));
      addTearDown(database.close);
      expect(localDatabaseSchemaVersion, 2);
      expect(await database.readCache('chapter:fx:900000123:3'), isNull);
      final legacy = await database.readCache(
        ScriptureCacheIdentity.legacy.key('chapter:fx:900000123:3'),
      );
      expect(legacy!.json, '{"legacy":"original"}');
      expect(legacy.sha, 'legacy-sha');
      expect(legacy.mustRevalidate, isTrue);
      final groups = await database.getGroups();
      expect(groups.single.id, 'mine');
      expect(groups.single.name, 'My group');
      final marking = (await database.getMarkings()).single;
      expect(marking.quote, 'A😀');
      expect(marking.start, 2);
      expect(marking.end, 5);
      expect(marking.passage.book, 900000123);
      expect((await database.getNotes()).single.text, 'My private note');
      expect(jsonDecode((await database.readSetting('lastPassage'))!), {
        'translation': 'fx',
        'book': 900000123,
        'chapter': 3,
        'verse': 7,
      });
      expect(await database.readSetting('preferences'), '{"textSize":24}');
    },
  );
}

final class _SchemaOneUser extends QueryExecutorUser {
  @override
  int get schemaVersion => 1;
  @override
  Future<void> beforeOpen(
    QueryExecutor executor,
    OpeningDetails details,
  ) async {
    await executor.ensureOpen(this);
    if (details.wasCreated) {
      final sql = File(
        'test/fixtures/database_schema_v1.sql',
      ).readAsStringSync();
      for (final statement
          in sql.split(';').where((value) => value.trim().isNotEmpty)) {
        await executor.runCustom(statement);
      }
    }
  }
}
