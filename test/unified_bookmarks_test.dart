import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:getbible_live/application/unified_bookmarks_controller.dart';
import 'package:getbible_live/core/request_cancellation.dart';
import 'package:getbible_live/data/database/local_database.dart';
import 'package:getbible_live/data/repositories/sql_unified_bookmarks_repository.dart';
import 'package:getbible_live/domain/models/annotations.dart';
import 'package:getbible_live/domain/models/notebook.dart';
import 'package:getbible_live/domain/models/passage.dart';
import 'package:getbible_live/domain/models/preferences.dart';
import 'package:getbible_live/domain/models/private_backup.dart';
import 'package:getbible_live/domain/models/public_topic.dart';
import 'package:getbible_live/domain/models/service_envelopes.dart';
import 'package:getbible_live/domain/models/unified_bookmarks.dart';
import 'package:getbible_live/domain/repositories/public_topics_repository.dart';

const _scope = SharedBookmarkSource.defaultScope;
const _passage = Passage(translation: 'kjv', book: 43, chapter: 3);
final _time = DateTime.utc(2025, 1, 2);
final _topic = PublicTopic(
  id: 'faith',
  name: 'Faith',
  color: '#123456',
  aliases: ['Belief'],
  isDefault: true,
  names: {'en': 'Faith', 'af': 'Geloof', 'fr': 'Foi'},
  coordinates: [const PublicTopicCoordinate(43, 3, 16)],
);
MarkingGroup _group(String id, String name, {SharedBookmarkSource? source}) =>
    MarkingGroup(
      id: id,
      name: name,
      color: '#FEDCBA',
      updatedAt: _time,
      source: source,
    );
