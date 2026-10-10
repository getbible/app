import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:getbible/application/offline_controller.dart';
import 'package:getbible/application/online_search_controller.dart';
import 'package:getbible/core/errors.dart';
import 'package:getbible/core/request_cancellation.dart';
import 'package:getbible/data/api/api_transport.dart';
import 'package:getbible/data/api/getbible_api_client.dart';
import 'package:getbible/data/database/local_database.dart';
import 'package:getbible/data/offline/bible_index_processor.dart';
import 'package:getbible/data/offline/bible_index_worker.dart';
import 'package:getbible/data/offline/bible_resource_installer.dart';
import 'package:getbible/data/repositories/cached_bible_repository.dart';
import 'package:getbible/data/repositories/installed_bible_repository.dart';
import 'package:getbible/data/repositories/installed_query_repository.dart';
import 'package:getbible/data/repositories/installed_search_repository.dart';
import 'package:getbible/domain/models/online_search.dart';
import 'package:getbible/domain/models/reference.dart';
import 'package:getbible/domain/models/search.dart';
import 'package:getbible/domain/models/service_envelopes.dart';
import 'package:getbible/domain/repositories/query_repository.dart';
import 'package:getbible/domain/repositories/search_repository.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _book = 900000123;
final _root = Uri.parse('https://api.getbible.net/v3');
String _fixture() =>
    File('test/fixtures/bible_v3/rich_translation.json').readAsStringSync();
String _sha(String raw) => sha1.convert(utf8.encode(raw)).toString();

