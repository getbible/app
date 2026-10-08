import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:getbible_live/application/grouped_reference_lookup.dart';
import 'package:getbible_live/application/reference_preview_controller.dart';
import 'package:getbible_live/core/errors.dart';
import 'package:getbible_live/core/json.dart';
import 'package:getbible_live/core/request_cancellation.dart';
import 'package:getbible_live/data/api/api_transport.dart';
import 'package:getbible_live/data/api/query_api_client.dart';
import 'package:getbible_live/domain/models/bible.dart';
import 'package:getbible_live/domain/models/cache.dart';
import 'package:getbible_live/domain/models/reference.dart';
import 'package:getbible_live/domain/repositories/bible_repository.dart';
import 'package:getbible_live/domain/repositories/query_repository.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

JsonMap _compact({
  int chapter = 3,
  int verse = 16,
  String text = '  Scripture\ntext  ',
}) => <String, Object?>{
  'kjv_43_$chapter': <String, Object?>{
    'book_nr': 43,
    'chapter': chapter,
    'ref': <String>['John $chapter:$verse', 'Johannes $chapter:$verse'],
    'verses': <Object?>[
      <String, Object?>{
        'verse': verse,
        'name': 'John $chapter:$verse',
        'text': text,
        'paragraph': true,
        'tokens': <Object?>[
          <String, Object?>{
            'token': 'the world',
            'lemma': <String, Object?>{
              'strong': <String>['G3588', 'G2889'],
              'lemma.TR': <String>['τον', 'κοσμον'],
            },
            'src': <int>[6, 7],
            'word_start': 5,
            'word_end': 6,
          },
        ],
        'source_extension': <String, Object?>{
          'nested': <int>[1, 2],
        },
        'spans': <Object?>[],
      },
    ],
    'future_metadata': 'retained',
  },
};

