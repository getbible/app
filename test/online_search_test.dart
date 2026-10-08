import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:getbible_live/application/online_search_controller.dart';
import 'package:getbible_live/core/errors.dart';
import 'package:getbible_live/core/json.dart';
import 'package:getbible_live/core/request_cancellation.dart';
import 'package:getbible_live/data/api/api_transport.dart';
import 'package:getbible_live/data/repositories/api_search_repository.dart';
import 'package:getbible_live/domain/models/bible.dart';
import 'package:getbible_live/domain/models/online_search.dart';
import 'package:getbible_live/domain/models/search.dart';
import 'package:getbible_live/domain/models/service_envelopes.dart';
import 'package:getbible_live/domain/repositories/search_repository.dart';
import 'package:getbible_live/services/search_match_emphasis.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test(
    'GET encodes exact selected text, all filters, false and zero without corpus requests',
    () async {
      final List<Uri> requests = <Uri>[];
      final ApiTransport transport = ApiTransport(
        client: MockClient((http.Request request) async {
          requests.add(request.url);
          return http.Response(jsonEncode(_fixture('search')), 200);
        }),
      );
      addTearDown(transport.close);
      final OnlineSearchPage page = await ApiSearchRepository(transport).search(
        OnlineSearchRequest(
          translation: 'tst',
          text: '  faith & hope / שלום  ',
          limit: 2,
          criteria: OnlineSearchCriteria(
            match: SearchMatchMode.partial,
            scope: OnlineSearchScope.deuterocanon,
            books: <int>[1, 1000000042],
            exclusions: <String>['darkness', 'night & day'],
            proximity: 0,
            sort: SearchSort.relevance,
            diacritics: SearchDiacritics.exact,
          ),
        ),
      );
      expect(requests.single.host, 'search.getbible.net');
      expect(requests.single.path, '/v3/tst');
      final Map<String, List<String>> parameters =
          requests.single.queryParametersAll;
      expect(parameters['q'], <String>['  faith & hope / שלום  ']);
      expect(parameters['book'], <String>['1', '1000000042']);
      expect(parameters['exclude'], <String>['darkness', 'night & day']);
      expect(parameters['case_sensitive'], <String>['false']);
      expect(parameters['proximity'], <String>['0']);
      expect(parameters['match'], <String>['substring']);
      expect(parameters['scope'], <String>['deuterocanon']);
      expect(parameters['diacritics'], <String>['exact']);
      expect(parameters['sort'], <String>['relevance']);
      expect(parameters.containsKey('locale'), false);
      expect(page.hits.map((OnlineSearchHit hit) => hit.book), <int>[2, 1]);
      expect(page.hits.first.verse.verse, 8);
      expect(page.hits.last.verse.text, 'First  \nverse.');
    },
  );

  test(
    'rich verse and compact direction remain available to result opening',
    () async {
      final JsonMap fixture = requireJsonMap(
        jsonDecode(
          File('test/fixtures/search_v3_rich.json').readAsStringSync(),
        ),
        'rich search',
      );
      final JsonMap chapter = requireJsonMap(
        requireJsonMap(fixture['results'], 'results')['tst_1_1'],
        'chapter',
      );
      final JsonMap verse = requireJsonMap(
        requireJsonList(chapter['verses'], 'verses').single,
        'verse',
      );
      final ApiTransport transport = ApiTransport(
        client: MockClient(
          (_) async => http.Response(jsonEncode(fixture), 200),
        ),
      );
      addTearDown(transport.close);
      final OnlineSearchPage page = await ApiSearchRepository(
        transport,
      ).search(_request());
      expect(page.hits.last.direction, 'RTL');
      expect(
        requireJsonMap(
          page.hits.last.verse.tokens.single.lemma,
          'lemma',
        )['strong'],
        <String>['G3056'],
      );
      expect(page.hits.last.verse.toJson()['tokens'], verse['tokens']);
    },
  );

  test(
    'reference results ignore full-text pagination and restrictions locally',
    () async {
      final Map<String, Object?> fixture = _fixture('search_reference');
      final Map<String, dynamic> query =
          fixture['query'] as Map<String, dynamic>;
      final Map<String, dynamic> chapter =
          (fixture['results'] as Map)['tst_1_1'] as Map<String, dynamic>;
      query['total'] = 120;
      query['returned'] = 120;
      chapter['verses'] = List<Object?>.generate(
        120,
        (int index) => <String, Object?>{
          'verse': index + 1,
          'name': 'Fixture 1:${index + 1}',
          'text': 'Verse ${index + 1}',
        },
      );
      fixture['matches'] = List<Object?>.generate(
        120,
        (int index) => <String, Object?>{
          'reference': 'Fixture 1:${index + 1}',
          'book_nr': 1,
          'chapter': 1,
          'verse': index + 1,
        },
      );
      final ApiTransport transport = ApiTransport(
        client: MockClient(
          (_) async => http.Response(jsonEncode(fixture), 200),
        ),
      );
      addTearDown(transport.close);
      final OnlineSearchPage page = await ApiSearchRepository(transport).search(
        OnlineSearchRequest(
          translation: 'tst',
          text: 'Fixture 1',
          limit: 1,
          offset: 900,
          criteria: OnlineSearchCriteria(
            scope: OnlineSearchScope.newTestament,
            books: <int>[43],
          ),
        ),
      );
      expect(page.kind, SearchResultKind.reference);
      expect(page.hits, hasLength(120));
      expect(page.hasMore, false);
      expect(page.offset, 0);
      expect(page.hits.first.score, isNull);
    },
  );

  test('malformed cache body is evicted for a corrected retry', () async {
    int count = 0;
    final ApiTransport transport = ApiTransport(
      client: MockClient((_) async {
        count += 1;
        return http.Response(
          jsonEncode(
            count == 1 ? <String, Object?>{'query': false} : _fixture('search'),
          ),
          200,
          headers: <String, String>{'cache-control': 'max-age=600'},
        );
      }),
    );
    addTearDown(transport.close);
    final ApiSearchRepository repository = ApiSearchRepository(transport);
    await expectLater(
      repository.search(_request()),
      throwsA(isA<ApiFormatException>()),
    );
    expect((await repository.search(_request())).returned, 2);
    expect(count, 2);
  });

  test(
    'compact metadata can omit pagination and selected direction supplies fallback',
    () async {
      final ApiTransport transport = ApiTransport(
        client: MockClient(
          (_) async =>
              http.Response(jsonEncode(_fixture('search_compact')), 200),
        ),
      );
      addTearDown(transport.close);
      final OnlineSearchPage page = await ApiSearchRepository(transport).search(
        OnlineSearchRequest(
          translation: 'tst',
          text: 'fixture',
          criteria: OnlineSearchCriteria(),
          direction: 'RTL',
        ),
      );
      expect(page.hasMore, false);
      expect(page.hits.single.direction, 'RTL');
      expect(page.hits.single.book, 101);
    },
  );

  test(
    'API paging uses actual returned count and deduplicates without reordering relevance',
    () async {
      final _Repository repository = _Repository(<Future<OnlineSearchPage>>[
        Future<OnlineSearchPage>.value(
          _page(<int>[8, 1], total: 4, hasMore: true),
        ),
        Future<OnlineSearchPage>.value(_page(<int>[1, 9], total: 4, offset: 2)),
      ]);
      final OnlineSearchController controller = OnlineSearchController(
        repository: repository,
      );
      addTearDown(controller.dispose);
      await controller.search('tst', 'faith', pageSize: 25);
      expect(controller.nextOffset, 2);
      expect(controller.canLoadMore, true);
      await controller.loadMore();
      expect(
        repository.requests.map(
          (OnlineSearchRequest request) => request.offset,
        ),
        <int>[0, 2],
      );
      expect(
        controller.results.map((OnlineSearchHit hit) => hit.verse.verse),
        <int>[8, 1, 9],
      );
      expect(controller.total, 4);
      expect(controller.canLoadMore, false);
    },
  );

  for (final bool engineChange in <bool>[false, true]) {
    test(
      '${engineChange ? 'engine' : 'source'} revision cannot mix into existing results; restart is explicit',
      () async {
        final _Repository repository = _Repository(<Future<OnlineSearchPage>>[
          Future<OnlineSearchPage>.value(
            _page(<int>[1], total: 2, hasMore: true),
          ),
          Future<OnlineSearchPage>.value(
            _page(
              <int>[2],
              total: 2,
              offset: 1,
              sha: engineChange ? 'first' : 'second',
              engine: engineChange ? 6 : 5,
            ),
          ),
          Future<OnlineSearchPage>.value(
            _page(<int>[3], total: 1, sha: 'second', engine: 6),
          ),
        ]);
        final OnlineSearchController controller = OnlineSearchController(
          repository: repository,
        );
        addTearDown(controller.dispose);
        await controller.search('tst', 'faith');
        await controller.loadMore();
        expect(controller.error, isA<SearchRevisionChangedException>());
        expect(controller.results.single.verse.verse, 1);
        expect(controller.canLoadMore, false);
        await controller.retry();
        expect(repository.requests.last.offset, 0);
        expect(controller.results.single.verse.verse, 3);
      },
    );
  }

  test(
    'repeated inputs and translation changes invalidate late responses',
    () async {
      final Completer<OnlineSearchPage> stale = Completer<OnlineSearchPage>();
      final _Repository repository = _Repository(<Future<OnlineSearchPage>>[
        stale.future,
        Future<OnlineSearchPage>.value(_page(<int>[2], total: 1)),
      ]);
      final OnlineSearchController controller = OnlineSearchController(
        repository: repository,
      );
      addTearDown(controller.dispose);
      final Future<void> earlier = controller.search('tst', 'faith');
      await controller.search('tst', 'faith');
      expect(repository.tokens.first!.isCancelled, true);
      stale.complete(_page(<int>[1], total: 1));
      await earlier;
      expect(controller.results.single.verse.verse, 2);
      controller.clear();
      expect(controller.results, isEmpty);
    },
  );

  test('closing cancels a pending page and its result cannot append', () async {
    final Completer<OnlineSearchPage> stale = Completer<OnlineSearchPage>();
    final _Repository repository = _Repository(<Future<OnlineSearchPage>>[
      Future<OnlineSearchPage>.value(_page(<int>[1], total: 2, hasMore: true)),
      stale.future,
    ]);
    final OnlineSearchController controller = OnlineSearchController(
      repository: repository,
    );
    addTearDown(controller.dispose);
    await controller.search('tst', 'faith');
    final Future<void> more = controller.loadMore();
    controller.cancel();
    stale.complete(_page(<int>[2], total: 2, offset: 1));
    await more;
    expect(controller.results.single.verse.verse, 1);
    expect(controller.isLoadingMore, false);
  });

  test(
    'empty success, rate-limit Retry-After and retry maintain explicit states',
    () async {
      DateTime now = DateTime.utc(2026);
      final _Repository repository = _Repository(<Future<OnlineSearchPage>>[
        Future<OnlineSearchPage>.error(
          RateLimitException(
            Uri.parse('https://search.getbible.net/v3/tst'),
            retryAfter: const Duration(seconds: 30),
          ),
        ),
        Future<OnlineSearchPage>.value(_page(<int>[], total: 0)),
      ]);
      final OnlineSearchController controller = OnlineSearchController(
        repository: repository,
        now: () => now,
      );
      addTearDown(controller.dispose);
      await controller.search('tst', 'faith');
      expect(controller.error, isA<RateLimitException>());
      expect(controller.canRetry, false);
      await controller.retry();
      expect(repository.requests, hasLength(1));
      now = now.add(const Duration(seconds: 30));
      await controller.retry();
      expect(controller.kind, SearchResultKind.search);
      expect(controller.total, 0);
      expect(controller.error, isNull);
      expect(controller.canLoadMore, false);
    },
  );

  test(
    'pagination never exceeds the 10000 offset ceiling and retains the true total',
    () async {
      final _CountingRepository repository = _CountingRepository();
      final OnlineSearchController controller = OnlineSearchController(
        repository: repository,
      );
      addTearDown(controller.dispose);
      await controller.search('tst', 'faith', pageSize: 100);
      while (controller.canLoadMore) {
        await controller.loadMore();
      }
      expect(repository.lastOffset, 10000);
      expect(controller.offsetLimitReached, true);
      expect(controller.total, 20000);
      expect(controller.results, hasLength(10100));
      await controller.loadMore();
      expect(repository.calls, 101);
    },
  );

  test(
    'Retry-After service pause survives repeated submission, changed filters, clear and close',
    () async {
      DateTime now = DateTime.utc(2026);
      final _Repository repository = _Repository(<Future<OnlineSearchPage>>[
        Future<OnlineSearchPage>.error(
          RateLimitException(
            Uri.parse('https://search.getbible.net/v3/tst'),
            retryAfter: const Duration(seconds: 30),
          ),
        ),
        Future<OnlineSearchPage>.value(_page(<int>[70], total: 1)),
      ]);
      final OnlineSearchController controller = OnlineSearchController(
        repository: repository,
        now: () => now,
      );
      addTearDown(controller.dispose);
      await controller.search('tst', 'faith');
      await controller.search('tst', 'faith');
      expect(repository.requests, hasLength(1));
      expect(controller.error, isA<RateLimitException>());
      expect(controller.canRetry, false);
      controller.clear();
      await controller.search(
        'tst',
        'narrower faith',
        criteria: OnlineSearchCriteria(books: <int>[1]),
      );
      controller.cancel();
      await controller.search('another', 'hope');
      expect(repository.requests, hasLength(1));
      expect(
        controller.retryAt,
        DateTime.utc(2026).add(const Duration(seconds: 30)),
      );
      expect(controller.request!.text, 'hope');
      now = now.add(const Duration(seconds: 30));
      await controller.retry();
      expect(repository.requests, hasLength(2));
      expect(repository.requests.last.translation, 'another');
      expect(repository.requests.last.text, 'hope');
      expect(controller.results.single.verse.verse, 70);
      expect(controller.error, isNull);
      expect(controller.retryAt, isNull);
    },
  );

  test(
    'silent lifecycle cancellation clears pending state without notifying application listeners',
    () async {
      final Completer<OnlineSearchPage> pending = Completer<OnlineSearchPage>();
      final _Repository repository = _Repository(<Future<OnlineSearchPage>>[
        pending.future,
      ]);
      final OnlineSearchController controller = OnlineSearchController(
        repository: repository,
      );
      addTearDown(controller.dispose);
      int notifications = 0;
      controller.addListener(() => notifications += 1);
      final Future<void> searching = controller.search('tst', 'faith');
      expect(notifications, greaterThan(0));
      final int before = notifications;
      controller.cancel(notify: false);
      expect(repository.tokens.single!.isCancelled, true);
      expect(controller.isLoading, false);
      expect(notifications, before);
      controller.clear(notify: false);
      expect(controller.request, isNull);
      expect(notifications, before);
      controller.cancel();
      controller.clear();
      expect(notifications, before + 2);
      pending.complete(_page(<int>[1], total: 1));
      await searching;
      expect(controller.results, isEmpty);
      expect(notifications, before + 2);
    },
  );

  test('bounds apply before HTTP and advanced inputs are immutable', () {
    final List<int> books = <int>[1];
    final OnlineSearchCriteria criteria = OnlineSearchCriteria(books: books);
    books.add(2);
    expect(criteria.books, <int>[1]);
    expect(() => criteria.books.add(3), throwsUnsupportedError);
    expect(
      () => OnlineSearchCriteria(proximity: 0, words: SearchWordMode.phrase),
      throwsFormatException,
    );
    expect(
      () => OnlineSearchCriteria(exclusions: List<String>.filled(33, 'term')),
      throwsFormatException,
    );
    expect(
      () => OnlineSearchCriteria(books: List<int>.filled(84, 1)),
      throwsFormatException,
    );
    expect(
      () => OnlineSearchRequest(
        translation: 'tst',
        text: '😀' * 501,
        criteria: criteria,
      ),
      throwsFormatException,
    );
    expect(() => _request().atOffset(10001), throwsFormatException);
    expect(
      () => OnlineSearchRequest(
        translation: '../tst',
        text: 'faith',
        criteria: criteria,
      ),
      throwsFormatException,
    );
    expect(
      OnlineSearchCriteria.fromOptions(
        const SearchOptions(
          match: SearchMatchMode.partial,
          scope: SearchScope.book(101),
        ),
      ).books,
      <int>[101],
    );
  });

  test(
    'emphasis preserves original Unicode text and never treats matches as offsets',
    () {
      const Verse verse = Verse(
        chapter: 1,
        verse: 1,
        name: '',
        text: '😀 Faith e\u0301 שלום 神爱世人',
      );
      final emphasis = searchMatchEmphasis(verse, <String>[
        'faith',
        'שלום',
        '爱世',
        'é',
        'not present',
      ]);
      expect(emphasis.map((item) => item.quote), <String>[
        'Faith',
        'שלום',
        '爱世',
      ]);
      for (final item in emphasis) {
        expect(
          verse.text.substring(item.range.start, item.range.end),
          item.quote,
        );
      }
      expect(emphasis.first.range.start, 3);
      expect(verse.text, '😀 Faith e\u0301 שלום 神爱世人');
    },
  );

  test(
    'temporary exact-word emphasis respects case and combining boundaries',
    () {
      const Verse verse = Verse(
        chapter: 1,
        verse: 1,
        name: '',
        text: 'Faith faithful faith e\u0301',
      );
      final exact = searchMatchEmphasis(verse, <String>[
        'faith',
        'e',
      ], match: SearchMatchMode.exact);
      expect(exact.map((item) => item.quote), <String>['Faith', 'faith']);
      final sensitive = searchMatchEmphasis(
        verse,
        <String>['faith'],
        match: SearchMatchMode.exact,
        caseSensitive: true,
      );
      expect(sensitive.map((item) => item.quote), <String>['faith']);
      final partial = searchMatchEmphasis(verse, <String>[
        'faith',
      ], match: SearchMatchMode.partial);
      expect(partial, hasLength(3));
    },
  );
}

