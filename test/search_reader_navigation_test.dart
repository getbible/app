import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:getbible/application/app_state.dart';
import 'package:getbible/data/database/local_database.dart';
import 'package:getbible/domain/models/passage.dart';
import 'package:getbible/domain/models/preferences.dart';
import 'package:getbible/main.dart';
import 'package:getbible/presentation/widgets/search_panel.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';

import 'support/reader_api_fixture.dart';

void main() {
  const Passage origin = Passage(
    translation: 'tst',
    book: 1,
    chapter: 1,
    verse: 1,
  );

  testWidgets(
    'composed Reader Search successful Open and close preserve safe widget disposal',
    (WidgetTester tester) async {
      final ReaderApiFixture fixture = ReaderApiFixture(
        resourceResponse: (http.Request request) async =>
            request.url.host == 'search.getbible.net'
            ? http.Response(jsonEncode(_reference()), 200)
            : null,
      );
      final AppState state = await _reader(tester, fixture, origin);
      await _search(tester, state, 'Genesis 1:3');
      final Finder open = find.text('Open Genesis 1:3');
      await tester.ensureVisible(open);
      await tester.pumpAndSettle();
      await tester.tap(open);
      await _settleIo(tester, state);
      expect(state.passage, origin.copyWith(verse: 3));
      expect(find.byType(SearchPanel), findsNothing);
      expect(tester.takeException(), isNull);

      await tester.tap(_searchLauncher());
      await tester.pumpAndSettle();
      expect(find.byType(SearchPanel), findsOneWidget);
      await tester.tap(find.byTooltip('Close search'));
      await tester.pumpAndSettle();
      expect(find.byType(SearchPanel), findsNothing);
      expect(state.passage, origin.copyWith(verse: 3));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'closing a composed pending Search cancels it without notifying a locked Provider tree',
    (WidgetTester tester) async {
      final Completer<http.Response> pending = Completer<http.Response>();
      final Completer<void> started = Completer<void>();
      final ReaderApiFixture fixture = ReaderApiFixture(
        resourceResponse: (http.Request request) async {
          if (request.url.host != 'search.getbible.net') return null;
          started.complete();
          return pending.future;
        },
      );
      final AppState state = await _reader(tester, fixture, origin);
      await tester.tap(_searchLauncher());
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey<String>('online-search-query')),
        'faith',
      );
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.runAsync(() => started.future);
      await tester.pump();
      expect(state.onlineSearch.isLoading, true);
      await tester.tap(find.byTooltip('Close search'));
      await tester.pumpAndSettle();
      pending.complete(http.Response(jsonEncode(_reference()), 200));
      await _settleIo(tester, state);
      expect(state.onlineSearch.isLoading, false);
      expect(state.onlineSearch.results, isEmpty);
      expect(state.passage, origin);
      expect(find.byType(SearchPanel), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'replacing query during delayed result Open invalidates old reader navigation',
    (WidgetTester tester) async {
      final ReaderApiFixture fixture = ReaderApiFixture(
        resourceResponse: (http.Request request) async =>
            request.url.host == 'search.getbible.net'
            ? http.Response(jsonEncode(_reference(extended: true)), 200)
            : null,
      );
      final AppState state = await _reader(tester, fixture, origin);
      await _search(tester, state, 'Extended Book 7:1');
      final Finder open = find.text('Open Extended Book 7:1');
      await tester.ensureVisible(open);
      await tester.pumpAndSettle();
      fixture.delayedIndex = Completer<void>();
      await tester.tap(open);
      await tester.runAsync(() => fixture.indexStarted.future);
      await tester.pump();
      final Finder query = find.byKey(
        const ValueKey<String>('online-search-query'),
      );
      await tester.ensureVisible(query);
      await tester.pump();
      await tester.enterText(query, 'New query');
      fixture.delayedIndex!.complete();
      await _settleIo(tester, state);
      expect(state.passage, origin);
      expect(find.byType(SearchPanel), findsOneWidget);
      expect(state.onlineSearch.request, isNull);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byTooltip('Close search'));
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'composed Search clears another translation during initialization without rebuilding locked ancestors',
    (WidgetTester tester) async {
      final ReaderApiFixture fixture = ReaderApiFixture(
        resourceResponse: (http.Request request) async {
          if (request.url.host != 'search.getbible.net') return null;
          return http.Response(
            jsonEncode(<String, Object?>{
              'query': <String, Object?>{
                'text': 'previous',
                'kind': 'search',
                'translation': request.url.pathSegments.last,
                'engine_version': 5,
                'total': 0,
                'returned': 0,
              },
              'results': <String, Object?>{},
              'matches': <Object?>[],
            }),
            200,
          );
        },
      );
      final AppState state = await _reader(tester, fixture, origin);
      await tester.runAsync(
        () => state.onlineSearch.search('other', 'previous'),
      );
      await tester.pumpAndSettle();
      expect(state.onlineSearch.request!.translation, 'other');
      await tester.tap(_searchLauncher());
      await tester.pumpAndSettle();
      expect(state.onlineSearch.request, isNull);
      expect(state.onlineSearch.results, isEmpty);
      expect(find.byType(SearchPanel), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byTooltip('Close search'));
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox());
    },
  );
}

