import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:getbible_live/application/grouped_reference_lookup.dart';
import 'package:getbible_live/application/topics_controller.dart';
import 'package:getbible_live/core/errors.dart';
import 'package:getbible_live/core/json.dart';
import 'package:getbible_live/core/request_cancellation.dart';
import 'package:getbible_live/data/api/api_transport.dart';
import 'package:getbible_live/data/api/public_topic_adapter.dart';
import 'package:getbible_live/data/api/query_api_client.dart';
import 'package:getbible_live/data/database/local_database.dart';
import 'package:getbible_live/data/repositories/api_public_topics_repository.dart';
import 'package:getbible_live/data/repositories/api_query_repository.dart';
import 'package:getbible_live/data/repositories/sql_public_topic_copy_repository.dart';
import 'package:getbible_live/data/repositories/sql_study_preferences_repository.dart';
import 'package:getbible_live/domain/models/annotations.dart';
import 'package:getbible_live/domain/models/bible.dart';
import 'package:getbible_live/domain/models/cache.dart';
import 'package:getbible_live/domain/models/passage.dart';
import 'package:getbible_live/domain/models/public_topic.dart';
import 'package:getbible_live/domain/models/reference.dart';
import 'package:getbible_live/domain/models/service_envelopes.dart';
import 'package:getbible_live/domain/models/study_context.dart';
import 'package:getbible_live/domain/repositories/bible_repository.dart';
import 'package:getbible_live/domain/repositories/installed_study_resource.dart';
import 'package:getbible_live/domain/repositories/public_topics_repository.dart';
import 'package:getbible_live/presentation/widgets/topics_panel.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

JsonMap _fixture(String name) => requireJsonMap(
  jsonDecode(File('test/fixtures/$name').readAsStringSync()),
  'topic fixture',
);
PublicTopic _topic() => PublicTopicAdapter.topic(
  _fixture('public_topic_single.json'),
  expectedId: 'authority-of-the-bible',
);
const StudyContext _context = StudyContext(
  passage: Passage(translation: 'kjv', book: 1, chapter: 1, verse: 1),
  bookName: 'Genesis',
  language: 'af',
  translationName: 'King James Version',
);

