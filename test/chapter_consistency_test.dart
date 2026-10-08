import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:getbible_live/data/api/getbible_api_client.dart';
import 'package:getbible_live/data/database/local_database.dart';
import 'package:getbible_live/data/repositories/cached_bible_repository.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('retries when a chapter hash rotates during download', () async {
    int shaRequest = 0;
    int chapterRequest = 0;
    final List<String> hashes = <String>[_sha('a'), _sha('b'), _sha('b')];
    final MockClient client = MockClient((http.Request request) async {
      if (request.url.path.endsWith('.sha')) {
        return http.Response(hashes[shaRequest++], 200);
      }
      chapterRequest++;
      return http.Response(
        jsonEncode(<String, Object?>{
          'translation': 'Test',
          'abbreviation': 'tst',
          'language': 'Test',
          'direction': 'LTR',
          'book_nr': 1,
          'book_name': 'Genesis',
          'chapter': 1,
          'name': 'Genesis 1',
          'verses': <Object?>[
            <String, Object?>{
              'chapter': 1,
              'verse': 1,
              'name': 'Genesis 1:1',
              'text': 'In the beginning.',
            },
          ],
        }),
        200,
      );
    });
    final LocalDatabase database = await LocalDatabase.memory();
    final CachedBibleRepository repository = CachedBibleRepository(
      database,
      GetBibleApiClient(client: client),
    );

    final result = await repository.getChapter('tst', 1, 1);

    expect(result.data.verses.single.text, 'In the beginning.');
    expect(chapterRequest, 2);
    expect(shaRequest, 3);
    final cached = await database.readCache('chapter:tst:1:1');
    expect(cached?.sha, _sha('b'));
    await database.close();
  });

  test('does not activate a chapter that keeps changing', () async {
    int shaRequest = 0;
    final MockClient client = MockClient((http.Request request) async {
      if (request.url.path.endsWith('.sha')) {
        final String value = _sha(String.fromCharCode(97 + shaRequest++));
        return http.Response(value, 200);
      }
      return http.Response(
        jsonEncode(<String, Object?>{
          'translation': 'Test',
          'abbreviation': 'tst',
          'language': 'Test',
          'direction': 'LTR',
          'book_nr': 1,
          'book_name': 'Genesis',
          'chapter': 1,
          'name': 'Genesis 1',
          'verses': <Object?>[
            <String, Object?>{
              'chapter': 1,
              'verse': 1,
              'name': 'Genesis 1:1',
              'text': 'Transient content.',
            },
          ],
        }),
        200,
      );
    });
    final LocalDatabase database = await LocalDatabase.memory();
    final CachedBibleRepository repository = CachedBibleRepository(
      database,
      GetBibleApiClient(client: client),
    );

    await expectLater(
      repository.getChapter('tst', 1, 1),
      throwsA(isA<Exception>()),
    );
    expect(await database.readCache('chapter:tst:1:1'), isNull);
    await database.close();
  });
}

String _sha(String character) => List<String>.filled(40, character).join();