Map<String, Object?> _fixture(String name) => Map<String, Object?>.from(
  (jsonDecode(File('test/fixtures/service_envelopes.json').readAsStringSync())
          as Map)[name]
      as Map,
);

OnlineSearchRequest _request() => OnlineSearchRequest(
  translation: 'tst',
  text: 'faith',
  criteria: OnlineSearchCriteria(),
);

OnlineSearchPage _page(
  List<int> verses, {
  required int total,
  int offset = 0,
  bool hasMore = false,
  String? sha = 'first',
  int engine = 5,
}) => OnlineSearchPage(
  kind: SearchResultKind.search,
  hits: verses.map((int verse) => _hit(verse)).toList(),
  total: total,
  returned: verses.length,
  engineVersion: engine,
  offset: offset,
  hasMore: hasMore,
  sourceSha: sha,
);

OnlineSearchHit _hit(int number) => OnlineSearchHit(
  translation: 'tst',
  book: 1,
  bookName: 'Fixture',
  chapter: 1,
  verse: Verse(
    chapter: 1,
    verse: number,
    name: 'Fixture 1:$number',
    text: 'Faith $number',
  ),
  reference: 'Fixture 1:$number',
  direction: 'LTR',
  terms: const <String>['faith'],
);

final class _Repository implements SearchRepository {
  _Repository(this.pages);
  final List<Future<OnlineSearchPage>> pages;
  final List<OnlineSearchRequest> requests = <OnlineSearchRequest>[];
  final List<RequestCancellation?> tokens = <RequestCancellation?>[];
  @override
  Future<OnlineSearchPage> search(
    OnlineSearchRequest request, {
    RequestCancellation? cancellation,
  }) {
    requests.add(request);
    tokens.add(cancellation);
    return pages.removeAt(0);
  }
}

final class _CountingRepository implements SearchRepository {
  int lastOffset = 0;
  int calls = 0;
  @override
  Future<OnlineSearchPage> search(
    OnlineSearchRequest request, {
    RequestCancellation? cancellation,
  }) async {
    calls += 1;
    lastOffset = request.offset;
    return _page(
      List<int>.generate(100, (int index) => request.offset + index + 1),
      total: 20000,
      offset: request.offset,
      hasMore: true,
    );
  }
}
