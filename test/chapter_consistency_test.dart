import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:getbible/core/errors.dart';
import 'package:getbible/data/api/api_transport.dart';
import 'package:getbible/data/api/getbible_api_client.dart';
import 'package:getbible/data/database/local_database.dart';
import 'package:getbible/data/repositories/cached_bible_repository.dart';
import 'package:getbible/domain/models/cache.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test(
    'retries source rotation then activates only matching exact JSON bytes',
    () async {
      final String original = _chapter('Original.');
      final String replacement = _chapter('Replacement.');
      int shaRequests = 0, chapterRequests = 0;
      final hashes = [
        _digest(original),
        _digest(replacement),
        _digest(replacement),
      ];
      final MockClient client = MockClient((request) async {
        expect(request.url.path, startsWith('/v3/'));
        if (request.url.path.endsWith('.sha')) {
          return http.Response(hashes[shaRequests++], 200);
        }
        return http.Response(
          chapterRequests++ == 0 ? original : replacement,
          200,
        );
      });
      final db = await LocalDatabase.memory();
      addTearDown(db.close);
      final repository = CachedBibleRepository(
        db,
        GetBibleApiClient(client: client),
      );
      final result = await repository.getChapter('tst', 1, 1);
      expect(result.data.verses.single.text, 'Replacement.');
      expect(chapterRequests, 2);
      expect(shaRequests, 3);
      final saved = await db.readCache(repository.cacheKey('chapter:tst:1:1'));
      expect(saved!.json, replacement);
      expect(saved.sha, _digest(replacement));
    },
  );

  test(
    'stable source hash with wrong bytes never activates a chapter',
    () async {
      final body = _chapter('Wrong bytes.');
      final client = MockClient(
        (request) async => http.Response(
          request.url.path.endsWith('.sha')
              ? _digest(_chapter('Correct bytes.'))
              : body,
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
        repository.getChapter('tst', 1, 1),
        throwsA(isA<ApiFormatException>()),
      );
      expect(
        await db.readCache(repository.cacheKey('chapter:tst:1:1')),
        isNull,
      );
    },
  );

  for (final failure in ['malformed', 'rotation', 'digest']) {
    test(
      '$failure replacement retains readable last-known-good content',
      () async {
        final String saved = _chapter('Last known good.');
        final String next = _chapter('New content.');
        int requestNumber = 0;
        final client = MockClient((request) async {
          if (request.url.path.endsWith('.sha')) {
            return http.Response(
              failure == 'rotation'
                  ? _digest('$next${requestNumber++}')
                  : _digest(next),
              200,
            );
          }
          return http.Response(
            failure == 'malformed'
                ? '{'
                : failure == 'digest'
                ? '$next '
                : next,
            200,
          );
        });
        final db = await LocalDatabase.memory();
        addTearDown(db.close);
        final repository = CachedBibleRepository(
          db,
          GetBibleApiClient(client: client),
        );
        await db.writeCache(
          key: repository.cacheKey('chapter:tst:1:1'),
          kind: 'chapter',
          sha: _digest(saved),
          payload: jsonDecode(saved) as Object,
          rawJson: saved,
          checkedAt: DateTime.utc(2026),
        );
        final result = await repository.getChapter('tst', 1, 1);
        expect(result.data.verses.single.text, 'Last known good.');
        expect(result.freshness, CacheFreshness.cachedUnverified);
        expect(
          (await db.readCache(repository.cacheKey('chapter:tst:1:1')))!.json,
          saved,
        );
      },
    );
  }

  test(
    'legacy v2 chapter remains explicitly legacy and never hash verified',
    () async {
      final body = _chapter('Legacy Scripture.');
      final db = await LocalDatabase.memory();
      addTearDown(db.close);
      await db.writeCache(
        key: ScriptureCacheIdentity.legacy.key('chapter:tst:1:1'),
        kind: 'chapter',
        sha: _digest(body),
        payload: jsonDecode(body) as Object,
        checkedAt: DateTime.utc(2026),
      );
      final client = MockClient(
        (_) async => throw http.ClientException('offline'),
      );
      final result = await CachedBibleRepository(
        db,
        GetBibleApiClient(
          transport: ApiTransport(
            client: client,
            retryPolicy: const ApiRetryPolicy(maxRetries: 0),
          ),
        ),
      ).getChapter('tst', 1, 1);
      expect(result.isLegacy, isTrue);
      expect(result.sourceApiVersion, 'v2');
      expect(result.isVerified, isFalse);
      expect(result.data.verses.single.text, 'Legacy Scripture.');
    },
  );

  test(
    'storage write failure returns fresh Scripture while preserving the saved value',
    () async {
      final old = _chapter('Last saved.');
      final fresh = _chapter('Validated fresh.');
      final executor = NativeDatabase.memory();
      final db = await LocalDatabase.fromExecutor(executor);
      addTearDown(db.close);
      final client = MockClient(
        (request) async => http.Response(
          request.url.path.endsWith('.sha') ? _digest(fresh) : fresh,
          200,
        ),
      );
      final repository = CachedBibleRepository(
        db,
        GetBibleApiClient(client: client),
      );
      await db.writeCache(
        key: repository.cacheKey('chapter:tst:1:1'),
        kind: 'chapter',
        sha: _digest(old),
        payload: jsonDecode(old) as Object,
        rawJson: old,
        checkedAt: DateTime.utc(2026),
      );
      await executor.runCustom(
        "CREATE TRIGGER cache_quota BEFORE INSERT ON cache_entries BEGIN SELECT RAISE(FAIL, 'quota'); END",
      );
      final result = await repository.getChapter('tst', 1, 1);
      expect(result.data.verses.single.text, 'Validated fresh.');
      expect(result.freshness, CacheFreshness.fresh);
      expect(
        (await db.readCache(repository.cacheKey('chapter:tst:1:1')))!.json,
        old,
      );
    },
  );

  test(
    'no-store fresh chapter returns without replacing saved offline value',
    () async {
      final saved = _chapter('Saved offline.');
      final body = _chapter('No store.');
      final client = MockClient(
        (request) async => http.Response(
          request.url.path.endsWith('.sha') ? _digest(body) : body,
          200,
          headers: {'cache-control': 'no-store'},
        ),
      );
      final db = await LocalDatabase.memory();
      addTearDown(db.close);
      final repository = CachedBibleRepository(
        db,
        GetBibleApiClient(client: client),
      );
      await db.writeCache(
        key: repository.cacheKey('chapter:tst:1:1'),
        kind: 'chapter',
        sha: _digest(saved),
        payload: jsonDecode(saved) as Object,
        rawJson: saved,
        checkedAt: DateTime.utc(2026),
      );
      final result = await repository.getChapter('tst', 1, 1);
      expect(result.data.verses.single.text, 'No store.');
      expect(
        (await db.readCache(repository.cacheKey('chapter:tst:1:1')))!.json,
        saved,
      );
    },
  );
}

String _digest(String body) => sha1.convert(utf8.encode(body)).toString();
String _chapter(String text) => jsonEncode(<String, Object?>{
  'translation': 'Test',
  'abbreviation': 'tst',
  'language': 'English',
  'direction': 'LTR',
  'book_nr': 1,
  'book_name': 'Genesis',
  'chapter': 1,
  'name': 'Genesis 1',
  'verses': [
    {'chapter': 1, 'verse': 1, 'name': 'Genesis 1:1', 'text': text},
  ],
});