Marking _mark(
  String id,
  String group, {
  SharedBookmarkSource? source,
  int? start,
  int? end,
}) => Marking(
  id: id,
  passage: _passage,
  verse: 16,
  start: start,
  end: end,
  quote: 'Original private quotation',
  reference: 'John 3:16',
  groupId: group,
  createdAt: _time,
  source: source,
);
Future<void> _seed(
  LocalDatabase db,
  List<MarkingGroup> groups,
  List<Marking> markings,
) => db.replaceReaderData(
  groups: groups,
  markings: markings,
  notes: [
    VerseNote(
      id: 'note',
      passage: _passage,
      verse: 16,
      reference: 'John 3:16',
      text: 'Unchanged note',
      createdAt: _time,
      updatedAt: _time,
    ),
  ],
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'topic normalization covers canonical and compatibility Unicode without folding Scripture',
    () {
      expect(normalizeBookmarkTopicName('  Fóí—ＦＡＩＴＨ ① ﬃ '), 'foifaith1ffi');
      expect(normalizeBookmarkTopicName('ΑΓΆΠΗ'), 'αγαπη');
      expect(normalizeBookmarkTopicName('שָׁלוֹם'), 'שלום');
      expect(normalizeBookmarkTopicName('الإِيمان'), 'الايمان');
      expect(
        normalizeBookmarkTopicName('한'),
        normalizeBookmarkTopicName('한'),
      );
    },
  );

  test(
    'metadata reconciles id, localized name and alias without any memberships',
    () {
      for (final label in ['faith', 'Géloof', 'Belief']) {
        final local = _group(label == 'faith' ? 'faith' : 'local-id', label);
        final plan = reconcileBookmarkGroups(
          groups: [local],
          markings: [],
          topics: [metadataOf(_topic)],
          sourceScope: _scope,
          locale: 'fr',
          now: DateTime.now(),
        );
        expect(plan.groups, hasLength(1));
        final migrated = plan.groups.single;
        expect(migrated.id, local.id);
        expect(migrated.name, local.name);
        expect(migrated.color, local.color);
        expect(migrated.updatedAt, local.updatedAt);
        expect(migrated.source?.topicId, 'faith');
        expect(plan.markings, isEmpty);
      }
    },
  );

  test(
    'ambiguous aliases and distinct same-name private groups are preserved',
    () {
      final second = PublicTopic(
        id: 'hope',
        name: 'Hope',
        color: '#234567',
        aliases: ['Belief'],
        isDefault: false,
        names: {},
        coordinates: [],
      );
      final plan = reconcileBookmarkGroups(
        groups: [_group('private', 'Belief')],
        markings: [],
        topics: [metadataOf(_topic), metadataOf(second)],
        sourceScope: _scope,
        locale: 'en',
        now: _time,
      );
      expect(plan.groups.first.source, isNull);
      expect(plan.groups, hasLength(3));
      final duplicated = reconcileBookmarkGroups(
        groups: [_group('one', 'Faith'), _group('two', 'Faith')],
        markings: [],
        topics: [metadataOf(_topic)],
        sourceScope: _scope,
        locale: 'en',
        now: _time,
      );
      expect(
        duplicated.groups.take(2).map((group) => group.source),
        everyElement(isNull),
      );
      expect(
        duplicated.groups.map((group) => group.id),
        containsAll(['one', 'two']),
      );
    },
  );

  test('global semantic identities include the provider and topic', () {
    final official = _mark(
      'official',
      'local',
      source: const SharedBookmarkSource(topicId: 'faith'),
    );
    final alternate = _mark(
      'alternate',
      'local',
      source: const SharedBookmarkSource(
        topicId: 'faith',
        sourceScope: 'bookmarks:v1:https://other.test/v1',
      ),
    );
    final anotherTopic = _mark(
      'another-topic',
      'local',
      source: const SharedBookmarkSource(topicId: 'hope'),
    );
    expect({
      official.identity,
      alternate.identity,
      anotherTopic.identity,
    }, hasLength(3));
    expect(
      Marking.fromJson(alternate.toJson()).sharedSource?.effectiveScope,
      'bookmarks:v1:https://other.test/v1',
    );
  });

  test(
    'explicit different source IDs and foreign providers outrank labels',
    () {
      final groups = [
        _group(
          'renamed',
          'Faith',
          source: const SharedBookmarkSource(topicId: 'hope'),
        ),
        _group(
          'foreign',
          'Faith',
          source: const SharedBookmarkSource(
            topicId: 'faith',
            sourceScope: 'bookmarks:v1:https://other.test/v1',
          ),
        ),
      ];
      final plan = reconcileBookmarkGroups(
        groups: groups,
        markings: [],
        topics: [metadataOf(_topic)],
        sourceScope: _scope,
        locale: 'en',
        now: _time,
      );
      expect(plan.groups[0].source?.topicId, 'hope');
      expect(
        plan.groups[1].source?.effectiveScope,
        'bookmarks:v1:https://other.test/v1',
      );
      expect(plan.groups, hasLength(3));
    },
  );

  test(
    'migration keeps personal ids/ranges/quotes and normalizes legacy origin before remapping',
    () {
      final local = _group('local', 'Geloof');
      final imported = _group('getbible-topic:faith', 'Faith');
      final private = _mark('personal', local.id);
      final selection = _mark('selection', local.id, start: 2, end: 8);
      final global = _mark('getbible-topic:faith:43:3:16', imported.id);
      final plan = reconcileBookmarkGroups(
        groups: [local, imported],
        markings: [private, selection, global],
        topics: [metadataOf(_topic)],
        sourceScope: _scope,
        locale: 'en',
        now: _time,
      );
      expect(plan.groups, hasLength(1));
      expect(plan.markings.map((mark) => mark.id), [
        'personal',
        'selection',
        global.id,
      ]);
      expect(plan.markings[0].toJson(), private.toJson());
      expect(plan.markings[1].toJson(), selection.toJson());
      expect(plan.markings[2].sharedSource?.topicId, 'faith');
      expect(plan.markings[2].groupId, 'local');
      final rows = bookmarkDisplayRows(plan.markings);
      expect(rows, hasLength(2));
      expect(rows.first.personal, isTrue);
      expect(rows.first.global, isTrue);
      expect(rows.first.marking.id, 'personal');
    },
  );

  test(
    'fresh fallback defaults become API groups without downloading verses',
    () async {
      final db = await LocalDatabase.memory();
      addTearDown(db.close);
      await SqlUnifiedBookmarksRepository(
        db,
      ).reconcile([metadataOf(_topic)], sourceScope: _scope, locale: 'af-ZA');
      expect((await db.getGroups()).single.name, 'Geloof');
      expect((await db.getGroups()).single.id, 'getbible-topic:faith');
      expect(await db.getMarkings(), isEmpty);
    },
  );

  test(
    'API default replacement keeps an already-selected fallback topic',
    () async {
      final db = await LocalDatabase.memory();
      addTearDown(db.close);
      await db.writeSetting(
        'readerPreferences',
        const ReaderPreferences(activeMarkingGroupId: 'grace').toJson(),
      );
      final grace = PublicTopic(
        id: 'grace',
        name: 'Grace',
        color: '#123456',
        aliases: [],
        isDefault: true,
        names: {},
        coordinates: [],
      );
      await SqlUnifiedBookmarksRepository(db).reconcile(
        [metadataOf(_topic), metadataOf(grace)],
        sourceScope: _scope,
        locale: 'en',
      );
      final preferences = ReaderPreferences.fromJson(
        jsonDecode((await db.readSetting('readerPreferences'))!),
      );
      expect(preferences.activeMarkingGroupId, 'getbible-topic:grace');
    },
  );

  test(
    'SQL migration remaps active/recent settings atomically and survives restart',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'bookmark-reopen-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/reader.sqlite');
      var db = await LocalDatabase.fromExecutor(NativeDatabase(file));
      final local = _group('local', 'Faith');
      final old = _group('getbible-topic:faith', 'Faith');
      await _seed(
        db,
        [local, old],
        [
          _mark('personal', local.id),
          _mark('getbible-topic:faith:43:3:16', old.id),
        ],
      );
      await db.writeSetting(
        'readerPreferences',
        const ReaderPreferences(
          activeMarkingGroupId: 'getbible-topic:faith',
        ).toJson(),
      );
      await db.writeSetting('bookmarks:v1:recent', [old.id, local.id]);
      final repo = SqlUnifiedBookmarksRepository(db);
      await repo.reconcile(
        [metadataOf(_topic)],
        sourceScope: _scope,
        locale: 'en',
      );
      await repo.reconcile(
        [metadataOf(_topic)],
        sourceScope: _scope,
        locale: 'en',
      );
      expect((await db.getGroups()).single.id, 'local');
      expect((await db.getMarkings()).length, 2);
      expect(
        ReaderPreferences.fromJson(
          jsonDecode((await db.readSetting('readerPreferences'))!),
        ).activeMarkingGroupId,
        'local',
      );
      expect(await repo.recentGroups(), ['local']);
      expect((await db.getNotes()).single.id, 'note');
      await db.close();
      db = await LocalDatabase.fromExecutor(NativeDatabase(file));
      addTearDown(db.close);
      expect((await db.getGroups()).single.updatedAt, _time);
      expect(
        (await db.getMarkings()).map((mark) => mark.createdAt),
        everyElement(_time),
      );
      expect(
        (await db.privateSnapshot()).settings.any(
          (setting) => setting.key == 'bookmarks:v1:recent',
        ),
        isTrue,
      );
    },
  );

  test(
    'download and removal are additive/idempotent and only affect one origin/provider',
    () async {
      final db = await LocalDatabase.memory();
      addTearDown(db.close);
      final private = _mark('private', 'local');
      await _seed(db, [_group('local', 'Faith')], [private]);
      final repo = SqlUnifiedBookmarksRepository(db);
      Future<void> download() => repo.download(
        [_topic],
        catalogue: [metadataOf(_topic)],
        sourceScope: _scope,
        locale: 'en',
        translation: 'kjv',
      );
      await download();
      await download();
      expect((await db.getMarkings()).length, 2);
      await repo.removeMembership(
        passage: _passage,
        verse: 16,
        groupId: 'local',
        origin: BookmarkOrigin.global,
      );
      expect((await db.getMarkings()).single.toJson(), private.toJson());
      await download();
      await repo.removeMembership(
        passage: _passage,
        verse: 16,
        groupId: 'local',
        origin: BookmarkOrigin.personal,
      );
      expect((await db.getMarkings()).single.isSharedBookmark, isTrue);
      await db.saveMarking(private);
      await repo.removeGlobal(
        sourceScope: 'bookmarks:v1:https://other.test/v1',
      );
      expect((await db.getMarkings()).length, 2);
      await repo.removeGlobal(sourceScope: _scope);
      expect((await db.getMarkings()).single.id, 'private');
      expect((await db.getGroups()).single.name, 'Faith');
      expect((await db.getNotes()).single.text, 'Unchanged note');
    },
  );

  test(
    'reconciliation and removal preserve saved notebooks and unactivated journals',
    () async {
      final db = await LocalDatabase.memory();
      addTearDown(db.close);
      await _seed(db, [_group('local', 'Faith')], [_mark('personal', 'local')]);
      final notebook = Notebook(
        id: 'study',
        title: 'Private study',
        createdAt: _time,
        updatedAt: _time,
        revision: 1,
        blocks: [
          NotebookBlock(
            id: 'block',
            text: 'Saved original',
            createdAt: _time,
            updatedAt: _time,
          ),
        ],
      );
      await db.saveNotebook(notebook, expectedRevision: null);
      final draft = notebook.edit(
        now: _time.add(const Duration(minutes: 1)),
        blocks: [
          notebook.blocks.single.withText(
            'Unsaved private journal',
            _time.add(const Duration(minutes: 1)),
          ),
        ],
      );
      await db.saveNotebookDraft(
        draft,
        expectedRevision: 1,
        editorId: 'independent-editor',
      );
      final before = await db.privateSnapshot();
      final repo = SqlUnifiedBookmarksRepository(db);
      await repo.download(
        [_topic],
        catalogue: [metadataOf(_topic)],
        sourceScope: _scope,
        locale: 'en',
        translation: 'kjv',
      );
      await repo.removeGlobal(sourceScope: _scope);
      final after = await db.privateSnapshot();
      expect(
        after.notebooks.map((book) => book.toJson()),
        before.notebooks.map((book) => book.toJson()),
      );
      expect(
        after.drafts.map(privateDraftToJson),
        before.drafts.map(privateDraftToJson),
      );
    },
  );

  test(
    'SQL failure rolls back groups, memberships and settings together',
    () async {
      final executor = NativeDatabase.memory();
      final db = await LocalDatabase.fromExecutor(executor);
      addTearDown(db.close);
      await _seed(db, [_group('local', 'Faith')], [_mark('personal', 'local')]);
      final before = await db.privateSnapshot();
      await executor.runCustom(
        "CREATE TRIGGER reject_global BEFORE INSERT ON markings WHEN NEW.source_json IS NOT NULL BEGIN SELECT RAISE(ABORT, 'disk failure'); END",
      );
      await expectLater(
        SqlUnifiedBookmarksRepository(db).download(
          [_topic],
          catalogue: [metadataOf(_topic)],
          sourceScope: _scope,
          locale: 'en',
          translation: 'kjv',
        ),
        throwsA(anything),
      );
      final after = await db.privateSnapshot();
      expect(
        after.reader.groups.map((group) => group.toJson()),
        before.reader.groups.map((group) => group.toJson()),
      );
      expect(
        after.reader.markings.map((mark) => mark.toJson()),
        before.reader.markings.map((mark) => mark.toJson()),
      );
    },
  );

  test(
    'malformed final topic prevents every mutation in a bulk download',
    () async {
      final db = await LocalDatabase.memory();
      addTearDown(db.close);
      await _seed(db, [_group('local', 'Faith')], [_mark('personal', 'local')]);
      final bad = PublicTopic(
        id: 'faith',
        name: 'Faith',
        color: '#123456',
        aliases: [],
        isDefault: false,
        names: {},
        coordinates: [const PublicTopicCoordinate(0, 1, 1)],
      );
      await expectLater(
        SqlUnifiedBookmarksRepository(db).download(
          [_topic, bad],
          catalogue: [metadataOf(_topic)],
          sourceScope: _scope,
          locale: 'en',
          translation: 'kjv',
        ),
        throwsFormatException,
      );
      expect((await db.getGroups()).single.source, isNull);
      expect((await db.getMarkings()).single.id, 'personal');
    },
  );

  test(
    'controller metadata initialization never requests topic memberships',
    () async {
      final db = await LocalDatabase.memory();
      addTearDown(db.close);
      final api = _PublicRepository();
      final controller = UnifiedBookmarksController(
        storage: SqlUnifiedBookmarksRepository(db),
        publicTopics: api,
        onChanged: () async {},
      );
      addTearDown(controller.dispose);
      await controller.initialize(locale: 'af');
      expect(controller.error, isNull);
      expect(api.topicRequests, 0);
      expect((await db.getGroups()).single.name, 'Geloof');
      await controller.download(translation: 'kjv');
      expect(controller.error, isNull);
      expect(api.topicRequests, 1);
      expect((await db.getMarkings()).single.isSharedBookmark, isTrue);
    },
  );

  test(
    'cancellation drains in-flight public work without adding memberships',
    () async {
      final db = await LocalDatabase.memory();
      addTearDown(db.close);
      final api = _PublicRepository();
      final controller = UnifiedBookmarksController(
        storage: SqlUnifiedBookmarksRepository(db),
        publicTopics: api,
        onChanged: () async {},
      );
      addTearDown(controller.dispose);
      await controller.initialize();
      api.block = Completer<PublicTopic>();
      final pending = controller.download(translation: 'kjv');
      await api.started.future;
      await controller.close();
      await pending;
      expect(await db.getMarkings(), isEmpty);
      controller.resume();
      api.block = null;
      await controller.download(translation: 'kjv');
      expect((await db.getMarkings()).length, 1);
    },
  );
}