void main() {
  test(
    'worker preserves all rich metadata and sparse introductions in bounded records',
    () async {
      final raw = _fixture();
      final source = jsonDecode(raw) as Map<String, Object?>;
      final batches = <Map<String, Object?>>[];
      await indexBibleInWorker(
        utf8.encode(raw),
        'fx',
        _sha(raw),
        (batch) async => batches.add(batch),
        RequestCancellation(),
      );
      final documents = <String, String>{
        for (final batch in batches)
          ...Map<String, String>.from(batch['documents'] as Map? ?? {}),
      };
      final chapter = jsonDecode(documents['chapter/$_book/3']!) as Map;
      final originalBooks = source['books']! as List;
      final originalChapters =
          (originalBooks.first as Map)['chapters']! as List;
      final original = originalChapters[1] as Map;
      for (final key in original.keys) {
        expect(chapter[key], original[key], reason: key.toString());
      }
      expect(
        (jsonDecode(documents['chapters/$_book']!) as List).map(
          (item) => (item as Map<String, Object?>)['chapter'],
        ),
        [0, 1, 3],
      );
      expect(
        (jsonDecode(documents['translation']!) as Map)['future_translation'],
        {'x': null},
      );
      expect(
        batches
            .where((batch) => batch['verses'] != null)
            .expand((batch) => batch['verses']! as List)
            .length,
        2,
      );
    },
  );

  test(
    'worker rejects exact-byte mismatch, duplicate books and invalid sparse verses',
    () async {
      final raw = _fixture();
      await expectLater(
        indexBibleInWorker(
          utf8.encode('$raw '),
          'fx',
          _sha(raw),
          (_) async {},
          RequestCancellation(),
        ),
        throwsFormatException,
      );
      final source = jsonDecode(raw) as Map<String, Object?>;
      final books = source['books']! as List;
      books.add(books.first);
      final duplicate = jsonEncode(source);
      expect(
        () => indexBibleSource(
          utf8.encode(duplicate),
          'fx',
          _sha(duplicate),
        ).toList(),
        throwsFormatException,
      );
    },
  );

  test(
    'worker cancellation terminates before the next acknowledged batch',
    () async {
      final token = RequestCancellation();
      int delivered = 0;
      final operation = indexBibleInWorker(
        utf8.encode(_fixture()),
        'fx',
        _sha(_fixture()),
        (_) async {
          delivered++;
          token.cancel();
        },
        token,
      );
      await expectLater(operation, throwsA(isA<RequestCancelledException>()));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(delivered, 1);
    },
  );

  test(
    'complete installation survives database restart and cache clear with zero HTTP',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'installed-bible-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/reader.sqlite');
      var db = await LocalDatabase.fromExecutor(NativeDatabase(file));
      var raw = _fixture();
      final paths = <String>[];
      bool online = true;
      bool rotate = false;
      int hashReads = 0;
      final transport = ApiTransport(
        client: MockClient((request) async {
          paths.add(request.url.path);
          if (!online) throw StateError('Offline must not issue HTTP.');
          if (request.url.path.endsWith('translations.json')) {
            final metadata = Map<String, dynamic>.from(jsonDecode(raw) as Map)
              ..remove('books');
            return http.Response(
              jsonEncode({
                'fx': {...metadata, 'sha': _sha(raw)},
              }),
              200,
            );
          }
          if (request.url.path.endsWith('fx.sha')) {
            hashReads++;
            return http.Response(
              rotate && hashReads.isEven ? '0' * 40 : _sha(raw),
              200,
            );
          }
          if (request.url.path.endsWith('fx.json')) {
            return http.Response(
              raw,
              200,
              headers: {'content-type': 'application/json; charset=utf-8'},
            );
          }
          return http.Response('missing', 404);
        }),
      );
      final installer = BibleResourceInstaller(transport);
      var store = SqlOfflineResourceStore(db);
      final manager = OfflineController(store: store, installers: [installer]);
      await manager.discover();
      expect(paths, ['/v3/translations.json']);
      await manager.install(manager.catalog.single);
      expect(manager.error, isNull);
      expect(paths.where((path) => path.endsWith('.json')).toList(), [
        '/v3/translations.json',
        '/v3/fx.json',
      ]);
      final firstGeneration = (await store.listInstalled()).single.generation;
      // A source rotation during an explicit update cannot replace the readable copy.
      rotate = true;
      hashReads = 0;
      await manager.install(manager.catalog.single);
      expect(manager.error, contains('changed during installation'));
      expect((await store.listInstalled()).single.generation, firstGeneration);
      // A subsequent update can use an old discovery descriptor, after verifying
      // the current bulk revision and recording its current SHA.
      rotate = false;
      raw = raw.replaceFirst('Another verse.', 'Another updated verse.');
      await manager.install(manager.catalog.single);
      expect(manager.error, isNull);
      expect((await store.listInstalled()).single.resource.revision, _sha(raw));
      manager.dispose();
      await db.close();
      online = false;
      paths.clear();
      db = await LocalDatabase.fromExecutor(NativeDatabase(file));
      addTearDown(db.close);
      store = SqlOfflineResourceStore(db);
      final installed = InstalledBibleRepository(store, sourceUri: _root);
      final reader = CachedBibleRepository(
        db,
        GetBibleApiClient(transport: transport),
        installed: installed,
      );
      expect((await reader.getTranslations()).data.single.abbreviation, 'fx');
      expect((await reader.getBooks('fx')).data.single.number, _book);
      expect(
        (await reader.getChapters(
          'fx',
          _book,
        )).data.map((item) => item.chapter),
        [0, 1, 3],
      );
      final chapter = (await reader.getChapter('fx', _book, 3)).data;
      expect(
        (chapter.verses.first.tokens.first.lemma!
            as Map<String, Object?>)['strong'],
        ['G1', 'G2'],
      );
      expect(chapter.editorial!.entries.length, 3);
      expect(
        (await reader.getChapter('fx', _book, 0)).data.isIntroduction,
        isTrue,
      );
      await reader.clearScriptureCache();
      expect(
        (await reader.getChapter('fx', _book, 3)).data.verses.last.text,
        'Another updated verse.',
      );
      final query = InstalledQueryRepository(
        installed: installed,
        online: _NeverQuery(),
      );
      final result = await query.query('fx', 'Extended Book3:7,9');
      expect(result.verseCount, 2);
      expect(
        result.chapters.single.verses.first.toJson(),
        chapter.verses.first.toJson(),
      );
      await expectLater(
        query.query('fx', 'Extended Book 3:7-9'),
        throwsA(isA<ReferenceLookupException>()),
      );
      await expectLater(
        query.query('fx', 'Extended Book 3:999999999999'),
        throwsA(isA<ReferenceLookupException>()),
      );
      await expectLater(
        query.query('fx', 'Extended Book 1'),
        throwsA(isA<ReferenceLookupException>()),
      );
      await expectLater(
        query.query('fx', 'John 3:16'),
        throwsA(isA<ReferenceLookupException>()),
      );
      final search = InstalledSearchRepository(
        installed: installed,
        query: query,
      );
      final page = await search.search(_request('supplied name'));
      expect(page.total, 1);
      expect(page.hits.single.verse.tokens, isNotEmpty);
      final ref = await search.search(_request('Extended Book 3:7,9'));
      expect(ref.kind, SearchResultKind.reference);
      expect(ref.hits.length, 2);
      expect(
        (await search.search(_request('another'))).hits.single.verse.verse,
        9,
      );
      expect(
        (await search.search(_request('NAME', caseSensitive: true))).total,
        0,
      );
      expect(
        (await search.search(_request('name', exclusions: ['supplied']))).total,
        0,
      );
      expect(
        (await search.search(
          _request('supplied name', words: SearchWordMode.phrase),
        )).total,
        1,
      );
      expect(
        (await search.search(
          _request('supplied missing', words: SearchWordMode.any),
        )).total,
        1,
      );
      final anyCriteria = OnlineSearchCriteria(
        diacritics: SearchDiacritics.exact,
        words: SearchWordMode.any,
      );
      final firstPage = await search.search(
        OnlineSearchRequest(
          translation: 'fx',
          text: 'name updated',
          criteria: anyCriteria,
          limit: 1,
        ),
      );
      expect(firstPage.total, 2);
      expect(firstPage.hasMore, isTrue);
      final secondPage = await search.search(
        OnlineSearchRequest(
          translation: 'fx',
          text: 'name updated',
          criteria: anyCriteria,
          limit: 1,
          offset: firstPage.nextOffset,
        ),
      );
      expect(secondPage.hits.single.verse.verse, 9);
      expect(secondPage.hasMore, isFalse);
      for (final unsupported in [
        OnlineSearchCriteria(),
        OnlineSearchCriteria(
          diacritics: SearchDiacritics.exact,
          sort: SearchSort.relevance,
        ),
        OnlineSearchCriteria(diacritics: SearchDiacritics.exact, proximity: 2),
        OnlineSearchCriteria(
          diacritics: SearchDiacritics.exact,
          scope: OnlineSearchScope.deuterocanon,
        ),
        OnlineSearchCriteria(
          diacritics: SearchDiacritics.exact,
          exclusions: ['two words'],
        ),
      ]) {
        await expectLater(
          search.search(
            OnlineSearchRequest(
              translation: 'fx',
              text: 'name',
              criteria: unsupported,
            ),
          ),
          throwsFormatException,
        );
      }
      expect(paths, isEmpty);
      transport.close();
    },
  );

  test(
    'unsupported offline filters are errors; online remains the controller default',
    () async {
      final db = await LocalDatabase.memory();
      addTearDown(db.close);
      final installed = InstalledBibleRepository(
        SqlOfflineResourceStore(db),
        sourceUri: _root,
      );
      final query = InstalledQueryRepository(
        installed: installed,
        online: _NeverQuery(),
      );
      final search = InstalledSearchRepository(
        installed: installed,
        query: query,
      );
      await expectLater(search.search(_request('word')), throwsFormatException);
      final api = _RecordingSearch();
      final local = _RecordingSearch();
      final controller = OnlineSearchController(
        repository: api,
        installedRepository: local,
      );
      addTearDown(controller.dispose);
      await controller.search('fx', 'faith');
      expect(api.calls, 1);
      expect(local.calls, 0);
      await controller.search(
        'fx',
        'faith',
        mode: SearchExecutionMode.installed,
      );
      expect(api.calls, 1);
      expect(local.calls, 1);
    },
  );
}

OnlineSearchRequest _request(
  String text, {
  bool caseSensitive = false,
  List<String> exclusions = const [],
  SearchWordMode words = SearchWordMode.all,
}) => OnlineSearchRequest(
  translation: 'fx',
  text: text,
  criteria: OnlineSearchCriteria(
    diacritics: SearchDiacritics.exact,
    caseSensitive: caseSensitive,
    exclusions: exclusions,
    words: words,
  ),
);

class _NeverQuery implements QueryRepository {
  @override
  Future<ReferenceResult> query(
    String translation,
    String reference, {
    RequestCancellation? cancellation,
  }) => throw StateError('Unexpected online query.');
}

class _RecordingSearch implements SearchRepository {
  int calls = 0;
  @override
  Future<OnlineSearchPage> search(
    OnlineSearchRequest request, {
    RequestCancellation? cancellation,
  }) async {
    calls++;
    return const OnlineSearchPage(
      kind: SearchResultKind.search,
      hits: [],
      total: 0,
      returned: 0,
      engineVersion: 1,
      offset: 0,
      hasMore: false,
      sourceSha: null,
    );
  }
}