void main() {
  test(
    'published compact Query fixture round-trips without synthetic chapter metadata',
    () {
      final JsonMap json = requireJsonMap(
        jsonDecode(
          File('test/fixtures/query_v3_compact.json').readAsStringSync(),
        ),
        'Query fixture',
      );
      final ReferenceResult result = ReferenceResult.fromJson(
        json,
        translation: 'kjv',
        reference: 'John 3:16',
      );
      expect(result.chapters.single.toJson(), json['kjv_43_3']);
    },
  );
  test(
    'compact Query envelope retains source identities, enrichment and ref arrays',
    () {
      final JsonMap json = _compact();
      final ReferenceResult result = ReferenceResult.fromJson(
        json,
        translation: 'kjv',
        reference: 'John 3:16',
      );
      final ReferenceChapter chapter = result.chapters.single;
      expect(chapter.bookNumber, 43);
      expect(chapter.verses.single.chapter, 3);
      expect(chapter.verses.single.verse, 16);
      expect(chapter.verses.single.text, '  Scripture\ntext  ');
      expect(chapter.toJson(), json['kjv_43_3']);
      expect(chapter.toJson().containsKey('editorial'), isFalse);
      expect(result.passageFor(chapter, chapter.verses.single).verse, 16);
    },
  );

  test('incompatible chapter and translation identities are rejected', () {
    final JsonMap json = _compact();
    final JsonMap chapter = json['kjv_43_3']! as JsonMap;
    chapter['abbreviation'] = 'other';
    expect(
      () => ReferenceResult.fromJson(
        json,
        translation: 'kjv',
        reference: 'John 3:16',
      ),
      throwsFormatException,
    );
    chapter.remove('abbreviation');
    final JsonMap verse =
        (chapter['verses']! as List<Object?>).first! as JsonMap;
    verse['chapter'] = 4;
    expect(
      () => ReferenceResult.fromJson(
        json,
        translation: 'kjv',
        reference: 'John 3:16',
      ),
      throwsFormatException,
    );
    verse.remove('chapter');
    verse.remove('name');
    expect(
      () => ReferenceResult.fromJson(
        json,
        translation: 'kjv',
        reference: 'John 3:16',
      ),
      throwsFormatException,
    );
  });

  test(
    'Query URI encodes a citation as one path segment without query parameters',
    () async {
      const String reference = 'John 3:16/17?source=1#note & quoted';
      final List<Uri> requested = <Uri>[];
      final MockClient client = MockClient((http.Request request) async {
        requested.add(request.url);
        return http.Response.bytes(utf8.encode(jsonEncode(_compact())), 200);
      });
      final ApiTransport transport = ApiTransport(
        client: client,
        retryPolicy: const ApiRetryPolicy(maxRetries: 0),
      );
      addTearDown(transport.close);
      final ReferenceResult result = await QueryApiClient(
        transport: transport,
      ).query('KJV', reference);
      expect(requested.single.pathSegments, <String>['v3', 'kjv', reference]);
      expect(requested.single.hasQuery, isFalse);
      expect(requested.single.hasFragment, isFalse);
      expect(result.translation, 'kjv');
    },
  );

  test(
    'unknown translation and missing reference preserve HTTP 404 without fallback',
    () async {
      final List<Uri> requested = <Uri>[];
      final ApiTransport transport = ApiTransport(
        client: MockClient((http.Request request) async {
          requested.add(request.url);
          return http.Response('<html>Not found</html>', 404);
        }),
        retryPolicy: const ApiRetryPolicy(maxRetries: 0),
      );
      addTearDown(transport.close);
      await expectLater(
        QueryApiClient(transport: transport).query('unknown', 'John 3:16'),
        throwsA(isA<ResourceUnavailableException>()),
      );
      expect(requested, hasLength(1));
      expect(requested.single.pathSegments[1], 'unknown');
    },
  );

  for (final String invalid in <String>[
    '{"unexpected": {}}',
    '{"kjv_43_3": {"book_nr": 43, "chapter": 3, "verses": []}}',
    '{invalid JSON',
  ]) {
    test(
      'schema-invalid or malformed fresh Query cache is evicted before retry: $invalid',
      () async {
        int requests = 0;
        final ApiTransport transport = ApiTransport(
          client: MockClient((http.Request request) async {
            requests += 1;
            return http.Response.bytes(
              utf8.encode(requests == 1 ? invalid : jsonEncode(_compact())),
              200,
              headers: <String, String>{'cache-control': 'max-age=600'},
            );
          }),
          retryPolicy: const ApiRetryPolicy(maxRetries: 0),
        );
        addTearDown(transport.close);
        final QueryApiClient api = QueryApiClient(transport: transport);
        await expectLater(
          api.query('kjv', 'John 3:16'),
          throwsA(isA<ApiFormatException>()),
        );
        final ReferenceResult result = await api.query('kjv', 'John 3:16');
        expect(requests, 2);
        expect(result.chapters.single.verses.single.verse, 16);
        await api.query('kjv', 'John 3:16');
        expect(
          requests,
          2,
          reason:
              'Only the invalid cache body is discarded; corrected Scripture remains cacheable.',
        );
      },
    );
  }

  test(
    'structured selection splits ranges and rejects successful partial responses',
    () async {
      final _QueryRepository query = _QueryRepository();
      final GroupedReferenceLookup lookup = _lookup(query);
      final StructuredReferenceRequest request = StructuredReferenceRequest(
        translation: 'kjv',
        sourceLabel: 'Johannes 3',
        selections: <ReferenceSelection>[
          ReferenceSelection(
            book: 43,
            chapter: 3,
            verses: List<int>.generate(450, (int index) => index + 1),
          ),
        ],
      );
      final ReferenceResult result = await lookup.lookup(request);
      expect(query.requests, <String>[
        'John 3:1-200',
        'John 3:201-400',
        'John 3:401-450',
      ]);
      expect(result.verseCount, 450);
      expect(result.chapters.single.verses.last.verse, 450);
      expect(request.label, 'Johannes 3');
      query.response = (String translation, String reference) async =>
          ReferenceResult.fromJson(
            _compact(),
            translation: translation,
            reference: reference,
          );
      await expectLater(
        lookup.lookup(request),
        throwsA(isA<ReferenceLookupException>()),
      );
    },
  );

  test(
    'noncontiguous multi-chapter selections preserve IDs and obey eight-reference bound',
    () async {
      final _QueryRepository query = _QueryRepository();
      final StructuredReferenceRequest request = StructuredReferenceRequest(
        translation: 'kjv',
        selections: <ReferenceSelection>[
          ReferenceSelection(
            book: 43,
            chapter: 3,
            verses: List<int>.generate(17, (int index) => index * 2 + 1),
          ),
          ReferenceSelection(book: 43, chapter: 4, verses: <int>[7, 9]),
        ],
      );
      final ReferenceResult result = await _lookup(query).lookup(request);
      expect(
        query.requests.map((String value) => value.split(';').length),
        <int>[8, 8, 3],
      );
      expect(
        result.chapters.map((ReferenceChapter value) => value.chapter),
        <int>[3, 4],
      );
      expect(
        result.chapters.first.verses.map((Verse value) => value.verse),
        List<int>.generate(17, (int index) => index * 2 + 1),
      );
    },
  );

  test(
    'structured batches obey character bounds using discovered translated names',
    () async {
      final String bookName = List<String>.filled(120, 'é').join();
      final _QueryRepository query = _QueryRepository(bookName: bookName);
      final GroupedReferenceLookup lookup = _lookup(query, bookName: bookName);
      final ReferenceResult result = await lookup.lookup(
        StructuredReferenceRequest(
          translation: 'kjv',
          sourceLabel: 'Different source language',
          selections: <ReferenceSelection>[
            ReferenceSelection(
              book: 43,
              chapter: 3,
              verses: <int>[1, 3, 5, 7, 9, 11],
            ),
          ],
        ),
      );
      expect(query.requests, hasLength(2));
      expect(
        query.requests.every((String text) => text.runes.length <= 512),
        isTrue,
      );
      expect(
        query.requests.every((String text) => text.startsWith(bookName)),
        isTrue,
      );
      expect(result.verseCount, 6);
    },
  );

  test('one failed batch exposes no successful partial preview', () async {
    final _QueryRepository query = _QueryRepository();
    int call = 0;
    query.response = (String translation, String reference) async {
      call += 1;
      if (call == 2) throw const NetworkException('Second batch failed.');
      return query.fixture(translation, reference);
    };
    final ReferencePreviewController controller = ReferencePreviewController(
      lookup: _lookup(query),
    );
    addTearDown(controller.dispose);
    await controller.open(
      StructuredReferenceRequest(
        translation: 'kjv',
        selections: <ReferenceSelection>[
          ReferenceSelection(
            book: 43,
            chapter: 3,
            verses: List<int>.generate(201, (int index) => index + 1),
          ),
        ],
      ),
    );
    expect(controller.result, isNull);
    expect(controller.error, isA<NetworkException>());
    expect(controller.isLoading, isFalse);
  });

  test(
    'late response after replacement or close cannot update a preview',
    () async {
      final Map<String, Completer<ReferenceResult>> pending =
          <String, Completer<ReferenceResult>>{};
      final _QueryRepository query = _QueryRepository();
      query.response = (String translation, String reference) {
        final Completer<ReferenceResult> completer =
            Completer<ReferenceResult>();
        pending[reference] = completer;
        return completer.future;
      };
      final ReferencePreviewController controller = ReferencePreviewController(
        lookup: _lookup(query),
      );
      addTearDown(controller.dispose);
      final Future<void> old = controller.open(
        const TextReferenceRequest(translation: 'kjv', reference: 'John 3:1'),
      );
      final Future<void> current = controller.open(
        const TextReferenceRequest(translation: 'kjv', reference: 'John 3:16'),
      );
      pending['John 3:16']!.complete(query.fixture('kjv', 'John 3:16'));
      await current;
      expect(controller.result!.chapters.single.verses.single.verse, 16);
      pending['John 3:1']!.complete(query.fixture('kjv', 'John 3:1'));
      await old;
      expect(controller.result!.chapters.single.verses.single.verse, 16);
      final Future<void> dismissed = controller.open(
        const TextReferenceRequest(translation: 'kjv', reference: 'John 3:2'),
      );
      controller.close();
      pending['John 3:2']!.complete(query.fixture('kjv', 'John 3:2'));
      await dismissed;
      expect(controller.isVisible, isFalse);
      expect(controller.result, isNull);
      expect(controller.historyLength, 0);
    },
  );

  test(
    'citation back history is bounded and restores loaded results without fetching',
    () async {
      final _QueryRepository query = _QueryRepository();
      final ReferencePreviewController controller = ReferencePreviewController(
        lookup: _lookup(query),
        historyLimit: 2,
      );
      addTearDown(controller.dispose);
      for (int verse = 1; verse <= 5; verse += 1) {
        await controller.open(
          TextReferenceRequest(translation: 'kjv', reference: 'John 3:$verse'),
        );
      }
      expect(controller.historyLength, 2);
      await controller.goBack();
      expect(controller.result!.chapters.single.verses.single.verse, 4);
      await controller.goBack();
      expect(controller.result!.chapters.single.verses.single.verse, 3);
      expect(controller.canGoBack, isFalse);
      expect(query.requests, hasLength(5));
    },
  );

  test(
    'oversized text and missing discovered books have explicit outcomes',
    () async {
      final _QueryRepository query = _QueryRepository();
      final GroupedReferenceLookup lookup = _lookup(query);
      await expectLater(
        lookup.lookup(
          TextReferenceRequest(
            translation: 'kjv',
            reference: List<String>.filled(513, 'é').join(),
          ),
        ),
        throwsA(isA<ReferenceLookupException>()),
      );
      await expectLater(
        lookup.lookup(
          StructuredReferenceRequest(
            translation: 'kjv',
            selections: <ReferenceSelection>[
              ReferenceSelection(book: 999999, chapter: 1, verses: <int>[1]),
            ],
          ),
        ),
        throwsA(isA<ReferenceLookupException>()),
      );
      expect(query.requests, isEmpty);
      expect(
        () => GroupedReferenceLookup(
          queryRepository: query,
          bibleRepository: _BooksRepository(),
          maxVersesPerRequest: 0,
        ),
        throwsArgumentError,
      );
    },
  );
}

