import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:getbible_live/application/app_state.dart';
import 'package:getbible_live/data/database/local_database.dart';
import 'package:getbible_live/domain/models/passage.dart';
import 'package:getbible_live/domain/models/preferences.dart';
import 'package:getbible_live/main.dart';
import 'package:getbible_live/presentation/widgets/reference_preview.dart';
import 'package:getbible_live/presentation/widgets/scripture_verse_text.dart';
import 'package:provider/provider.dart';

import 'reader_api_fixture.dart';

/// Runs against the complete reader with deterministic v3 and Query services.
/// Shared by widget CI and the native integration runner; no live API is needed.
void readerUpgradeJourney({bool nativeClipboard = false}) {
  testWidgets(
    'preview Copy and Close preserve position; Open reveals verse 70',
    (WidgetTester tester) async {
      if (!nativeClipboard) {
        String? clipboard;
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          (MethodCall call) async {
            if (call.method == 'Clipboard.setData') {
              clipboard =
                  (call.arguments as Map<Object?, Object?>)['text'] as String?;
            }
            if (call.method == 'Clipboard.getData') {
              return <String, Object?>{'text': clipboard};
            }
            return null;
          },
        );
        addTearDown(
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            SystemChannels.platform,
            null,
          ),
        );
      }
      final ReaderApiFixture fixture = ReaderApiFixture(lastVerse: 80);
      const Passage original = Passage(
        translation: 'tst',
        book: 1,
        chapter: 1,
        verse: 1,
      );
      final AppState state = (await tester.runAsync(() async {
        final LocalDatabase database = await LocalDatabase.memory();
        final AppState state = AppState.fromDatabase(
          database,
          api: fixture.api,
        );
        await state.settings.saveLastReadingPosition(
          LastReadingPosition(
            passage: original,
            verse: 1,
            updatedAt: DateTime.utc(2026, 1, 1),
          ),
        );
        await state.initialize();
        await state.saveVerseNote(1, 'Genesis 1:1', 'My private note');
        await state.setSourceStyles(false);
        return state;
      }))!;
      addTearDown(state.close);
      expect(state.error, isNull);
      final LastReadingPosition? before = await tester
          .runAsync<LastReadingPosition?>(
            state.settings.getLastReadingPosition,
          );

      await tester.pumpWidget(
        ChangeNotifierProvider.value(value: state, child: const GetBibleApp()),
      );
      await tester.pumpAndSettle();
      expect(find.text('My private note'), findsOneWidget);

      Future<void> preview() async {
        await tester.tap(find.widgetWithText(TextButton, 'Fixture 1'));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const ValueKey<String>('reference-preview-input')),
          'Genesis 1:70',
        );
        await tester.tap(find.text('Preview'));
        await tester.pumpAndSettle();
        expect(find.text('Copy'), findsOneWidget);
        expect(state.passage, original);
      }

      await preview();
      await tester.tap(find.text('Copy'));
      // A frame becoming idle does not acknowledge an asynchronous platform
      // write. The preview presents this message only after setData completes.
      await _waitForPlatformAction(
        tester,
        () => find.text('Scripture copied').evaluate().isNotEmpty,
        'Copy must acknowledge the native clipboard write before reading it.',
      );
      final ClipboardData? copied = await tester.runAsync<ClipboardData?>(
        () => Clipboard.getData('text/plain'),
      );
      // Flutter's Android lifecycle starts with an assumed focused window;
      // `resumed` alone cannot prove OS clipboard access. The emulator runner
      // checks native window readiness, and this read must still prove that
      // the real clipboard contains the text produced by the user's action.
      expect(
        copied?.text,
        contains('Verse 70 original.'),
        reason:
            'Copy was acknowledged, but native clipboard readback failed. '
            'On Android inspect runtime-evidence/window.txt and logcat.txt '
            'for input focus or a system dialog.',
      );
      expect(state.passage, original);
      await tester.tap(find.byTooltip('Close reference preview'));
      await tester.pumpAndSettle();
      expect(find.byType(ReferencePreview), findsNothing);
      final LastReadingPosition? afterClose = await tester
          .runAsync<LastReadingPosition?>(
            state.settings.getLastReadingPosition,
          );
      expect(afterClose?.passage, before?.passage);
      expect(afterClose?.updatedAt, before?.updatedAt);

      // An unsaved note must never follow a preview into another passage.
      await tester.tap(find.text('My private note'));
      await tester.pumpAndSettle();
      final Finder noteInput = find.byWidgetPredicate(
        (Widget widget) =>
            widget is TextField &&
            widget.decoration?.hintText == 'Write your note…',
      );
      await tester.enterText(noteInput, 'An unsaved private draft');
      await preview();
      await tester.tap(find.text('Open in reader'));
      await tester.pumpAndSettle();
      expect(
        find.text(
          'Save or close the note editor before opening another reference.',
        ),
        findsOneWidget,
      );
      expect(state.passage, original);
      expect(state.savedNotes.single.text, 'My private note');
      await tester.tap(find.byTooltip('Close reference preview'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(noteInput).controller?.text,
        'An unsaved private draft',
      );
      await tester.tap(find.byTooltip('Close note editor'));
      await tester.pumpAndSettle();

      await preview();
      await tester.tap(find.text('Open in reader'));
      // SQL, platform messages and isolate work use the real event loop.
      for (int attempt = 0; attempt < 100; attempt++) {
        await tester.runAsync(() async {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        });
        await tester.pump(const Duration(milliseconds: 16));
        if (!state.loading &&
            find.byType(ReferencePreview).evaluate().isEmpty) {
          break;
        }
      }
      await tester.pumpAndSettle();
      expect(find.byType(ReferencePreview), findsNothing);
      expect(
        state.passage,
        const Passage(translation: 'tst', book: 1, chapter: 1, verse: 70),
      );
      final Finder verse = find.byWidgetPredicate(
        (Widget widget) =>
            widget is ScriptureVerseText && widget.verse.verse == 70,
      );
      expect(verse, findsOneWidget);
      final Rect bounds = tester.getRect(verse);
      expect(bounds.top, greaterThanOrEqualTo(0));
      expect(bounds.bottom, lessThan(tester.view.physicalSize.height));
      expect(state.preferences.showSourceStyles, isFalse);
      final LastReadingPosition? opened = await tester
          .runAsync<LastReadingPosition?>(
            state.settings.getLastReadingPosition,
          );
      expect(opened?.passage, state.passage);
      expect(state.savedNotes.single.text, 'My private note');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}

Future<void> _waitForPlatformAction(
  WidgetTester tester,
  bool Function() complete,
  String reason,
) async {
  final Stopwatch deadline = Stopwatch()..start();
  while (!complete() && deadline.elapsed < const Duration(seconds: 10)) {
    // Platform channels run on the real event loop in both host widget tests
    // and installed-app tests. Poll an explicit completion condition, never a
    // guessed number of frames or an unconditional settling delay.
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    });
    await tester.pump(const Duration(milliseconds: 16));
  }
  expect(complete(), isTrue, reason: reason);
}
