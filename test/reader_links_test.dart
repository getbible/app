import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:getbible/application/app_state.dart';
import 'package:getbible/data/database/local_database.dart';
import 'package:getbible/domain/models/passage.dart';
import 'package:getbible/domain/models/preferences.dart';
import 'package:getbible/main.dart';
import 'package:getbible/presentation/reader_router.dart';
import 'package:getbible/presentation/reader_screen.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import 'support/reader_api_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('friendly links preserve Unicode, literal percent and exact verse', () {
    const passage = Passage(
      translation: 'tst',
      book: 99,
      chapter: 4,
      verse: 17,
    );
    final uri = shareablePassageUri(passage, 'Café 100% λόγος');
    final link = parsePassageLink(uri)!;
    expect(link.bookSlug, 'Café-100%-λόγος');
    expect(link.verse, 17);
    expect(bookMatchesSlug('Cafe\u0301', 'Café'), isTrue);
    expect(
      parsePassageLink(Uri.parse('getbible:///TST/Genesis/1?verse=3'))?.verse,
      3,
    );
    expect(
      parsePassageLink(Uri.parse('getbible://TST/Genesis/1/3'))?.translation,
      'tst',
    );
    for (final invalid in [
      'https://example.org/TST/Genesis/1',
      'https://getbible.life/TST/Genesis/1',
      '//example.org/TST/Genesis/1',
      'javascript:/TST/Genesis/1',
      '/TST/Genesis/1?verse=1&verse=2',
      '/TST/Genesis/1/2?verse=3',
      '/TST/Genesis/0?verse=1',
      '/TST/Genesis/1?verse=no',
    ]) {
      expect(parsePassageLink(Uri.parse(invalid)), isNull, reason: invalid);
    }
  });

  test(
    'initial link wins over last position; bad link never opens daily/default',
    () async {
      final fixture = ReaderApiFixture();
      final state = AppState.fromDatabase(
        await LocalDatabase.memory(),
        api: fixture.api,
      );
      addTearDown(state.close);
      await state.settings.saveLastReadingPosition(
        LastReadingPosition(
          passage: const Passage(translation: 'tst', book: 1, chapter: 1),
          verse: 3,
          updatedAt: DateTime.now().toUtc(),
        ),
      );
      await state.initialize(
        initialUri: Uri.parse('/TST/Extended-Book/7?verse=1'),
      );
      expect(state.passage.book, ReaderApiFixture.extendedBook);
      expect(state.passage.verse, 1);
      final position = await state.settings.getLastReadingPosition();
      await state.openPassageLink(Uri.parse('/TST/Genesis/1?verse=2'));
      expect(state.error, contains('verse is not available'));
      expect(state.passage, position!.passage);
      expect(
        (await state.settings.getLastReadingPosition())!.passage,
        position.passage,
      );
      await state.retryReading();
      expect(state.error, contains('verse is not available'));
      expect(fixture.paths.any((path) => path.contains('daily')), isFalse);
    },
  );

  test(
    'restart restores saved visible verse independently from chapter route',
    () async {
      final state = AppState.fromDatabase(
        await LocalDatabase.memory(),
        api: ReaderApiFixture().api,
      );
      addTearDown(state.close);
      await state.loadPassage(
        const Passage(translation: 'tst', book: 1, chapter: 1),
      );
      await state.recordReadingPosition(3);
      await state.initialize();
      expect(state.passage.verse, 3);
    },
  );

  for (final destination in ['/TST/Genesis/1?verse=1', '/']) {
    test('Back to $destination supersedes a delayed external link', () async {
      final fixture = ReaderApiFixture()..delayedIndex = Completer<void>();
      final state = AppState.fromDatabase(
        await LocalDatabase.memory(),
        api: fixture.api,
      );
      await state.loadPassage(
        const Passage(translation: 'tst', book: 1, chapter: 1, verse: 1),
      );
      final navigation = ReaderRouter(state);
      addTearDown(() async {
        navigation.dispose();
        await state.close();
      });
      await navigation.ready;
      navigation.openNative(Uri.parse('getbible:///TST/Extended-Book/7'));
      await fixture.indexStarted.future;
      navigation.router.go(destination);
      await _waitForIdle(state);
      // Slow superseded work must not suppress subsequent reader actions.
      await state.loadPassage(state.passage.copyWith(verse: 3));
      expect(
        navigation.router.routeInformationProvider.value.uri.toString(),
        '/TST/Genesis/1?verse=3',
      );
      fixture.delayedIndex!.complete();
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(state.passage.book, 1);
      expect(state.passage.verse, 3);
      expect(
        navigation.router.routeInformationProvider.value.uri.toString(),
        '/TST/Genesis/1?verse=3',
      );
      expect((await state.settings.getLastReadingPosition())!.passage.book, 1);
    });
  }

  testWidgets('cold URL, native link and browser history use the real reader', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    try {
      final state = (await tester.runAsync(
        () async => AppState.fromDatabase(
          await LocalDatabase.memory(),
          api: ReaderApiFixture(lastVerse: 40).api,
        ),
      ))!;
      addTearDown(state.close);
      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: state,
          child: GetBibleApp(
            initialize: true,
            initialUri: Uri.parse('/TST/Genesis/1?verse=35'),
          ),
        ),
      );
      await _settle(tester, state);
      expect(state.passage.verse, 35);
      expect(find.text('35'), findsOneWidget);
      expect(
        find.bySemanticsLabel(RegExp(r'^Genesis 1:35\. Verse 35 original\.')),
        findsOneWidget,
      );
      expect(
        tester
            .widgetList<SelectableText>(find.byType(SelectableText))
            .any(
              (text) =>
                  text.textSpan?.toPlainText(includePlaceholders: false) ==
                  'Verse 35 original.',
            ),
        isTrue,
        reason: 'The accessible label must retain native selectable Scripture.',
      );
      final router = GoRouter.of(tester.element(find.byType(ReaderScreen)));
      expect(
        router.routeInformationProvider.value.uri.queryParameters['verse'],
        '35',
      );
      // Native activations arrive independently of the widget scheduling zone.
      // Completed position writes from cold startup must not retain that zone.
      await tester.runAsync(
        () => state.openPassageLink(
          Uri.parse('getbible:///TST/Extended-Book/7?verse=1'),
        ),
      );
      await _settle(tester, state);
      expect(
        router.routeInformationProvider.value.uri.path,
        '/TST/Extended-Book/7',
      );
      // Platform route information is the same callback used by browser Back.
      await GoRouter.of(
        tester.element(find.byType(ReaderScreen)),
      ).routeInformationProvider.didPushRouteInformation(
        RouteInformation(uri: Uri.parse('/TST/Genesis/1?verse=3')),
      );
      await _settle(tester, state);
      expect(state.passage.book, 1);
      expect(state.passage.verse, 3);
      expect(find.text('3'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    } finally {
      semantics.dispose();
    }
  });

  testWidgets(
    'browser navigation keeps unsaved inline draft and its source URL',
    (tester) async {
      final semantics = tester.ensureSemantics();
      try {
        final state = (await tester.runAsync(() async {
          final state = AppState.fromDatabase(
            await LocalDatabase.memory(),
            api: ReaderApiFixture().api,
          );
          await state.loadPassage(
            const Passage(translation: 'tst', book: 1, chapter: 1, verse: 1),
          );
          return state;
        }))!;
        addTearDown(state.close);
        await tester.pumpWidget(
          ChangeNotifierProvider.value(
            value: state,
            child: const GetBibleApp(),
          ),
        );
        await _settle(tester, state);
        await tester.tap(find.text('1').first);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Add note'));
        await tester.pumpAndSettle();
        final editor = find.widgetWithText(TextField, 'Write your note…');
        await tester.enterText(editor, 'Kept across history and layout');
        await GoRouter.of(
          tester.element(find.byType(ReaderScreen)),
        ).routeInformationProvider.didPushRouteInformation(
          RouteInformation(uri: Uri.parse('/TST/Extended-Book/7')),
        );
        await _settle(tester, state);
        expect(state.passage.book, 1);
        expect(
          tester.widget<TextField>(editor).controller!.text,
          'Kept across history and layout',
        );
        final router = GoRouter.of(tester.element(find.byType(ReaderScreen)));
        expect(
          router.routeInformationProvider.value.uri.path,
          '/TST/Genesis/1',
        );
        await tester.runAsync(() => state.setLayout(ReaderLayout.paragraph));
        await tester.pumpAndSettle();
        expect(
          find.bySemanticsLabel(RegExp(r'^Genesis 1:1\.  First verse\. ')),
          findsOneWidget,
        );
        expect(
          tester.widget<TextField>(editor).controller!.text,
          'Kept across history and layout',
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      } finally {
        semantics.dispose();
      }
    },
  );
}

Future<void> _settle(WidgetTester tester, AppState state) async {
  await tester.pump();
  for (var attempt = 0; attempt < 100; attempt++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 30));
    if (!state.loading) {
      await tester.pumpAndSettle();
      return;
    }
  }
  fail('Reader route did not settle: ${state.error}');
}

Future<void> _waitForIdle(AppState state) async {
  for (var attempt = 0; attempt < 100; attempt++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
    if (!state.loading) return;
  }
  fail('Passage navigation did not settle: ${state.error}');
}
