import 'dart:io';

import 'package:drift/drift.dart'
    show OpeningDetails, QueryExecutor, QueryExecutorUser;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:getbible_live/application/app_state.dart';
import 'package:getbible_live/data/database/local_database.dart';
import 'package:getbible_live/domain/models/annotations.dart';
import 'package:getbible_live/domain/models/backup.dart';
import 'package:getbible_live/domain/models/bible.dart';
import 'package:getbible_live/domain/models/passage.dart';
import 'package:getbible_live/domain/models/preferences.dart';
import 'package:getbible_live/main.dart';
import 'package:getbible_live/services/backup_service.dart';
import 'package:getbible_live/services/scripture_text.dart';
import 'package:provider/provider.dart';

import 'support/reader_api_fixture.dart';

// Current web contract: lib/markings.ts + lib/shared-bookmarks.ts at
// 22172efd7ed46722c8f0da42b58222c8f1bc2360. The fixture represents a migrated
// local group with both personal and downloaded membership in the same verse.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('current web backups retain independent origins and original text', () {
    final BackupData backup = _fixture();
    final BackupData roundTrip = decodeBackup(encodeBackup(backup));
    expect(roundTrip.groups.first.source?.topicId, 'faith');
    expect(roundTrip.groups.last.source, isNull);
    expect(
      roundTrip.markings.map((Marking item) => item.isSharedBookmark),
      <bool>[false, true, false],
    );
    expect(
      roundTrip.markings.map((Marking item) => item.toJson()),
      backup.markings.map((Marking item) => item.toJson()),
    );
    expect(roundTrip.notes.single.toJson(), backup.notes.single.toJson());
    expect(mergeBackupData(backup, roundTrip).markings.length, 3);
  });

  test('same-group personal and shared marks survive colliding import IDs', () {
    final BackupData backup = _fixture();
    final Marking personal = backup.markings.first;
    final Marking global = backup.markings[1].copyWith(id: personal.id);
    final List<Marking> merged = mergeMarkings(
      <Marking>[personal],
      <Marking>[global, global.copyWith(id: 'repeated-import')],
    );
    expect(merged.length, 2);
    expect(merged.last.id, '${personal.id}-imported-1');
    expect(merged.last.source?.topicId, 'faith');
    expect(merged.first.quote, 'Original personal quote.');
  });

  test('distinct groups keep their IDs even when labels and colors match', () {
    final BackupData backup = _fixture();
    final MarkingGroup first = backup.groups.last;
    final MarkingGroup second = first.copyWith(id: 'another-private-group');
    final BackupData imported = BackupData(
      version: 2,
      exportedAt: backup.exportedAt,
      groups: <MarkingGroup>[second],
      markings: <Marking>[backup.markings.first.copyWith(groupId: second.id)],
      notes: const <VerseNote>[],
    );
    final BackupData merged = mergeBackupData(backup, imported);
    expect(
      merged.groups.map((MarkingGroup group) => group.id),
      containsAll(<String>[first.id, second.id]),
    );
    expect(mergeBackupData(merged, imported).groups.length, 3);
  });

  test('matching labels cannot absorb a different topic or personal group', () {
    final BackupData backup = _fixture();
    final MarkingGroup linked = backup.groups.first;
    final MarkingGroup personal = MarkingGroup(
      id: linked.id,
      name: linked.name,
      color: linked.color,
      updatedAt: linked.updatedAt,
    );
    final BackupData existing = BackupData(
      version: 2,
      exportedAt: backup.exportedAt,
      groups: <MarkingGroup>[personal],
      markings: <Marking>[backup.markings.first],
      notes: const <VerseNote>[],
    );
    final BackupData merged = mergeBackupData(existing, backup);
    expect(merged.groups.length, 3);
    final MarkingGroup imported = merged.groups.singleWhere(
      (MarkingGroup group) => group.source != null,
    );
    expect(imported.id, '${linked.id}-imported-1');
    expect(
      merged.markings
          .where((Marking mark) => mark.groupId == imported.id)
          .length,
      2,
    );
    expect(
      merged.markings
          .singleWhere((Marking mark) => mark.id == 'personal-faith')
          .groupId,
      personal.id,
    );
    expect(mergeBackupData(merged, backup).groups.length, merged.groups.length);
  });

  test('legacy recognition is narrow and precedes group and ID remapping', () {
    final Map<String, Object?> original =
        _fixture().markings[1].toJson(websiteCompatible: true)
          ..remove('source')
          ..['colorId'] = 'getbible-topic:faith';
    final Marking legacy = Marking.fromJson(original);
    expect(legacy.isSharedBookmark, isTrue);
    expect(
      Marking.fromJson(<String, Object?>{
        ...original,
        'id': 'personal-in-global-group',
      }).isSharedBookmark,
      isFalse,
    );
    final Marking remapped = legacy.copyWith(
      groupId: 'local-faith',
      id: 'collision-imported-1',
    );
    expect(remapped.source?.topicId, 'faith');
    expect(remapped.isSharedBookmark, isTrue);
    expect(
      remapped.toJson(websiteCompatible: true)['source'],
      <String, Object?>{'type': 'shared-bookmark', 'topicId': 'faith'},
    );
    final DateTime now = DateTime.utc(2026);
    final MarkingGroup group = MarkingGroup(
      id: legacy.groupId,
      name: 'Unrelated personal group',
      color: '#123456',
      updatedAt: now,
    );
    final BackupData current = BackupData(
      version: 2,
      exportedAt: now,
      groups: <MarkingGroup>[group],
      markings: <Marking>[
        _fixture().markings.first.copyWith(groupId: group.id),
      ],
      notes: const <VerseNote>[],
    );
    final BackupData imported = BackupData(
      version: 1,
      exportedAt: now,
      groups: <MarkingGroup>[group.copyWith(name: 'Faith')],
      markings: <Marking>[legacy],
      notes: const <VerseNote>[],
    );
    final BackupData merged = mergeBackupData(current, imported);
    expect(merged.groups.length, 2);
    expect(merged.markings.length, 2);
    expect(
      merged.markings
          .singleWhere((Marking mark) => mark.isSharedBookmark)
          .source
          ?.topicId,
      'faith',
    );
    expect(
      merged.markings
          .singleWhere((Marking mark) => mark.isSharedBookmark)
          .groupId,
      '${legacy.groupId}-imported-1',
    );
    expect(mergeBackupData(merged, imported).markings.length, 2);
  });

  test('invalid provenance rejects complete backup before persistence', () {
    for (final Object? source in <Object?>[
      null,
      <String, Object?>{'type': 'other', 'topicId': 'faith'},
      <String, Object?>{'type': 'shared-bookmark', 'topicId': 'Faith'},
      <String, Object?>{'type': 'shared-bookmark', 'topicId': 'bad/topic'},
      <String, Object?>{'type': 'shared-bookmark', 'topicId': 'a' * 81},
    ]) {
      final Map<String, Object?> json = _fixture().toJson();
      final List<Object?> markings = json['markings']! as List<Object?>;
      (markings.first! as Map<String, Object?>)['source'] = source;
      expect(() => BackupData.fromJson(json), throwsFormatException);
    }
    final Map<String, Object?> ranged = _fixture().markings.last.toJson()
      ..['source'] = <String, Object?>{
        'type': 'shared-bookmark',
        'topicId': 'faith',
      };
    expect(() => Marking.fromJson(ranged), throwsFormatException);
    expect(
      () => MarkingGroup.fromJson(<String, Object?>{
        ..._fixture().groups.first.toJson(),
        'source': null,
      }),
      throwsFormatException,
    );
  });

  test('SQLite restart and group edits preserve shared provenance', () async {
    final Directory directory = await Directory.systemTemp.createTemp(
      'getbible-bookmark-restart-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final File file = File('${directory.path}/reader.sqlite');
    final BackupData backup = _fixture();
    final LocalDatabase first = await LocalDatabase.fromExecutor(
      NativeDatabase(file),
    );
    await first.replaceReaderData(
      groups: backup.groups,
      markings: backup.markings,
      notes: backup.notes,
    );
    await first.close();
    final LocalDatabase reopened = await LocalDatabase.fromExecutor(
      NativeDatabase(file),
    );
    final AppState state = AppState.fromDatabase(reopened);
    addTearDown(state.close);
    state.groups = await reopened.getGroups();
    await state.saveMarkingGroup(
      id: 'my-faith',
      name: 'Renamed by me',
      color: '#123456',
    );
    expect(
      (await reopened.getGroups())
          .singleWhere((MarkingGroup group) => group.id == 'my-faith')
          .source
          ?.topicId,
      'faith',
    );
    final List<Marking> markings = await reopened.getMarkings();
    expect(
      markings
          .where((Marking mark) => mark.isSharedBookmark)
          .single
          .source
          ?.topicId,
      'faith',
    );
    expect(
      markings.map((Marking mark) => mark.id),
      unorderedEquals(backup.markings.map((Marking mark) => mark.id)),
    );
    expect(
      (await reopened.getNotes()).single.toJson(),
      backup.notes.single.toJson(),
    );
  });

  test(
    'schema 3 migration adds provenance without rewriting private tables',
    () async {
      final Directory directory = await Directory.systemTemp.createTemp(
        'getbible-bookmark-migration-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final File file = File('${directory.path}/reader.sqlite');
      final NativeDatabase old = NativeDatabase(file);
      await old.ensureOpen(_SchemaThreeUser());
      await old.runCustom(
        "INSERT INTO marking_groups VALUES('mine','My group','#123456',0,0,42)",
      );
      await old.runCustom(
        "INSERT INTO markings VALUES('personal','kjv',1,1,1,2,4,'😀','Genesis 1:1','mine',43)",
      );
      await old.runCustom(
        "INSERT INTO notebooks VALUES('notebook','Private notebook',10,20,1)",
      );
      await old.runCustom(
        "INSERT INTO notebook_blocks VALUES('block','notebook',0,'Keep my text',10,20,NULL)",
      );
      await old.runCustom(
        "INSERT INTO notebook_drafts VALUES('notebook','writer',2,'{\"draft\":\"unchanged\"}',30,1)",
      );
      final List<String> tables = <String>[
        'marking_groups',
        'markings',
        'notebooks',
        'notebook_blocks',
        'notebook_drafts',
        'settings',
        'notes',
        'cache_entries',
      ];
      final Map<String, List<Map<String, Object?>>> before =
          <String, List<Map<String, Object?>>>{};
      for (final String table in tables) {
        before[table] = await old.runSelect(
          'SELECT * FROM $table',
          <Object?>[],
        );
      }
      await old.close();
      final NativeDatabase executor = NativeDatabase(file);
      final LocalDatabase upgraded = await LocalDatabase.fromExecutor(executor);
      addTearDown(upgraded.close);
      expect(
        (await executor.runSelect(
          'PRAGMA user_version',
          <Object?>[],
        )).single['user_version'],
        4,
      );
      for (final String table in tables) {
        final List<Map<String, Object?>> rows = await executor.runSelect(
          'SELECT * FROM $table',
          <Object?>[],
        );
        expect(
          rows
              .map(
                (Map<String, Object?> row) =>
                    Map<String, Object?>.from(row)..remove('source_json'),
              )
              .toList(),
          before[table],
          reason: table,
        );
      }
      expect((await upgraded.getMarkings()).single.source, isNull);
    },
  );

  test(
    'failed schema 4 upgrade rolls back both provenance and version',
    () async {
      final Directory directory = await Directory.systemTemp.createTemp(
        'getbible-bookmark-rollback-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final File file = File('${directory.path}/reader.sqlite');
      final NativeDatabase old = NativeDatabase(file);
      await old.ensureOpen(_SchemaThreeUser());
      await old.runCustom('ALTER TABLE markings ADD COLUMN source_json TEXT');
      await old.close();
      final NativeDatabase failed = NativeDatabase(file);
      await expectLater(
        LocalDatabase.fromExecutor(failed),
        throwsA(isA<Exception>()),
      );
      await failed.close();
      final NativeDatabase inspect = NativeDatabase(file);
      await inspect.ensureOpen(_SchemaThreeUser());
      addTearDown(inspect.close);
      expect(
        (await inspect.runSelect(
          'PRAGMA user_version',
          <Object?>[],
        )).single['user_version'],
        3,
      );
      expect(
        (await inspect.runSelect(
          'PRAGMA table_info(marking_groups)',
          <Object?>[],
        )).map((Map<String, Object?> row) => row['name']),
        isNot(contains('source_json')),
      );
    },
  );

  test(
    'per-topic marking/removal retains global and independent private copies',
    () async {
      final LocalDatabase database = await LocalDatabase.memory();
      final AppState state = AppState.fromDatabase(database);
      addTearDown(state.close);
      final BackupData backup = _fixture();
      await state.annotations.replaceAll(backup);
      state.passage = const Passage(translation: 'kjv', book: 1, chapter: 1);
      state.groups = backup.groups;
      state.markings = await state.annotations.getMarkingsForPassage(
        state.passage,
      );
      const Verse verse = Verse(
        chapter: 1,
        verse: 1,
        name: 'Genesis 1:1',
        text: 'Original personal quote.',
      );
      await state.markWholeVerse(verse, verse.name, 'personal');
      await state.markWholeVerse(verse, verse.name, 'personal');
      expect(
        state.markings.where((Marking mark) => mark.isWholeVerse).length,
        3,
      );
      expect(
        state.markings.any((Marking mark) => mark.id == 'personal-faith'),
        isTrue,
      );
      await state.removeWholeVerseMarking(1, groupId: 'personal');
      expect(state.markings.length, 3);
      await state.removeWholeVerseMarking(1, groupId: 'my-faith');
      expect(
        state.markings.map((Marking mark) => mark.id),
        unorderedEquals(<String>['getbible-topic:faith:1:1:1', 'selection']),
      );
      await state.markWholeVerse(verse, verse.name, 'my-faith');
      await state.markWholeVerse(verse, verse.name, 'personal');
      await state.removeWholeVerseMarking(1);
      expect(
        state.markings
            .where((Marking mark) => mark.isWholeVerse)
            .single
            .isSharedBookmark,
        isTrue,
      );
      expect(
        (await state.annotations.getNotes()).single.text,
        'Private unchanged 😃',
      );
    },
  );

  test('personal whole-verse color outranks a later public import', () {
    final BackupData backup = _fixture();
    final Marking global = backup.markings[1].copyWith(groupId: 'personal');
    final List<ScriptureTextSegment> segments = const ScriptureTextComposer()
        .compose(
          verse: const Verse(
            chapter: 1,
            verse: 1,
            name: 'Genesis 1:1',
            text: 'Original personal quote.',
          ),
          groups: backup.groups,
          markings: <Marking>[backup.markings.first, global],
        );
    expect(segments.single.markingGroup?.id, 'my-faith');
    expect(preferredWholeVerseMarking(<Marking>[global])?.id, global.id);
  });

  testWidgets('verse menu identifies each removable personal topic', (
    WidgetTester tester,
  ) async {
    final ReaderApiFixture fixture = ReaderApiFixture();
    final AppState state = (await tester.runAsync(() async {
      final LocalDatabase database = await LocalDatabase.memory();
      final AppState state = AppState.fromDatabase(database, api: fixture.api);
      await state.annotations.replaceAll(_fixture());
      await state.annotations.saveGroup(
        MarkingGroup(
          id: '__none__',
          name: 'Imported action ID',
          color: '#123456',
          updatedAt: DateTime.utc(2026),
        ),
      );
      await state.settings.saveLastReadingPosition(
        LastReadingPosition(
          passage: const Passage(translation: 'tst', book: 1, chapter: 1),
          verse: 1,
          updatedAt: DateTime.utc(2026),
        ),
      );
      await state.initialize();
      await state.markWholeVerse(
        state.current!.verses.first,
        'Genesis 1:1',
        'personal',
      );
      await state.selectActiveGroup('__none__');
      return state;
    }))!;
    addTearDown(state.close);
    await tester.pumpWidget(
      ChangeNotifierProvider.value(value: state, child: const GetBibleApp()),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('1').first);
    await tester.pumpAndSettle();
    expect(find.text('Remove from My faith'), findsOneWidget);
    expect(find.text('Remove from Private study'), findsOneWidget);
    expect(find.text('Remove all personal verse markings'), findsOneWidget);
    await tester.tap(find.text('Imported action ID'));
    for (int attempt = 0; attempt < 50; attempt++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 16));
      if (state.markings.any((Marking mark) => mark.groupId == '__none__')) {
        break;
      }
    }
    expect(
      state.markings.any((Marking mark) => mark.groupId == '__none__'),
      isTrue,
    );
    expect(
      state.markings.any((Marking mark) => mark.id == 'personal-faith'),
      isTrue,
    );
    await tester.tap(find.text('1').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove from My faith'));
    for (int attempt = 0; attempt < 50; attempt++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 16));
      if (!state.markings.any((Marking mark) => mark.id == 'personal-faith')) {
        break;
      }
    }
    expect(
      state.markings.any((Marking mark) => mark.id == 'personal-faith'),
      isFalse,
    );
    expect(state.markings.any((Marking mark) => mark.isSharedBookmark), isTrue);
    expect(
      state.markings.any(
        (Marking mark) => mark.groupId == 'personal' && mark.isWholeVerse,
      ),
      isTrue,
    );
    expect(tester.takeException(), isNull);
  });
}

BackupData _fixture() => decodeBackup(
  File('test/fixtures/current_web_bookmarks_v2.json').readAsStringSync(),
);

final class _SchemaThreeUser extends QueryExecutorUser {
  @override
  int get schemaVersion => 3;

  @override
  Future<void> beforeOpen(
    QueryExecutor executor,
    OpeningDetails details,
  ) async {
    await executor.ensureOpen(this);
    if (!details.wasCreated) return;
    for (final String statement
        in File('test/fixtures/database_schema_v3.sql')
            .readAsStringSync()
            .split(';')
            .where((String part) => part.trim().isNotEmpty)) {
      await executor.runCustom(statement);
    }
  }
}
