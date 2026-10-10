import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:getbible/data/api/api_configuration.dart';
import 'package:getbible/data/api/api_transport.dart';
import 'package:getbible/data/api/getbible_api_client.dart';
import 'package:getbible/data/database/local_database.dart';
import 'package:getbible/data/repositories/cached_bible_repository.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  for (final revalidated in [false, true]) {
    test(
      'clear prevents an in-flight ${revalidated ? '304' : '200'} from restoring HTTP cache',
      () async {
        final started = Completer<void>();
        final release = Completer<void>();
        var requests = 0;
        final transport = ApiTransport(
          client: MockClient((request) async {
            requests++;
            if (requests == (revalidated ? 2 : 1)) {
              started.complete();
              await release.future;
              if (revalidated) {
                expect(request.headers['if-none-match'], 'revision-one');
                return http.Response(
                  '',
                  304,
                  headers: {'cache-control': 'max-age=3600'},
                );
              }
            }
            return http.Response(
              '{"saved":true}',
              200,
              headers: {
                'cache-control': 'max-age=3600',
                'etag': 'revision-one',
              },
            );
          }),
        );
        addTearDown(transport.close);
        if (revalidated) {
          await transport.get(ApiService.dictionaries, 'fixture.json');
        }
        final pending = transport.get(
          ApiService.dictionaries,
          'fixture.json',
          forceRefresh: true,
        );
        await started.future;
        transport.clearCache();
        release.complete();
        expect((await pending).json['saved'], isTrue);
        final before = requests;
        await transport.get(ApiService.dictionaries, 'fixture.json');
        expect(
          requests,
          before + 1,
          reason: 'A later use must fetch a new copy.',
        );
        await transport.get(ApiService.dictionaries, 'fixture.json');
        expect(
          requests,
          before + 1,
          reason: 'The new post-clear copy can be cached.',
        );
      },
    );
  }

  for (final publicClear in [false, true]) {
    test(
      '${publicClear ? 'public' : 'Scripture'} clear prevents a pending chapter from restoring SQLite',
      () async {
        final body = File(
          'test/fixtures/bible_v3/contract_plain_chapter.json',
        ).readAsStringSync();
        final hash = sha1.convert(utf8.encode(body)).toString();
        final started = Completer<void>();
        final release = Completer<void>();
        var bodies = 0;
        final client = GetBibleApiClient(
          client: MockClient((request) async {
            if (request.url.path.endsWith('.sha')) {
              return http.Response(hash, 200);
            }
            bodies++;
            if (bodies == 1) {
              started.complete();
              await release.future;
            }
            return http.Response(body, 200);
          }),
        );
        final database = await LocalDatabase.memory();
        addTearDown(database.close);
        addTearDown(client.close);
        final repository = CachedBibleRepository(database, client);
        final pending = repository.getChapter('plain', 1, 1);
        await started.future;
        if (publicClear) {
          await repository.clearPublicCache();
        } else {
          await repository.clearScriptureCache();
        }
        release.complete();
        expect((await pending).data.verses.single.text, 'First verse.');
        final key = repository.cacheKey('chapter:plain:1:1');
        expect(await database.readCache(key), isNull);
        await repository.getChapter('plain', 1, 1);
        expect((await database.readCache(key))?.json, body);
      },
    );
  }
}
