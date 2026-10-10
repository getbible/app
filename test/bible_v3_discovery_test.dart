import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:getbible/core/errors.dart';
import 'package:getbible/data/api/api_configuration.dart';
import 'package:getbible/data/api/api_transport.dart';
import 'package:getbible/data/api/getbible_api_client.dart';
import 'package:getbible/data/database/local_database.dart';
import 'package:getbible/data/repositories/cached_bible_repository.dart';
import 'package:getbible/domain/models/bible.dart';
import 'package:getbible/domain/models/cache.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test(
    'intro-only large book discovers a navigation node without requesting chapter zero',
    () async {
      final String book = File(
        'test/fixtures/bible_v3/contract_intro_only_book.json',
      ).readAsStringSync();
      final List<Uri> requests = [];
      final client = MockClient((request) async {
        requests.add(request.url);
        return switch (request.url.path) {
          '/v3/fx/900000999/chapters.json' => http.Response('{}', 200),
          '/v3/fx/900000999.sha' => http.Response(_digest(book), 200),
          '/v3/fx/900000999.json' => http.Response(book, 200),
          _ => http.Response('Unavailable', 404),
        };
      });
      final db = await LocalDatabase.memory();
      addTearDown(db.close);
      final repository = CachedBibleRepository(
        db,
        GetBibleApiClient(client: client),
      );
      final index = await repository.getChapters('fx', 900000999);
      expect(index.data.single.chapter, 0);
      expect(index.data.single.isIntroduction, isTrue);
      final intro = await repository.getChapter('fx', 900000999, 0);
      expect(intro.data.verses, isEmpty);
      expect(
        intro.data.introduction.single.text,
        'Only an introduction, no Scripture coordinates.',
      );
      expect(
        requests.where((uri) => uri.path.contains('/900000999/0.')),
        isEmpty,
      );
      expect(requests.every((uri) => uri.path.startsWith('/v3/')), isTrue);
    },
  );
  test(
    'nested positive intro chapter uses its book content without a standalone file',
    () async {
      final translation =
          jsonDecode(
                File(
                  'test/fixtures/bible_v3/contract_rich_translation.json',
                ).readAsStringSync(),
              )
              as Map<String, dynamic>;
      final nested =
          (translation['books'] as List).single as Map<String, dynamic>;
      final String body = jsonEncode({
        ...nested,
        'translation': translation['translation'],
        'abbreviation': 'fx',
        'lang': 'fx',
        'language': 'Fixture language',
        'encoding': 'UTF-8',
        'direction': 'LTR',
      });
      final List<String> requests = [];
      final client = MockClient((request) async {
        requests.add(request.url.path);
        return switch (request.url.path) {
          '/v3/fx/900000123/chapters.json' => http.Response(
            jsonEncode({
              '3': {
                'chapter': 3,
                'name': 'Extended Book 3',
                'sha': List.filled(40, 'a').join(),
                'url': 'https://api.getbible.net/v3/fx/900000123/3.json',
              },
            }),
            200,
          ),
          '/v3/fx/900000123.sha' => http.Response(_digest(body), 200),
          '/v3/fx/900000123.json' => http.Response.bytes(
            utf8.encode(body),
            200,
          ),
          _ => http.Response('Missing', 404),
        };
      });
      final db = await LocalDatabase.memory();
      addTearDown(db.close);
      final repository = CachedBibleRepository(
        db,
        GetBibleApiClient(client: client),
      );
      final verifiedBook = await repository.getBookContent('fx', 900000123);
      expect(verifiedBook.data.chapters.length, 2);
      final chapters = await repository.getChapters('fx', 900000123);
      expect(chapters.data.map((chapter) => chapter.chapter), [0, 1, 3]);
      final intro = await repository.getChapter('fx', 900000123, 1);
      expect(intro.data.verses, isEmpty);
      expect(intro.data.titles.single.text, 'Book preface');
      expect(requests.where((path) => path.contains('/900000123/1.')), isEmpty);
    },
  );
  test(
    'no-store nested introduction remains selectable without persisting a source body',
    () async {
      final translation =
          jsonDecode(
                File(
                  'test/fixtures/bible_v3/contract_rich_translation.json',
                ).readAsStringSync(),
              )
              as Map<String, dynamic>;
      final nested =
          (translation['books'] as List).single as Map<String, dynamic>;
      final String body = jsonEncode({
        ...nested,
        'translation': translation['translation'],
        'abbreviation': 'fx',
        'lang': 'fx',
        'language': 'Fixture language',
        'encoding': 'UTF-8',
        'direction': 'LTR',
      });
      final List<String> requests = [];
      final client = MockClient((request) async {
        requests.add(request.url.path);
        return switch (request.url.path) {
          '/v3/fx/900000123/chapters.json' => http.Response(
            jsonEncode({
              '3': {
                'chapter': 3,
                'name': 'Extended Book 3',
                'sha': List.filled(40, 'a').join(),
                'url': 'https://api.getbible.net/v3/fx/900000123/3.json',
              },
            }),
            200,
          ),
          '/v3/fx/900000123.sha' => http.Response(
            _digest(body),
            200,
            headers: {'cache-control': 'no-store'},
          ),
          '/v3/fx/900000123.json' => http.Response.bytes(
            utf8.encode(body),
            200,
            headers: {'cache-control': 'no-store'},
          ),
          _ => http.Response('Missing', 404),
        };
      });
      final db = await LocalDatabase.memory();
      addTearDown(db.close);
      final repository = CachedBibleRepository(
        db,
        GetBibleApiClient(client: client),
      );
      final verifiedBook = await repository.getBookContent('fx', 900000123);
      expect(verifiedBook.data.chapters.length, 2);
      final chapters = await repository.getChapters('fx', 900000123);
      expect(chapters.data.map((chapter) => chapter.chapter), [0, 1, 3]);
      final intro = await repository.getChapter('fx', 900000123, 1);
      expect(intro.data.verses, isEmpty);
      expect(intro.data.titles.single.text, 'Book preface');
      expect(requests.where((path) => path.contains('/900000123/1.')), isEmpty);
      expect(
        await db.readCache(repository.cacheKey('chapters:fx:900000123')),
        isNull,
      );
      expect(
        await db.readCache(repository.cacheKey('book:fx:900000123')),
        isNull,
      );
    },
  );
  test(
    'a valid plain chapter index works when optional book metadata is unavailable',
    () async {
      int chapterRequests = 0;
      final client = MockClient((request) async {
        if (request.url.path.endsWith('/chapters.json')) {
          chapterRequests++;
          return http.Response(
            '{"1":{"chapter":1,"name":"Genesis 1","sha":"source"}}',
            200,
          );
        }
        return http.Response('No book snapshot', 404);
      });
      final db = await LocalDatabase.memory();
      addTearDown(db.close);
      final repository = CachedBibleRepository(
        db,
        GetBibleApiClient(client: client),
      );
      final chapters = await repository.getChapters('fx', 1);
      expect(chapters.data.single.chapter, 1);
      expect(chapterRequests, 1);
    },
  );
  for (final policy in ['no-cache', 'no-store', 'max-age=3600']) {
    test('$policy controls persistent index reuse', () async {
      int requests = 0;
      final client = MockClient((request) async {
        requests++;
        return http.Response(
          jsonEncode({
            'fx': {
              'translation': 'Fixture',
              'abbreviation': 'fx',
              'lang': 'en',
              'language': 'English',
              'direction': 'LTR',
              'sha': List.filled(40, 'a').join(),
            },
          }),
          200,
          headers: {'cache-control': policy},
        );
      });
      final db = await LocalDatabase.memory();
      addTearDown(db.close);
      final repository = CachedBibleRepository(
        db,
        GetBibleApiClient(client: client),
      );
      await repository.getTranslations();
      await repository.getTranslations();
      expect(requests, policy == 'max-age=3600' ? 1 : 2);
      final saved = await db.readCache(repository.cacheKey('translations'));
      if (policy == 'no-store') {
        expect(saved, isNull);
      } else {
        expect(saved, isNotNull);
      }
    });
  }
  test(
    'full enriched corpus worker preserves original bytes through cached activation',
    () async {
      final String body = File(
        'test/fixtures/bible_v3/rich_translation.json',
      ).readAsStringSync();
      final String sourceHash = _digest(body);
      int downloads = 0;
      final client = MockClient((request) async {
        if (request.url.path.endsWith('.sha')) {
          return http.Response(sourceHash, 200);
        }
        downloads++;
        return http.Response.bytes(utf8.encode(body), 200);
      });
      final db = await LocalDatabase.memory();
      addTearDown(db.close);
      final repository = CachedBibleRepository(
        db,
        GetBibleApiClient(client: client),
      );
      final translation = Translation(
        translation: 'Fixture Bible',
        abbreviation: 'fx',
        lang: 'fx',
        language: 'Fixture language',
        direction: 'LTR',
        sha: sourceHash,
      );
      final first = await repository.getWholeTranslation(translation);
      expect(first.data.toJson(), jsonDecode(body));
      expect((await db.readCache(repository.cacheKey('full:fx')))!.json, body);
      final reopened = await repository.getWholeTranslation(translation);
      expect(reopened.freshness, CacheFreshness.cachedVerified);
      expect(
        reopened.data.books.single.chapters.last.verses.first.text,
        '  A😀  supplied\tname\nremains.  ',
      );
      expect(downloads, 1);
    },
  );
  test(
    'a wrong-translation book cannot activate in the requested source cache',
    () async {
      final Map<String, dynamic> source =
          jsonDecode(
                File(
                  'test/fixtures/bible_v3/contract_intro_only_book.json',
                ).readAsStringSync(),
              )
              as Map<String, dynamic>;
      final String body = jsonEncode({...source, 'abbreviation': 'other'});
      final client = MockClient(
        (request) async => http.Response(
          request.url.path.endsWith('.sha') ? _digest(body) : body,
          200,
        ),
      );
      final db = await LocalDatabase.memory();
      addTearDown(db.close);
      final repository = CachedBibleRepository(
        db,
        GetBibleApiClient(client: client),
      );
      await expectLater(
        repository.getBookContent('fx', 900000999),
        throwsA(isA<ApiFormatException>()),
      );
      expect(
        await db.readCache(repository.cacheKey('book:fx:900000999')),
        isNull,
      );
    },
  );
  test(
    'domain-invalid snapshots cannot poison conditional HTTP revalidation',
    () async {
      final Map<String, dynamic> chapter =
          jsonDecode(
                File(
                  'test/fixtures/bible_v3/contract_plain_chapter.json',
                ).readAsStringSync(),
              )
              as Map<String, dynamic>;
      int requests = 0;
      final client = GetBibleApiClient(
        client: MockClient((request) async {
          expect(request.headers['if-none-match'], isNull);
          final value = requests++ == 0
              ? {
                  ...chapter,
                  'verses': [
                    {
                      'chapter': 1,
                      'verse': 1,
                      'text': 'Text',
                      'paragraph': 'invalid',
                    },
                  ],
                }
              : chapter;
          return http.Response(
            jsonEncode(value),
            200,
            headers: {'etag': '"snapshot"', 'cache-control': 'max-age=3600'},
          );
        }),
      );
      addTearDown(client.close);
      await expectLater(
        client.getChapter('plain', 1, 1),
        throwsA(isA<ApiFormatException>()),
      );
      expect(
        (await client.getChapter('plain', 1, 1)).verses.single.text,
        'First verse.',
      );
      expect(requests, 2);
    },
  );
  test(
    'configured Bible sources keep distinct persistent cache identities',
    () async {
      final db = await LocalDatabase.memory();
      addTearDown(db.close);
      final officialClient = GetBibleApiClient();
      addTearDown(officialClient.close);
      final mirrorClient = GetBibleApiClient(
        configuration: ApiConfiguration(
          endpoints: {
            ApiService.bible: ApiServiceEndpoint(
              baseUri: Uri.parse('https://mirror.example/v3/'),
              version: 'v3',
            ),
          },
        ),
      );
      addTearDown(mirrorClient.close);
      final official = CachedBibleRepository(db, officialClient);
      final mirror = CachedBibleRepository(db, mirrorClient);
      expect(official.cacheKey('chapter:fx:1:1'), 'bible:v3:s2:chapter:fx:1:1');
      expect(
        mirror.cacheKey('chapter:fx:1:1'),
        isNot(official.cacheKey('chapter:fx:1:1')),
      );
    },
  );
  test(
    'fresh 404 remains a typed HTTP failure when there is no saved index',
    () async {
      final db = await LocalDatabase.memory();
      addTearDown(db.close);
      final repository = CachedBibleRepository(
        db,
        GetBibleApiClient(
          transport: ApiTransport(
            client: MockClient((_) async => http.Response('Missing', 404)),
            retryPolicy: const ApiRetryPolicy(maxRetries: 0),
          ),
        ),
      );
      await expectLater(
        repository.getBooks('missing'),
        throwsA(
          isA<HttpStatusException>().having(
            (error) => error.statusCode,
            'status',
            404,
          ),
        ),
      );
    },
  );
  test(
    'book source change expires only matching chapter IDs and keeps their bytes',
    () async {
      final db = await LocalDatabase.memory();
      addTearDown(db.close);
      final client = MockClient(
        (_) async => http.Response(
          jsonEncode({
            '1': {'nr': 1, 'name': 'First', 'sha': 'new'},
            '10': {'nr': 10, 'name': 'Tenth', 'sha': 'same'},
          }),
          200,
        ),
      );
      final repository = CachedBibleRepository(
        db,
        GetBibleApiClient(client: client),
      );
      await db.writeCache(
        key: repository.cacheKey('books:fx'),
        kind: 'books',
        sha: '',
        payload: [
          {'nr': 1, 'name': 'First', 'sha': 'old'},
          {'nr': 10, 'name': 'Tenth', 'sha': 'same'},
        ],
        checkedAt: DateTime.utc(2026),
      );
      for (final book in [1, 10]) {
        await db.writeCache(
          key: repository.cacheKey('chapter:fx:$book:1'),
          kind: 'chapter',
          sha: 'saved',
          payload: {'text': 'saved $book'},
          checkedAt: DateTime.utc(2026),
        );
      }
      await repository.getBooks('fx', forceRefresh: true);
      final changed = await db.readCache(repository.cacheKey('chapter:fx:1:1'));
      expect(changed!.sha, isEmpty);
      expect(jsonDecode(changed.json), {'text': 'saved 1'});
      expect(
        (await db.readCache(repository.cacheKey('chapter:fx:10:1')))!.sha,
        'saved',
      );
    },
  );
}

String _digest(String body) => sha1.convert(utf8.encode(body)).toString();
