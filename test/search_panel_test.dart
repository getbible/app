import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:getbible_live/application/online_search_controller.dart';
import 'package:getbible_live/core/errors.dart';
import 'package:getbible_live/core/request_cancellation.dart';
import 'package:getbible_live/domain/models/bible.dart';
import 'package:getbible_live/domain/models/online_search.dart';
import 'package:getbible_live/domain/models/search.dart';
import 'package:getbible_live/domain/models/service_envelopes.dart';
import 'package:getbible_live/domain/repositories/search_repository.dart';
import 'package:getbible_live/presentation/widgets/scripture_verse_text.dart';
import 'package:getbible_live/presentation/widgets/search_panel.dart';

void main() {
  testWidgets(
    'selected phrase is passed exactly; narrow RTL 200% panel remains native and opens the exact result',
    (WidgetTester tester) async {
      tester.view.physicalSize = const Size(320, 740);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final _Repository repository = _Repository();
      final OnlineSearchController controller = OnlineSearchController(
        repository: repository,
      );
      addTearDown(controller.dispose);
      OnlineSearchHit? opened;
      const String phrase = '  שלום  עולם\n';
      await tester.pumpWidget(
        MaterialApp(
          builder: (BuildContext context, Widget? child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(2)),
            child: Directionality(
              textDirection: TextDirection.rtl,
              child: child!,
            ),
          ),
          home: Scaffold(
            body: SearchPanel(
              controller: controller,
              translation: 'tst',
              books: const <BibleBook>[],
              initialQuery: phrase,
              initialPhrase: true,
              direction: 'RTL',
              onOpen: (OnlineSearchHit hit) async => opened = hit,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(repository.requests.single.text, phrase);
      expect(repository.requests.single.criteria.words, SearchWordMode.phrase);
      expect(repository.requests.single.direction, 'RTL');
      expect(find.text('1 of 1 results loaded.'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('Open Fixture 1:70'),
        180,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      final ScriptureVerseText verse = tester.widget<ScriptureVerseText>(
        find.byType(ScriptureVerseText),
      );
      expect(verse.textDirection, TextDirection.rtl);
      expect(verse.verse.text, 'שלום  עולם');
      await tester.tap(find.text('Open Fixture 1:70'));
      await tester.pumpAndSettle();
      expect(opened!.verse.verse, 70);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'changing input cancels late results; keyboard submission searches current text',
    (WidgetTester tester) async {
      final Completer<OnlineSearchPage> pending = Completer<OnlineSearchPage>();
      final _Repository repository = _Repository(pending: pending);
      final OnlineSearchController controller = OnlineSearchController(
        repository: repository,
      );
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SearchPanel(
              controller: controller,
              translation: 'tst',
              books: const <BibleBook>[],
              initialQuery: 'old phrase',
              onOpen: (_) async {},
            ),
          ),
        ),
      );
      await tester.pump();
      expect(controller.isLoading, true);
      await tester.enterText(
        find.byKey(const ValueKey<String>('online-search-query')),
        'new phrase',
      );
      expect(repository.tokens.first!.isCancelled, true);
      pending.complete(_page());
      await tester.pump();
      expect(controller.results, isEmpty);
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      expect(repository.requests.last.text, 'new phrase');
      expect(controller.results.single.verse.verse, 70);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'reference result explains filters and offers no full-text pagination',
    (WidgetTester tester) async {
      final _Repository repository = _Repository(reference: true);
      final OnlineSearchController controller = OnlineSearchController(
        repository: repository,
      );
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SearchPanel(
              controller: controller,
              translation: 'tst',
              books: const <BibleBook>[],
              initialQuery: 'Fixture 1:70',
              onOpen: (_) async {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.text(
          '1 verses in the resolved reference. Full-text filters do not apply.',
        ),
        findsOneWidget,
      );
      expect(find.text('Load more results'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'opening search with another translation clears completed previous results',
    (WidgetTester tester) async {
      final _Repository repository = _Repository();
      final OnlineSearchController controller = OnlineSearchController(
        repository: repository,
      );
      addTearDown(controller.dispose);
      await controller.search('tst', 'previous');
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SearchPanel(
              controller: controller,
              translation: 'another',
              books: const <BibleBook>[],
              onOpen: (_) async {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(controller.results, isEmpty);
      expect(controller.request, isNull);
      expect(find.text('Open Fixture 1:70'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'failed Open keeps the selected search and displays a recoverable error',
    (WidgetTester tester) async {
      final OnlineSearchController controller = OnlineSearchController(
        repository: _Repository(),
      );
      addTearDown(controller.dispose);
      int attempts = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SearchPanel(
              controller: controller,
              translation: 'tst',
              books: const <BibleBook>[],
              initialQuery: 'faith',
              onOpen: (_) async {
                attempts += 1;
                if (attempts == 1) {
                  throw StateError('Requested verse unavailable');
                }
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Open Fixture 1:70'));
      await tester.pumpAndSettle();
      expect(find.byType(SearchPanel), findsOneWidget);
      expect(
        find.textContaining('Requested verse unavailable'),
        findsOneWidget,
      );
      expect(controller.request!.text, 'faith');
      expect(controller.results.single.verse.verse, 70);
      await tester.tap(find.text('Open Fixture 1:70'));
      await tester.pumpAndSettle();
      expect(attempts, 2);
      expect(find.textContaining('Requested verse unavailable'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'reopened rate-limited search restores the Retry availability timer',
    (WidgetTester tester) async {
      DateTime now = DateTime.utc(2026);
      final OnlineSearchController controller = OnlineSearchController(
        repository: _RateLimitedRepository(),
        now: () => now,
      );
      addTearDown(controller.dispose);
      await controller.search('tst', 'faith');
      controller.cancel();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SearchPanel(
              controller: controller,
              translation: 'tst',
              books: const <BibleBook>[],
              onOpen: (_) async {},
            ),
          ),
        ),
      );
      await tester.pump();
      final Finder retry = find.widgetWithText(OutlinedButton, 'Retry');
      expect(tester.widget<OutlinedButton>(retry).onPressed, isNull);
      now = now.add(const Duration(seconds: 30));
      await tester.pump(const Duration(seconds: 30));
      expect(tester.widget<OutlinedButton>(retry).onPressed, isNotNull);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}

final class _RateLimitedRepository implements SearchRepository {
  @override
  Future<OnlineSearchPage> search(
    OnlineSearchRequest request, {
    RequestCancellation? cancellation,
  }) async => throw RateLimitException(
    Uri.parse('https://search.getbible.net/v3/tst'),
    retryAfter: const Duration(seconds: 30),
  );
}

OnlineSearchPage _page({bool reference = false}) => OnlineSearchPage(
  kind: reference ? SearchResultKind.reference : SearchResultKind.search,
  hits: const <OnlineSearchHit>[
    OnlineSearchHit(
      translation: 'tst',
      book: 1,
      bookName: 'Fixture',
      chapter: 1,
      verse: Verse(
        chapter: 1,
        verse: 70,
        name: 'Fixture 1:70',
        text: 'שלום  עולם',
      ),
      reference: 'Fixture 1:70',
      direction: 'RTL',
      terms: <String>['שלום'],
    ),
  ],
  total: 1,
  returned: 1,
  engineVersion: 5,
  offset: 0,
  hasMore: false,
  sourceSha: reference ? null : 'source',
);

final class _Repository implements SearchRepository {
  _Repository({this.pending, this.reference = false});
  final Completer<OnlineSearchPage>? pending;
  final bool reference;
  final List<OnlineSearchRequest> requests = <OnlineSearchRequest>[];
  final List<RequestCancellation?> tokens = <RequestCancellation?>[];
  @override
  Future<OnlineSearchPage> search(
    OnlineSearchRequest request, {
    RequestCancellation? cancellation,
  }) {
    requests.add(request);
    tokens.add(cancellation);
    if (requests.length == 1 && pending != null) return pending!.future;
    return Future<OnlineSearchPage>.value(_page(reference: reference));
  }
}
