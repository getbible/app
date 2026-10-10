import 'dart:async';
import 'dart:ui' show ViewFocusDirection, ViewFocusEvent, ViewFocusState;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:getbible_live/application/app_state.dart';
import 'package:getbible_live/data/database/local_database.dart';
import 'package:getbible_live/domain/models/passage.dart';
import 'package:getbible_live/domain/models/preferences.dart';
import 'package:getbible_live/main.dart';
import 'package:getbible_live/presentation/reader_screen.dart';
import 'package:go_router/go_router.dart';

import 'support/reader_api_fixture.dart';

void main() {
  for (final requestedVerse in [3, 2]) {
    testWidgets(
      'production bootstrap retains launch verse $requestedVerse over a reset platform route',
      (tester) async {
        const messages = MethodChannel('com.llfbandit.app_links/messages');
        const events = MethodChannel('com.llfbandit.app_links/events');
        final messenger = tester.binding.defaultBinaryMessenger;
        messenger.setMockMethodCallHandler(messages, (_) async => null);
        messenger.setMockMethodCallHandler(events, (_) async => null);
        addTearDown(() {
          messenger.setMockMethodCallHandler(messages, null);
          messenger.setMockMethodCallHandler(events, null);
          tester.platformDispatcher.clearDefaultRouteNameTestValue();
        });

        final fixture = ReaderApiFixture();
        final state = (await tester.runAsync(() async {
          final state = AppState.fromDatabase(
            await LocalDatabase.memory(),
            api: fixture.api,
          );
          // Start with real cached Scripture and a different durable position.
          // The production session still has no current chapter in memory.
          await state.bibles.getTranslations();
          await state.bibles.getBooks('tst');
          await state.bibles.getChapters('tst', 1);
          await state.bibles.getChapter('tst', 1, 1);
          await state.settings.saveLastReadingPosition(
            LastReadingPosition(
              passage: const Passage(
                translation: 'tst',
                book: ReaderApiFixture.extendedBook,
                chapter: 7,
                verse: 1,
              ),
              verse: 1,
              updatedAt: DateTime.now().toUtc(),
            ),
          );
          return state;
        }))!;
        addTearDown(state.close);
        fixture.paths.clear();
        try {
          final opening = Completer<AppState>();
          final location = '/TST/Genesis/1?verse=$requestedVerse';
          tester.platformDispatcher.defaultRouteNameTestValue = location;
          final bootstrap = ReaderBootstrap(createState: () => opening.future);
          await tester.pumpWidget(bootstrap);
          await tester.pump();
          expect(find.text('Opening local data'), findsOneWidget);
          _focusView(tester);
          await tester.pump();
          expect(tester.takeException(), isNull);
          // The temporary startup MaterialApp can report its root before the
          // actual reader is constructed. Its platform value is not the launch.
          tester.platformDispatcher.defaultRouteNameTestValue = '/';
          opening.complete(state);
          for (var attempt = 0; attempt < 100; attempt++) {
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 10)),
            );
            await tester.pump(const Duration(milliseconds: 20));
            _focusView(tester);
            if (!state.loading &&
                find.byType(ReaderScreen).evaluate().isNotEmpty) {
              break;
            }
          }
          await tester.pumpAndSettle();
          expect(state.loading, isFalse);
          final router = GoRouter.of(tester.element(find.byType(ReaderScreen)));
          expect(
            router.routeInformationProvider.value.uri.toString(),
            location,
          );
          if (requestedVerse == 3) {
            expect(state.passage.book, 1);
            expect(state.passage.verse, 3);
            expect(state.error, isNull);
          } else {
            expect(state.current, isNull);
            expect(state.error, contains('verse is not available'));
            final saved = await tester.runAsync(
              state.settings.getLastReadingPosition,
            );
            expect(saved!.passage.book, ReaderApiFixture.extendedBook);
          }
          expect(
            fixture.paths,
            everyElement('/v3/tst/1/1.sha'),
            reason: 'Only the requested cached chapter may be verified.',
          );
          expect(tester.takeException(), isNull);
        } finally {
          await tester.runAsync(state.close);
          await tester.pumpWidget(const SizedBox.shrink());
        }
      },
    );
  }
}

void _focusView(WidgetTester tester) {
  tester.binding.handleViewFocusChanged(
    ViewFocusEvent(
      viewId: tester.view.viewId,
      state: ViewFocusState.focused,
      direction: ViewFocusDirection.forward,
    ),
  );
}