GroupedReferenceLookup _lookup(
  _QueryRepository query, {
  String bookName = 'John',
}) => GroupedReferenceLookup(
  queryRepository: query,
  bibleRepository: _BooksRepository(bookName: bookName),
);

class _BooksRepository extends Fake implements BibleRepository {
  _BooksRepository({this.bookName = 'John'});
  final String bookName;

  @override
  Future<RepositoryResult<List<BibleBook>>> getBooks(
    String translation, {
    bool forceRefresh = false,
  }) async => RepositoryResult<List<BibleBook>>(
    data: <BibleBook>[
      BibleBook(number: 43, name: bookName, sha: 'discovered-book-sha'),
    ],
    freshness: CacheFreshness.fresh,
    checkedAt: DateTime.utc(2026, 10, 8),
  );
}

class _QueryRepository implements QueryRepository {
  _QueryRepository({this.bookName = 'John'});
  final String bookName;
  final List<String> requests = <String>[];
  Future<ReferenceResult> Function(String translation, String reference)?
  response;

  @override
  Future<ReferenceResult> query(
    String translation,
    String reference, {
    RequestCancellation? cancellation,
  }) async {
    requests.add(reference);
    return response == null
        ? fixture(translation, reference)
        : response!(translation, reference);
  }

  ReferenceResult fixture(String translation, String reference) {
    final JsonMap chapters = <String, Object?>{};
    for (final String part in reference.split(';')) {
      final RegExpMatch match = RegExp(
        r' (\d+):(\d+)(?:-(\d+))?$',
      ).firstMatch(part)!;
      final int chapter = int.parse(match.group(1)!);
      final int start = int.parse(match.group(2)!);
      final int end = int.parse(match.group(3) ?? match.group(2)!);
      final String key = '${translation}_43_$chapter';
      final JsonMap value =
          chapters.putIfAbsent(
                key,
                () => <String, Object?>{
                  'book_nr': 43,
                  'chapter': chapter,
                  'ref': <String>[],
                  'verses': <Object?>[],
                },
              )!
              as JsonMap;
      (value['ref']! as List<String>).add(part);
      for (int verse = start; verse <= end; verse += 1) {
        (value['verses']! as List<Object?>).add(<String, Object?>{
          'verse': verse,
          'name': '$bookName $chapter:$verse',
          'text': 'Verse $verse.',
        });
      }
    }
    return ReferenceResult.fromJson(
      chapters,
      translation: translation,
      reference: reference,
    );
  }
}
