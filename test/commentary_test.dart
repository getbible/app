import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:getbible_live/application/commentary_controller.dart';
import 'package:getbible_live/core/errors.dart';
import 'package:getbible_live/core/json.dart';
import 'package:getbible_live/core/request_cancellation.dart';
import 'package:getbible_live/data/api/api_transport.dart';
import 'package:getbible_live/data/api/commentary_adapter.dart';
import 'package:getbible_live/data/api/service_envelope_adapters.dart';
import 'package:getbible_live/data/repositories/api_commentary_repository.dart';
import 'package:getbible_live/domain/models/commentary.dart';
import 'package:getbible_live/domain/models/passage.dart';
import 'package:getbible_live/domain/models/reference.dart';
import 'package:getbible_live/domain/models/service_envelopes.dart';
import 'package:getbible_live/domain/models/study_context.dart';
import 'package:getbible_live/domain/repositories/commentary_repository.dart';
import 'package:getbible_live/domain/repositories/study_preferences_repository.dart';
import 'package:getbible_live/presentation/widgets/commentary_panel.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  late JsonMap fixture;
  setUp(() {
    fixture = requireJsonMap(
      jsonDecode(File('test/fixtures/commentary_v1.json').readAsStringSync()),
      'commentary fixtures',
    );
  });

  test(
    'ranges anchored earlier, multiple comments and introductions preserve source order',
    () {
      final CommentaryChapter chapter = CommentaryAdapter.chapter(
        fixture['chapter'],
        'fixture',
        1,
        1,
      );
      expect(
        chapter.entriesForVerse(5).map((CommentaryEntry entry) => entry.verse),
        <int>[3, 5],
      );
      expect(chapter.entriesForVerse(2), isEmpty);
      expect(chapter.entriesForVerse(null), chapter.entries);
      expect(chapter.entries.first.isIntroduction, isTrue);
      expect(chapter.entries[1].verses, <int>[3, 4, 5]);
      expect(chapter.entries[1].osis, 'Gen.1.3');
      expect(
        chapter.entries[1].text,
        'First ranged comment.\n\n<b>Plain text stays plain.</b>',
      );
      expect(chapter.entries[2].references, isEmpty);
      final CommentaryChapter introduction = CommentaryAdapter.chapter(
        fixture['book_intro'],
        'fixture',
        1,
        0,
      );
      expect(introduction.entries.single.isIntroduction, isTrue);
      expect(introduction.entries.single.coverageLabel, 'Book introduction');
      expect(jsonDecode(jsonEncode(chapter.source)), fixture['chapter']);
      expect(
        () => chapter.entries[1].source['text'] = 'changed',
        throwsUnsupportedError,
      );
    },
  );

  test(
    'malformed ranges, wrong chapter identity and absent required fields reject',
    () {
      for (final List<int> verses in <List<int>>[
        <int>[4, 5],
        <int>[3, 3],
        <int>[2, 3],
        <int>[3],
      ]) {
        final JsonMap invalid = _clone(fixture['chapter']);
        final JsonMap entry = requireJsonMap(
          (invalid['entries'] as List)[1],
          'entry',
        );
        entry['verses'] = verses;
        (invalid['entries'] as List)[1] = entry;
        expect(
          () => CommentaryAdapter.chapter(invalid, 'fixture', 1, 1),
          throwsFormatException,
        );
      }
      expect(
        () => CommentaryAdapter.chapter(fixture['chapter'], 'fixture', 1, 2),
        throwsFormatException,
      );
      final JsonMap invalid = _clone(fixture['chapter']);
      invalid.remove('language');
      expect(
        () => CommentaryAdapter.chapter(invalid, 'fixture', 1, 1),
        throwsFormatException,
      );
    },
  );

  test(
    'cross-chapter quotations show once while retaining all source coverage',
    () {
      final CommentaryEntry last = CommentaryAdapter.chapter(
        fixture['chapter'],
        'fixture',
        1,
        1,
      ).entries.last;
      final CommentaryEntry next = CommentaryAdapter.chapter(
        fixture['next_chapter'],
        'fixture',
        1,
        2,
      ).entries.single;
      final List<CommentaryQuotation> grouped = CommentaryQuotation.group(
        <CommentaryEntry>[last, next],
      );
      expect(grouped, hasLength(1));
      expect(
        grouped.single.entries.map((CommentaryEntry entry) => entry.osis),
        <String>['Gen.1.8', 'Gen.2.1'],
      );
      expect(
        grouped.single.entries.map((CommentaryEntry entry) => entry.verses),
        <List<int>>[
          <int>[8, 9],
          <int>[1, 2],
        ],
      );
      expect(grouped.single.entries.first.references, isNotEmpty);
      final CommentaryEntry distinct = CommentaryAdapter.chapter(
        fixture['chapter'],
        'fixture',
        1,
        1,
      ).entries[2];
      expect(
        CommentaryQuotation.group(<CommentaryEntry>[last, distinct, next]),
        hasLength(3),
      );
    },
  );

  test(
    'metadata retains attribution, source v2 versification and sparse coverage',
    () {
      final CommentaryMetadata metadata = CommentaryAdapter.metadata(
        fixture['metadata'],
        'fixture',
      );
      expect(metadata.references.api, 'getbible-v2');
      expect(metadata.references.versification, 'KJV');
      expect(metadata.sourceName, 'CrossWire SWORD');
      expect(metadata.license, 'Public Domain');
      expect(jsonDecode(jsonEncode(metadata.source)), fixture['metadata']);
      final CommentaryCoverage coverage = CommentaryAdapter.coverage(
        fixture['coverage'],
        'fixture',
      );
      expect(coverage.covers(1, 0), isTrue);
      expect(coverage.covers(1, 1), isTrue);
      expect(coverage.covers(1, 2), isFalse);
      expect(coverage.covers(43, 1), isFalse);
      expect(coverage.covers(43, 2), isTrue);
      expect(coverage.covers(1000000042, 7), isFalse);
    },
  );

  test(
    'repository requests only discovery metadata coverage and covered chapter',
    () async {
      final List<String> paths = <String>[];
      final ApiTransport transport = ApiTransport(
        client: MockClient((http.Request request) async {
          paths.add(request.url.path);
          final Object? value = switch (request.url.path) {
            '/v1/commentaries.json' => fixture['catalogue'],
            '/v1/fixture/metadata.json' => fixture['metadata'],
            '/v1/fixture/books.json' => fixture['coverage'],
            '/v1/fixture/1/1.json' => fixture['chapter'],
            _ => throw StateError('Unexpected resource ${request.url}'),
          };
          return http.Response.bytes(utf8.encode(jsonEncode(value)), 200);
        }),
      );
      addTearDown(transport.close);
      final ApiCommentaryRepository repository = ApiCommentaryRepository(
        transport,
      );
      await repository.catalogue();
      await repository.metadata('fixture');
      await repository.coverage('fixture');
      await repository.chapter('fixture', 1, 1);
      expect(paths, <String>[
        '/v1/commentaries.json',
        '/v1/fixture/metadata.json',
        '/v1/fixture/books.json',
        '/v1/fixture/1/1.json',
      ]);
      expect(
        () => repository.chapter('../fixture', 1, 1),
        throwsFormatException,
      );
      expect(() => repository.chapter('fixture', 84, 1), throwsFormatException);
      expect(paths, hasLength(4));
    },
  );

  test(
    'fresh malformed chapter is evicted so Retry gets corrected source',
    () async {
      int reads = 0;
      final ApiTransport transport = ApiTransport(
        client: MockClient((_) async {
          reads += 1;
          return http.Response.bytes(
            utf8.encode(
              jsonEncode(
                reads == 1
                    ? <String, Object?>{'schema': 'invalid'}
                    : fixture['chapter'],
              ),
            ),
            200,
            headers: <String, String>{'cache-control': 'max-age=600'},
          );
        }),
      );
      addTearDown(transport.close);
      final ApiCommentaryRepository repository = ApiCommentaryRepository(
        transport,
      );
      await expectLater(
        repository.chapter('fixture', 1, 1),
        throwsA(isA<ApiFormatException>()),
      );
      expect((await repository.chapter('fixture', 1, 1)).entries, hasLength(4));
      await repository.chapter('fixture', 1, 1);
      expect(reads, 2);
    },
  );

  test(
    'book introduction loads chapter zero without inventing Scripture',
    () async {
      final _Repository repository = _Repository(fixture);
      final CommentaryController controller = CommentaryController(
        repository: repository,
        preferences: _Preferences(),
      );
      addTearDown(controller.dispose);
      await controller.open(_context(chapter: 0, verse: null));
      expect(controller.chapter!.chapter, 0);
      expect(controller.entries.single.isIntroduction, isTrue);
      expect(controller.canSelectVerse, isFalse);
      expect(repository.chapterReads, <String>['fixture/1/0']);
    },
  );

  test(
    'missing coverage and absent verse are successful distinct states',
    () async {
      final _Repository repository = _Repository(fixture);
      final CommentaryController controller = CommentaryController(
        repository: repository,
        preferences: _Preferences(),
      );
      addTearDown(controller.dispose);
      await controller.open(_context(chapter: 2));
      expect(
        controller.availability,
        CommentaryAvailability.unavailableChapter,
      );
      expect(repository.chapterReads, isEmpty);
      expect(controller.error, isNull);
      await controller.open(_context(verse: 2));
      expect(controller.availability, CommentaryAvailability.unavailableVerse);
      expect(controller.error, isNull);
      controller.setVerseMode(false);
      expect(controller.entries, hasLength(4));
      expect(repository.chapterReads, hasLength(1));
    },
  );

  test(
    'nonmatching language requires explicit choice and never silently substitutes',
    () async {
      final _Repository repository = _Repository(fixture);
      final _Preferences preferences = _Preferences();
      final CommentaryController controller = CommentaryController(
        repository: repository,
        preferences: preferences,
      );
      addTearDown(controller.dispose);
      await controller.open(_context(language: 'ar'));
      expect(controller.availability, CommentaryAvailability.selectResource);
      expect(repository.metadataReads, isEmpty);
      await controller.selectModule('fixture');
      expect(controller.entries, isNotEmpty);
      expect(controller.isCompatible(controller.selectedModule!), isFalse);
      expect(preferences.saved, isEmpty);
    },
  );

  test(
    'saved compatible choice survives restart and save failure stays bounded',
    () async {
      final _Repository repository = _Repository(fixture, secondModule: true);
      final _Preferences preferences = _Preferences()..saved['en'] = 'second';
      final CommentaryController controller = CommentaryController(
        repository: repository,
        preferences: preferences,
      );
      addTearDown(controller.dispose);
      await controller.open(_context());
      expect(controller.selectedModule!.id, 'second');
      preferences.failWrites = true;
      await controller.selectModule('fixture');
      await Future<void>.delayed(Duration.zero);
      expect(controller.preferenceWarning, contains('not saved'));
      expect(controller.entries, isNotEmpty);
      expect(controller.error, isNull);
    },
  );

  test(
    'late module and dismissed requests cannot replace current Study state',
    () async {
      final _Repository repository = _Repository(fixture, secondModule: true);
      final Completer<CommentaryChapter> old = Completer<CommentaryChapter>();
      repository.delayedChapter = old;
      final CommentaryController controller = CommentaryController(
        repository: repository,
        preferences: _Preferences(),
      );
      addTearDown(controller.dispose);
      final Future<void> first = controller.open(_context());
      await Future<void>.delayed(Duration.zero);
      repository.delayedChapter = null;
      await controller.selectModule('second');
      expect(controller.chapter!.commentary, 'second');
      old.complete(
        CommentaryAdapter.chapter(fixture['chapter'], 'fixture', 1, 1),
      );
      await first;
      expect(controller.chapter!.commentary, 'second');
      final Completer<CommentaryChapter> closed =
          Completer<CommentaryChapter>();
      repository.delayedChapter = closed;
      final Future<void> pending = controller.selectModule('fixture');
      await Future<void>.delayed(Duration.zero);
      controller.close();
      closed.complete(
        CommentaryAdapter.chapter(fixture['chapter'], 'fixture', 1, 1),
      );
      await pending;
      expect(controller.context, isNull);
      expect(controller.chapter, isNull);
      expect(controller.isLoading, isFalse);
    },
  );

  testWidgets('plain native text and citation preview retain selected Bible', (
    WidgetTester tester,
  ) async {
    final CommentaryController controller = CommentaryController(
      repository: _Repository(fixture),
      preferences: _Preferences(),
    );
    addTearDown(controller.dispose);
    ReferenceRequest? request;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CommentaryPanel(
            controller: controller,
            context: _context(),
            onPreviewReference: (ReferenceRequest value) async {
              request = value;
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.text('First ranged comment.\n\n<b>Plain text stays plain.</b>'),
      findsOneWidget,
    );
    expect(find.text('Second comment for the same verse.'), findsOneWidget);
    expect(find.text('Chapter introduction.'), findsNothing);
    await tester.ensureVisible(find.text('Gen. 1:1–2'));
    await tester.tap(find.text('Gen. 1:1–2'));
    expect(request, isA<StructuredReferenceRequest>());
    expect(request!.translation, 'other');
    expect(request!.sourceLabel, 'Genesis 1:1-2');
    expect(
      (request! as StructuredReferenceRequest).selections.single.verses,
      <int>[1, 2],
    );
    await tester.tap(find.text('Whole chapter'));
    await tester.pump();
    expect(find.text('Chapter introduction.'), findsOneWidget);
  });

  testWidgets(
    'narrow RTL 200 percent text remains accessible without overflow',
    (WidgetTester tester) async {
      tester.view.physicalSize = const Size(340, 600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final CommentaryController controller = CommentaryController(
        repository: _Repository(fixture),
        preferences: _Preferences(),
      );
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(
              size: Size(340, 600),
              textScaler: TextScaler.linear(2),
            ),
            child: Directionality(
              textDirection: TextDirection.rtl,
              child: Scaffold(
                body: CommentaryPanel(
                  controller: controller,
                  context: _context(),
                  onPreviewReference: (_) async {},
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(find.text('Gen. 1:1–2'));
      expect(tester.takeException(), isNull);
      expect(find.byType(SelectableText), findsWidgets);
    },
  );
}

JsonMap _clone(Object? value) =>
    requireJsonMap(jsonDecode(jsonEncode(value)), 'fixture');
StudyContext _context({
  int chapter = 1,
  int? verse = 5,
  String language = 'en',
}) => StudyContext(
  passage: Passage(
    translation: 'other',
    book: 1,
    chapter: chapter,
    verse: verse,
  ),
  bookName: 'Genesis',
  language: language,
  translationName: 'Selected Bible',
);

final class _Repository implements CommentaryRepository {
  _Repository(this.fixture, {this.secondModule = false});
  final JsonMap fixture;
  final bool secondModule;
  final List<String> metadataReads = <String>[];
  final List<String> chapterReads = <String>[];
  Completer<CommentaryChapter>? delayedChapter;

  @override
  Future<CommentaryCatalogue> catalogue({
    RequestCancellation? cancellation,
  }) async {
    final JsonMap value = _clone(fixture['catalogue']);
    if (secondModule) {
      final JsonMap second = _clone((value['commentaries'] as List).single)
        ..['id'] = 'second'
        ..['name'] = 'Second Commentary';
      (value['commentaries'] as List).add(second);
      value['module_count'] = 2;
    }
    return ServiceEnvelopeAdapters.commentaries(value);
  }

  @override
  Future<CommentaryMetadata> metadata(
    String module, {
    RequestCancellation? cancellation,
  }) async {
    metadataReads.add(module);
    return CommentaryAdapter.metadata(
      _clone(fixture['metadata'])..['id'] = module,
      module,
    );
  }

  @override
  Future<CommentaryCoverage> coverage(
    String module, {
    RequestCancellation? cancellation,
  }) async => CommentaryAdapter.coverage(
    _clone(fixture['coverage'])..['commentary'] = module,
    module,
  );

  @override
  Future<CommentaryChapter> chapter(
    String module,
    int book,
    int chapter, {
    RequestCancellation? cancellation,
  }) async {
    chapterReads.add('$module/$book/$chapter');
    if (delayedChapter != null) return delayedChapter!.future;
    return CommentaryAdapter.chapter(
      _clone(fixture[chapter == 0 ? 'book_intro' : 'chapter'])
        ..['commentary'] = module,
      module,
      book,
      chapter,
    );
  }
}

final class _Preferences implements StudyPreferencesRepository {
  final Map<String, String> saved = <String, String>{};
  bool failWrites = false;
  @override
  Future<String?> commentary(String language) async => saved[language];
  @override
  Future<void> setCommentary(String language, String module) async {
    if (failWrites) throw const StorageException('Disk unavailable.');
    saved[language] = module;
  }

  @override
  Future<String?> dictionary(String language, String family) async => null;
  @override
  Future<void> setDictionary(
    String language,
    String family,
    String module,
  ) async {}
  @override
  Future<bool> topicFollowed(String scopedTopic) async => false;
  @override
  Future<bool> topicHidden(String scopedTopic) async => false;
  @override
  Future<void> setTopicFollowed(String scopedTopic, bool followed) async {}
  @override
  Future<void> setTopicHidden(String scopedTopic, bool hidden) async {}
}