final class _PublicRepository implements PublicTopicsRepository {
  int topicRequests = 0;
  Completer<PublicTopic>? block;
  final started = Completer<void>();
  @override
  String get sourceScope => _scope;
  @override
  Future<PublicTopicDiscovery> discovery({
    RequestCancellation? cancellation,
  }) async => PublicTopicDiscovery(
    catalogVersion: 1,
    checksum: 'same',
    topicCount: 1,
    associationCount: 1,
    localeCount: 2,
    resources: {},
    locales: ['en', 'af'],
  );
  @override
  Future<PublicTopicCatalogue> catalogue({
    RequestCancellation? cancellation,
  }) async =>
      PublicTopicCatalogue(topics: [metadataOf(_topic).summary], source: {});
  @override
  Future<List<PublicTopicLocale>> locales({
    RequestCancellation? cancellation,
  }) async => [
    const PublicTopicLocale(code: 'en', name: 'English', topicCount: 1),
    const PublicTopicLocale(code: 'af', name: 'Afrikaans', topicCount: 1),
  ];
  @override
  Future<PublicTopicNames> names(
    String locale, {
    RequestCancellation? cancellation,
  }) async =>
      PublicTopicNames(locale: locale, names: {'faith': _topic.names[locale]!});
  @override
  Future<PublicTopic> topic(
    String id, {
    RequestCancellation? cancellation,
  }) async {
    topicRequests++;
    if (block != null) {
      if (!started.isCompleted) started.complete();
      return cancellation!.bind(block!.future);
    }
    return _topic;
  }

  @override
  Future<PublicTopicAssociations> chapter(
    int book,
    int chapter, {
    RequestCancellation? cancellation,
  }) => throw UnimplementedError();
}
