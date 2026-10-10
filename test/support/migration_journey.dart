import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart'
    show OpeningDetails, QueryExecutor, QueryExecutorUser;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:getbible/data/database/local_database.dart';

import 'fixture_documents.dart';

/// A pre-offline release database is reopened by the current migration path on
/// each native host. Private identities, provenance and timestamps must survive.
void migrationJourney() {
  testWidgets(
    'released schema upgrade preserves private records across restart',
    (tester) async {
      await tester.runAsync(() async {
        final directory = await Directory.systemTemp.createTemp(
          'getbible-upgrade-',
        );
        try {
          final file = File('${directory.path}/release.sqlite');
          final old = NativeDatabase(file);
          await old.ensureOpen(_ReleasedDatabase());
          await old.close();
          for (var restart = 0; restart < 2; restart++) {
            final database = await LocalDatabase.fromExecutor(
              NativeDatabase(file),
            );
            try {
              final group = (await database.getGroups()).single;
              expect(group.id, 'preserved-group');
              expect(group.name, 'My own title');
              expect(group.source?.topicId, 'grace');
              final note = (await database.getNotes()).single;
              expect(note.id, 'preserved-note');
              expect(note.text, 'Private reflection שלום 😀');
              expect(note.createdAt.millisecondsSinceEpoch, 10);
              expect(note.updatedAt.millisecondsSinceEpoch, 20);
              expect(
                await SqlOfflineResourceStore(database).listInstalled(),
                isEmpty,
              );
            } finally {
              await database.close();
            }
          }
        } finally {
          await directory.delete(recursive: true);
        }
      });
    },
  );
}

final class _ReleasedDatabase extends QueryExecutorUser {
  @override
  int get schemaVersion => 4;

  @override
  Future<void> beforeOpen(
    QueryExecutor executor,
    OpeningDetails details,
  ) async {
    await executor.ensureOpen(this);
    for (final statement in fixtureText('database_schema_v4.sql').split(';')) {
      if (statement.trim().isNotEmpty) await executor.runCustom(statement);
    }
    await executor.runCustom(
      'INSERT INTO marking_groups VALUES(?,?,?,?,?,?,?)',
      [
        'preserved-group',
        'My own title',
        '#112233',
        0,
        0,
        42,
        jsonEncode({'type': 'shared-bookmark', 'topicId': 'grace'}),
      ],
    );
    await executor.runCustom('INSERT INTO notes VALUES(?,?,?,?,?,?,?,?,?,?)', [
      'preserved-note',
      '1:1:1',
      'test',
      1,
      1,
      1,
      'Genesis 1:1',
      'Private reflection שלום 😀',
      10,
      20,
    ]);
  }
}