void main() {
  test(
    'topic installation status changes preserve selected topic and private choices',
    () async {
      final database = await LocalDatabase.memory();
      addTearDown(database.close);
      final repository = _TopicsFake();
      final controller = _controller(repository, database);
      addTearDown(controller.dispose);
      await controller.initialize(_context);
      await controller.selectTopic('authority-of-the-bible');
      await controller.setFollowed('authority-of-the-bible', true);
      final selected = controller.selectedTopic;
      final names = controller.localizedNames;
      repository.installed = true;
      await controller.refreshInstallationStatus();
      expect(controller.isInstalled, isTrue);
      expect(controller.selectedTopic, same(selected));
      expect(controller.localizedNames, same(names));
      expect(controller.followed, contains('authority-of-the-bible'));
      final pending = Completer<bool>();
      repository.statusPending = pending;
      final older = controller.refreshInstallationStatus();
      controller.dismiss();
      pending.complete(false);
      await older;
      expect(controller.isInstalled, isTrue);
    },
  );

  test(
    'topic citations reject unavailable selected-Bible books and verses without partial success',
    () async {
      final List<Uri> requests = <Uri>[];
      final ApiTransport transport = ApiTransport(
        client: MockClient((http.Request request) async {
          requests.add(request.url);
          return http.Response(
            jsonEncode(<String, Object?>{
              'web_1_1': <String, Object?>{
                'book_nr': 1,
                'chapter': 1,
                'verses': <Object?>[
                  <String, Object?>{
                    'verse': 1,
                    'name': 'Genesis 1:1',
                    'text': 'A returned verse',
                  },
                ],
              },
            }),
            200,
          );
        }),
        retryPolicy: const ApiRetryPolicy(maxRetries: 0),
      );
      addTearDown(transport.close);
      final GroupedReferenceLookup lookup = GroupedReferenceLookup(
        queryRepository: ApiQueryRepository(
          QueryApiClient(transport: transport),
        ),
        bibleRepository: _TopicBible(),
      );
      await expectLater(
        lookup.lookup(
          StructuredReferenceRequest(
            translation: 'web',
            selections: _topic().selections,
            sourceLabel: _topic().name,
          ),
        ),
        throwsA(isA<ReferenceLookupException>()),
      );
      expect(requests, isEmpty); // The selected Bible lacks the cited book 43.
      await expectLater(
        lookup.lookup(
          StructuredReferenceRequest(
            translation: 'web',
            selections: [_topic().selections.first],
            sourceLabel: _topic().name,
          ),
        ),
        throwsA(isA<ReferenceLookupException>()),
      );
      expect(requests.single.host, 'query.getbible.net');
      expect(requests.single.pathSegments, [
        'v3',
        'web',
        'Genesis 1:1;Genesis 1:3',
      ]);
    },
  );

  test(
    'private identity allocation retries occupied ids and fails without mutations when exhausted',
    () async {
      final LocalDatabase database = await LocalDatabase.memory();
      addTearDown(database.close);
      final DateTime now = DateTime.utc(2026);
      await database.saveGroup(
        MarkingGroup(
          id: 'private-topic-collision',
          name: 'Private group',
          color: '#ABCDEF',
          updatedAt: now,
        ),
      );
      final List<MarkingGroup> before = await database.getGroups();
      final SqlPublicTopicCopyRepository exhausted =
          SqlPublicTopicCopyRepository(database, createId: () => 'collision');
      final PublicTopicCopyPreview preview = await exhausted.preview(
        topic: _topic(),
        sourceScope: 'bookmarks:v1:test',
        translation: 'kjv',
      );
      await expectLater(exhausted.copy(preview), throwsStateError);
      expect(await database.getGroups(), hasLength(before.length));
      expect(await database.getMarkings(), isEmpty);
      int attempts = 0;
      final SqlPublicTopicCopyRepository recovered =
          SqlPublicTopicCopyRepository(
            database,
            createId: () => attempts++ == 0 ? 'collision' : 'fresh-$attempts',
          );
      final PublicTopicCopyResult result = await recovered.copy(preview);
      expect(result.groupId, 'private-topic-fresh-2');
      expect(result.added, 3);
      expect(
        (await database.getGroups())
            .firstWhere(
              (MarkingGroup group) => group.id == 'private-topic-collision',
            )
            .name,
        'Private group',
      );
    },
  );

  test(
    'counts and coordinate arrays are separate contracts; published topic parses',
    () {
      final PublicTopicCatalogue catalogue = PublicTopicAdapter.catalogue(
        _fixture('public_topic_summaries.json'),
      );
      expect(catalogue.topics.first.verseCount, 3);
      expect(
        _topic().coordinates.map((PublicTopicCoordinate verse) => verse.key),
        ['1/1/1', '1/1/3', '43/3/16'],
      );
      final PublicTopic live = PublicTopicAdapter.topic(
        _fixture('public_topic_live_authority.json'),
        expectedId: 'authority-of-the-bible',
      );
      expect(live.coordinates, isNotEmpty);
      expect(live.localizedName('af'), 'Gesag van die Bybel');
      final JsonMap wrongSummary = _fixture('public_topic_summaries.json');
      ((wrongSummary['topics']! as List<Object?>).first!
          as JsonMap)['verses'] = [
        [1, 1, 1],
      ];
      expect(
        () => PublicTopicAdapter.catalogue(wrongSummary),
        throwsA(isA<ApiFormatException>()),
      );
      final JsonMap wrongTopic = _fixture('public_topic_single.json')
        ..['verses'] = 3;
      expect(
        () => PublicTopicAdapter.topic(
          wrongTopic,
          expectedId: 'authority-of-the-bible',
        ),
        throwsA(isA<ApiFormatException>()),
      );
    },
  );

  test(
    'invalid identities, duplicate coordinates and mismatched reverse identities fail',
    () {
      final JsonMap duplicate = _fixture('public_topic_single.json')
        ..['verses'] = [
          [1, 1, 1],
          [1, 1, 1],
        ];
      expect(
        () => PublicTopicAdapter.topic(
          duplicate,
          expectedId: 'authority-of-the-bible',
        ),
        throwsA(isA<ApiFormatException>()),
      );
      final JsonMap invalid = _fixture('public_topic_single.json')
        ..['verses'] = [
          [67, 1, 1],
        ];
      expect(
        () => PublicTopicAdapter.topic(
          invalid,
          expectedId: 'authority-of-the-bible',
        ),
        throwsA(isA<ApiFormatException>()),
      );
      expect(
        () => PublicTopicAdapter.topic(
          _fixture('public_topic_single.json'),
          expectedId: 'hope',
        ),
        throwsA(isA<ApiFormatException>()),
      );
      expect(
        () => PublicTopicAdapter.chapter(
          _fixture('public_topic_reverse.json'),
          book: 43,
          chapter: 3,
        ),
        throwsA(isA<ApiFormatException>()),
      );
    },
  );

  test(
    'partial locales fall back to English and empty reverse lookup is success',
    () {
      expect(_topic().localizedName('fr'), 'Authority of the Bible');
      final PublicTopicNames names = PublicTopicAdapter.names(
        _fixture('public_topic_names_af.json'),
        locale: 'af',
      );
      expect(names.names['hope'], isNull);
      final PublicTopicAssociations empty = PublicTopicAdapter.chapter(
        {
          'schema_version': 1,
          'book': 1,
          'chapter': 1,
          'verses': <String, Object?>{},
        },
        book: 1,
        chapter: 1,
      );
      expect(empty.forVerse(1), isEmpty);
      expect(
        PublicTopicAdapter.locales(
          _fixture('public_topic_locales.json'),
        ).last.topicCount,
        1,
      );
    },
  );

  test(
    'on-demand reads use exact ids and no bulk files or public writes',
    () async {
      final List<Uri> requests = [];
      final ApiTransport transport = ApiTransport(
        client: MockClient((http.Request request) async {
          requests.add(request.url);
          expect(request.method, 'GET');
          final String file = switch (request.url.path) {
            '/v1/index.json' => 'public_topic_index.json',
            '/v1/topics.json' => 'public_topic_summaries.json',
            '/v1/topics/authority-of-the-bible.json' =>
              'public_topic_single.json',
            '/v1/verses/1/1.json' => 'public_topic_reverse.json',
            '/v1/locales.json' => 'public_topic_locales.json',
            '/v1/locales/af.json' => 'public_topic_names_af.json',
            _ => throw StateError('Unexpected resource ${request.url}'),
          };
          return http.Response(jsonEncode(_fixture(file)), 200);
        }),
        retryPolicy: const ApiRetryPolicy(maxRetries: 0),
      );
      addTearDown(transport.close);
      final ApiPublicTopicsRepository repository = ApiPublicTopicsRepository(
        transport,
      );
      await repository.discovery();
      await repository.catalogue();
      await repository.locales();
      await repository.names('af');
      await repository.topic('authority-of-the-bible');
      await repository.chapter(1, 1);
      expect(requests, hasLength(6));
      expect(
        requests.every(
          (Uri url) => url.host == 'bookmarks.getbible.net' && !url.hasQuery,
        ),
        isTrue,
      );
      expect(
        () => repository.topic('Authority of the Bible'),
        throwsFormatException,
      );
      expect(() => repository.chapter(1000000042, 7), throwsFormatException);
    },
  );

  test(
    'schema-invalid fresh-cache body is evicted and retry reads corrected resource',
    () async {
      int calls = 0;
      final ApiTransport transport = ApiTransport(
        client: MockClient((_) async {
          calls++;
          return http.Response(
            jsonEncode(
              calls == 1
                  ? {'schema_version': 1}
                  : _fixture('public_topic_single.json'),
            ),
            200,
            headers: {'cache-control': 'max-age=600'},
          );
        }),
        retryPolicy: const ApiRetryPolicy(maxRetries: 0),
      );
      addTearDown(transport.close);
      final ApiPublicTopicsRepository repository = ApiPublicTopicsRepository(
        transport,
      );
      await expectLater(
        repository.topic('authority-of-the-bible'),
        throwsA(isA<ApiFormatException>()),
      );
      expect(
        (await repository.topic('authority-of-the-bible')).name,
        'Authority of the Bible',
      );
      await repository.topic('authority-of-the-bible');
      expect(calls, 2);
    },
  );

  test(
    'catalogue revision revalidates even previously cached/deleted topics',
    () async {
      int revision = 1;
      int topicCalls = 0;
      final ApiTransport transport = ApiTransport(
        client: MockClient((http.Request request) async {
          if (request.url.path.endsWith('/index.json')) {
            final JsonMap index = _fixture('public_topic_index.json')
              ..['catalog_version'] = revision
              ..['checksum'] = (revision == 1 ? 'a' : 'b') * 64;
            return http.Response(
              jsonEncode(index),
              200,
              headers: {'cache-control': 'max-age=600'},
            );
          }
          topicCalls++;
          if (revision == 2) return http.Response('Deleted', 404);
          final JsonMap topic = _fixture('public_topic_single.json')
            ..['id'] = request.url.pathSegments.last.replaceAll('.json', '');
          return http.Response(
            jsonEncode(topic),
            200,
            headers: {'cache-control': 'max-age=600'},
          );
        }),
        retryPolicy: const ApiRetryPolicy(maxRetries: 0),
      );
      addTearDown(transport.close);
      final ApiPublicTopicsRepository repository = ApiPublicTopicsRepository(
        transport,
      );
      await repository.discovery();
      await repository.topic('authority-of-the-bible');
      await repository.topic('hope');
      revision = 2;
      await repository.discovery();
      await expectLater(
        repository.topic('authority-of-the-bible'),
        throwsA(isA<ResourceUnavailableException>()),
      );
      expect(topicCalls, 3);
    },
  );

  test(
    'public browsing/follow/hide is local and canonical coverage does not limit reader',
    () async {
      final LocalDatabase database = await LocalDatabase.memory();
      addTearDown(database.close);
      final List<MarkingGroup> before = await database.getGroups();
      final _TopicsFake repository = _TopicsFake();
      final TopicsController controller = _controller(repository, database);
      addTearDown(controller.dispose);
      await controller.initialize(_context);
      expect(controller.nameOf(controller.catalogue!.topics.last), 'Hope');
      expect(
        controller.nameOf(controller.catalogue!.topics.first),
        'Gesag van die Bybel',
      );
      expect(controller.relatedIds, {'authority-of-the-bible'});
      await controller.setFollowed('authority-of-the-bible', true);
      await controller.setHidden('hope', true);
      final TopicsController restored = _controller(repository, database);
      addTearDown(restored.dispose);
      await restored.initialize(_context);
      expect(restored.followed, {'authority-of-the-bible'});
      expect(restored.hidden, {'hope'});
      await restored.initialize(
        const StudyContext(
          passage: Passage(translation: 'kjv', book: 1000000042, chapter: 7),
          bookName: 'Extended book',
          language: 'en',
        ),
      );
      expect(restored.catalogue!.topics, hasLength(2));
      expect(restored.associationError, isA<FormatException>());
      expect(
        await database.getGroups().then(
          (List<MarkingGroup> groups) =>
              groups.map((MarkingGroup group) => group.toJson()).toList(),
        ),
        before.map((MarkingGroup group) => group.toJson()).toList(),
      );
      expect(await database.getMarkings(), isEmpty);
      expect(await database.getNotes(), isEmpty);
    },
  );

  test('topic switching and dismissal ignore late responses', () async {
    final LocalDatabase database = await LocalDatabase.memory();
    addTearDown(database.close);
    final _TopicsFake repository = _TopicsFake();
    final TopicsController controller = _controller(repository, database);
    addTearDown(controller.dispose);
    await controller.initialize(_context);
    final Completer<PublicTopic> old = Completer<PublicTopic>();
    repository.delayedTopic = old;
    final Future<void> first = controller.selectTopic('authority-of-the-bible');
    repository.delayedTopic = null;
    await controller.selectTopic('hope');
    old.complete(_topic());
    await first;
    expect(controller.selectedTopic!.id, 'hope');
    final Completer<PublicTopic> dismissed = Completer<PublicTopic>();
    repository.delayedTopic = dismissed;
    final Future<void> pending = controller.selectTopic(
      'authority-of-the-bible',
    );
    controller.dismiss();
    dismissed.complete(_topic());
    await pending;
    expect(controller.selectedTopic, isNull);
  });

  test(
    'private copies preserve matching starter/custom identities and notes; repeats are additive and duplicate-safe',
    () async {
      final LocalDatabase database = await LocalDatabase.memory();
      addTearDown(database.close);
      final DateTime created = DateTime.utc(2020);
      final MarkingGroup private = MarkingGroup(
        id: 'authority-of-the-bible',
        name: 'Authority of the Bible',
        color: '#AABBCC',
        updatedAt: created,
      );
      await database.saveGroup(private);
      final VerseNote note = VerseNote(
        id: 'keep-note',
        passage: _context.passage.copyWith(clearVerse: true),
        verse: 1,
        reference: 'Genesis 1:1',
        text: 'Private original',
        createdAt: created,
        updatedAt: created,
      );
      await database.saveNote(note);
      final Marking marker = Marking(
        id: 'keep-marking',
        passage: _context.passage.copyWith(clearVerse: true),
        verse: 1,
        start: null,
        end: null,
        quote: 'Private quote',
        reference: 'Genesis 1:1',
        groupId: private.id,
        createdAt: created,
      );
      await database.saveMarking(marker);
      final List<MarkingGroup> originalGroups = await database.getGroups();
      int id = 0;
      final SqlPublicTopicCopyRepository copies = SqlPublicTopicCopyRepository(
        database,
        createId: () => 'copy-${id++}',
        clock: () => DateTime.utc(2026),
      );
      final PublicTopicCopyPreview preview = await copies.preview(
        topic: _topic(),
        sourceScope: 'bookmarks:v1:test',
        translation: 'kjv',
      );
      expect(preview.alreadyPresent, 0);
      expect(await database.getGroups(), hasLength(originalGroups.length));
      final PublicTopicCopyResult first = await copies.copy(preview);
      expect(first.groupId, startsWith('private-topic-'));
      expect(first.groupId, isNot(private.id));
      expect(first.added, 3);
      final PublicTopicCopyResult again = await copies.copy(preview);
      expect(again.added, 0);
      expect(again.groupId, first.groupId);
      final List<Marking> markings = await database.getMarkings();
      expect(markings, hasLength(4));
      expect(
        markings.firstWhere((Marking item) => item.id == marker.id).toJson(),
        marker.toJson(),
      );
      expect((await database.getNotes()).single.toJson(), note.toJson());
      final List<MarkingGroup> groups = await database.getGroups();
      for (final MarkingGroup original in originalGroups) {
        expect(
          groups
              .firstWhere((MarkingGroup item) => item.id == original.id)
              .toJson(),
          original.toJson(),
        );
      }
      final JsonMap updated = _fixture('public_topic_single.json')
        ..['name'] = 'Renamed public topic'
        ..['verses'] = [
          [1, 1, 1],
          [43, 3, 16],
          [43, 3, 17],
        ];
      final PublicTopicCopyPreview update = await copies.preview(
        topic: PublicTopicAdapter.topic(updated, expectedId: _topic().id),
        sourceScope: 'bookmarks:v1:test',
        translation: 'web',
      );
      expect(update.alreadyPresent, 2);
      expect((await copies.copy(update)).added, 1);
      expect(
        await database.getMarkings(),
        hasLength(5),
      ); // Removed public 1:3 stays private.
      expect(
        (await database.getGroups())
            .firstWhere((MarkingGroup item) => item.id == first.groupId)
            .name,
        preview.groupName,
      );
    },
  );

  test(
    'transaction collision rolls back the entire copy and does not write provenance',
    () async {
      final LocalDatabase database = await LocalDatabase.memory();
      addTearDown(database.close);
      final MarkingGroup group = (await database.getGroups()).first;
      final DateTime now = DateTime.utc(2026);
      final Marking existing = Marking(
        id: 'collision',
        passage: _context.passage.copyWith(clearVerse: true),
        verse: 3,
        start: null,
        end: null,
        quote: 'kept',
        reference: 'Genesis 1:3',
        groupId: group.id,
        createdAt: now,
      );
      await database.saveMarking(existing);
      final MarkingGroup copied = MarkingGroup(
        id: 'fresh-private-group',
        name: 'New copy',
        color: '#FFFFFF',
        updatedAt: now,
      );
      final Marking invalid = Marking(
        id: existing.id,
        passage: _context.passage.copyWith(clearVerse: true),
        verse: 1,
        start: null,
        end: null,
        quote: '',
        reference: 'Genesis 1:1',
        groupId: copied.id,
        createdAt: now,
      );
      await expectLater(
        database.commitPublicTopicCopy(
          provenanceKey: 'test-copy-provenance',
          groupId: copied.id,
          newGroup: copied,
          newMarkings: [invalid],
        ),
        throwsA(isA<StorageException>()),
      );
      expect(
        (await database.getGroups()).any(
          (MarkingGroup item) => item.id == copied.id,
        ),
        isFalse,
      );
      expect((await database.getMarkings()).single.toJson(), existing.toJson());
      expect(await database.readSetting('test-copy-provenance'), isNull);
    },
  );

  test(
    'concurrent repeated imports serialize and deleted copies can be recreated',
    () async {
      final LocalDatabase database = await LocalDatabase.memory();
      addTearDown(database.close);
      final SqlPublicTopicCopyRepository copies = SqlPublicTopicCopyRepository(
        database,
      );
      final PublicTopicCopyPreview preview = await copies.preview(
        topic: _topic(),
        sourceScope: 'bookmarks:v1:test',
        translation: 'kjv',
      );
      final List<PublicTopicCopyResult> results = await Future.wait([
        copies.copy(preview),
        copies.copy(preview),
      ]);
      expect(results.map((PublicTopicCopyResult result) => result.added), [
        3,
        0,
      ]);
      expect(results.first.groupId, results.last.groupId);
      expect(await database.getMarkings(), hasLength(3));
      await database.deleteGroup(results.first.groupId);
      final PublicTopicCopyResult recreated = await copies.copy(preview);
      expect(recreated.groupId, isNot(results.first.groupId));
      expect(recreated.added, 3);
    },
  );

  testWidgets(
    'topics preview retains selected Bible and copying requires concrete confirmation',
    (WidgetTester tester) async {
      final LocalDatabase database = await LocalDatabase.memory();
      addTearDown(database.close);
      final TopicsController controller = _controller(_TopicsFake(), database);
      addTearDown(controller.dispose);
      final List<ReferenceRequest> requests = [];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TopicsPanel(
              controller: controller,
              context: _context,
              onPreviewReference: (ReferenceRequest request) async {
                requests.add(request);
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Gesag van die Bybel'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Genesis 1'));
      await tester.pumpAndSettle();
      expect(requests.single, isA<StructuredReferenceRequest>());
      expect(requests.single.translation, 'kjv');
      expect(
        (requests.single as StructuredReferenceRequest)
            .selections
            .single
            .verses,
        [1, 3],
      );
      await tester.tap(find.text('Copy to my markings'));
      await tester.pumpAndSettle();
      expect(find.textContaining('3 new whole-verse markings'), findsOneWidget);
      expect(await database.getMarkings(), isEmpty);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(await database.getMarkings(), isEmpty);
      await tester.tap(find.text('Copy to my markings'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Copy markings'));
      await tester.pumpAndSettle();
      expect(await database.getMarkings(), hasLength(3));
    },
  );

  testWidgets(
    'topic browsing/detail stay scrollable at 200 percent text and narrow keyboard-height viewport',
    (WidgetTester tester) async {
      tester.view.physicalSize = const Size(320, 400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final LocalDatabase database = await LocalDatabase.memory();
      addTearDown(database.close);
      final TopicsController controller = _controller(_TopicsFake(), database);
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          builder: (BuildContext context, Widget? child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(2)),
            child: child!,
          ),
          home: Scaffold(
            body: TopicsPanel(
              controller: controller,
              context: _context,
              onPreviewReference: (_) async {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await controller.selectTopic('authority-of-the-bible');
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );
}

TopicsController _controller(
  PublicTopicsRepository repository,
  LocalDatabase database,
) => TopicsController(
  repository: repository,
  preferences: SqlStudyPreferencesRepository(database),
  copyRepository: SqlPublicTopicCopyRepository(database),
);

final class _TopicBible extends Fake implements BibleRepository {
  @override
  Future<RepositoryResult<List<BibleBook>>> getBooks(
    String translation, {
    bool forceRefresh = false,
  }) async => RepositoryResult<List<BibleBook>>(
    data: const <BibleBook>[
      BibleBook(number: 1, name: 'Genesis', sha: 'discovered'),
    ],
    freshness: CacheFreshness.fresh,
    checkedAt: DateTime.utc(2026),
  );
}

final class _TopicsFake
    implements PublicTopicsRepository, InstalledStudyResource {
  bool installed = false;
  Completer<bool>? statusPending;
  @override
  Future<bool> isInstalled(String id) =>
      statusPending?.future ?? Future.value(installed);
  Completer<PublicTopic>? delayedTopic;
  @override
  String get sourceScope => 'bookmarks:v1:fake';
  @override
  Future<PublicTopicDiscovery> discovery({
    RequestCancellation? cancellation,
  }) async => PublicTopicAdapter.discovery(_fixture('public_topic_index.json'));
  @override
  Future<PublicTopicCatalogue> catalogue({
    RequestCancellation? cancellation,
  }) async =>
      PublicTopicAdapter.catalogue(_fixture('public_topic_summaries.json'));
  @override
  Future<List<PublicTopicLocale>> locales({
    RequestCancellation? cancellation,
  }) async => PublicTopicAdapter.locales(_fixture('public_topic_locales.json'));
  @override
  Future<PublicTopicNames> names(
    String locale, {
    RequestCancellation? cancellation,
  }) async => PublicTopicAdapter.names(
    _fixture('public_topic_names_af.json'),
    locale: locale,
  );
  @override
  Future<PublicTopicAssociations> chapter(
    int book,
    int chapter, {
    RequestCancellation? cancellation,
  }) async => PublicTopicAdapter.chapter(
    _fixture('public_topic_reverse.json'),
    book: book,
    chapter: chapter,
  );
  @override
  Future<PublicTopic> topic(
    String id, {
    RequestCancellation? cancellation,
  }) async {
    if (delayedTopic != null) return delayedTopic!.future;
    final JsonMap record = _fixture('public_topic_single.json')..['id'] = id;
    return PublicTopicAdapter.topic(record, expectedId: id);
  }
}