Future<AppState> _reader(
  WidgetTester tester,
  ReaderApiFixture fixture,
  Passage origin,
) async {
  tester.view.physicalSize = const Size(1250, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final AppState state = (await tester.runAsync(() async {
    final AppState state = AppState.fromDatabase(
      await LocalDatabase.memory(),
      api: fixture.api,
    );
    await state.settings.saveLastReadingPosition(
      LastReadingPosition(
        passage: origin,
        verse: origin.verse ?? 1,
        updatedAt: DateTime.utc(2026),
      ),
    );
    await state.initialize();
    return state;
  }))!;
  addTearDown(state.close);
  await tester.pumpWidget(
    ChangeNotifierProvider.value(value: state, child: const GetBibleApp()),
  );
  await tester.pumpAndSettle();
  expect(state.error, isNull);
  return state;
}

Finder _searchLauncher() => find
    .ancestor(of: find.text('Search').first, matching: find.byType(InkWell))
    .first;

Future<void> _search(WidgetTester tester, AppState state, String query) async {
  await tester.tap(_searchLauncher());
  await tester.pumpAndSettle();
  await tester.enterText(
    find.byKey(const ValueKey<String>('online-search-query')),
    query,
  );
  await tester.testTextInput.receiveAction(TextInputAction.search);
  await _settleIo(tester, state);
}

Future<void> _settleIo(WidgetTester tester, AppState state) async {
  // SQLite workers complete on the real event loop, while UI-originated Future
  // continuations also need fake-clock pumps. Wait for the actual idle state
  // and keep both loops moving instead of assuming a fixed storage latency.
  final Stopwatch deadline = Stopwatch()..start();
  do {
    await tester.runAsync(
      () async => Future<void>.delayed(const Duration(milliseconds: 1)),
    );
    await tester.pump(const Duration(milliseconds: 20));
    if (deadline.elapsed > const Duration(seconds: 10)) {
      throw TimeoutException(
        'Reader and search operations did not become idle.',
      );
    }
  } while (state.loading || state.searchLoading);
  await tester.pumpAndSettle();
}

Map<String, Object?> _reference({bool extended = false}) {
  final int book = extended ? ReaderApiFixture.extendedBook : 1;
  final int chapter = extended ? 7 : 1;
  final int verse = extended ? 1 : 3;
  final String bookName = extended ? 'Extended Book' : 'Genesis';
  final String reference = '$bookName $chapter:$verse';
  return <String, Object?>{
    'query': <String, Object?>{
      'text': reference,
      'kind': 'reference',
      'translation': 'tst',
      'engine_version': 5,
      'total': 1,
      'returned': 1,
    },
    'results': <String, Object?>{
      'tst_${book}_$chapter': <String, Object?>{
        'book_nr': book,
        'book_name': bookName,
        'chapter': chapter,
        'verses': <Object?>[
          <String, Object?>{
            'verse': verse,
            'name': reference,
            'text': 'Verse $verse original.',
          },
        ],
      },
    },
    'matches': <Object?>[
      <String, Object?>{
        'reference': reference,
        'book_nr': book,
        'chapter': chapter,
        'verse': verse,
      },
    ],
  };
}
