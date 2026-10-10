import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:getbible_live/application/app_state.dart';
import 'package:getbible_live/data/database/local_database.dart';
import 'package:getbible_live/domain/models/notebook.dart';
import 'package:getbible_live/domain/models/passage.dart';
import 'package:getbible_live/domain/models/preferences.dart';
import 'package:getbible_live/main.dart';
import 'package:getbible_live/presentation/widgets/keyboard_inset_padding.dart';
import 'package:getbible_live/presentation/widgets/notes_panel.dart';
import 'package:getbible_live/presentation/widgets/scripture_verse_text.dart';
import 'package:getbible_live/presentation/widgets/study_workspace.dart';
import 'package:provider/provider.dart';

import 'support/study_api_fixture.dart';

const Passage _origin = Passage(
  translation: 'tst',
  book: 1,
  chapter: 1,
  verse: 1,
);

void main() {
  testWidgets(
    'compact Study retains its context through reverse animation and can reopen after disposal',
    (tester) async {
      _configureView(tester, const Size(390, 844));
      addTearDown(tester.view.resetViewInsets);
      final state = await _createReader(tester);
      await _showReader(tester, state);
      final launcher = find.byTooltip(state.ui('study'));
      await tester.tap(launcher);
      await _settle(tester);
      final workspace = tester.widget<StudyWorkspace>(
        find.byType(StudyWorkspace),
      );
      final captured = workspace.context;
      for (final double inset in <double>[180, -0.25, 0]) {
        tester.view.viewInsets = FakeViewPadding(bottom: inset);
        await tester.pump();
        expect(tester.takeException(), isNull);
        final padding = tester.widget<Padding>(
          find
              .descendant(
                of: find.byType(KeyboardInsetPadding),
                matching: find.byType(Padding),
              )
              .first,
        );
        expect(padding.padding, EdgeInsets.only(bottom: inset < 0 ? 0 : inset));
        expect(
          tester.widget<StudyWorkspace>(find.byType(StudyWorkspace)).context,
          same(captured),
        );
      }

      await tester.tap(find.byTooltip('Close Study tools'));
      await tester.pump();
      // Pop has completed, but the bottom sheet's reverse animation has not.
      // Native keyboard and annotation notifications can still rebuild it.
      tester.view.viewInsets = const FakeViewPadding(bottom: 180);
      await tester.runAsync(state.refreshAnnotations);
      await tester.pump(const Duration(milliseconds: 20));
      expect(tester.takeException(), isNull);
      expect(
        tester.widget<StudyWorkspace>(find.byType(StudyWorkspace)).context,
        same(captured),
      );
      tester.view.viewInsets = const FakeViewPadding(bottom: -0.25);
      await tester.pump(const Duration(milliseconds: 20));
      expect(tester.takeException(), isNull);
      workspace.onClose(); // A repeated close must not pop the reader route.
      await tester.pump(const Duration(milliseconds: 20));
      expect(tester.takeException(), isNull);
      expect(state.passage, _origin);

      tester.view.resetViewInsets();
      await _settle(tester);
      expect(find.byType(StudyWorkspace), findsNothing);
      await tester.tap(launcher);
      await _settle(tester);
      expect(find.byType(StudyWorkspace), findsOneWidget);
      expect(
        tester.widget<StudyWorkspace>(find.byType(StudyWorkspace)).context,
        isNot(same(captured)),
      );
      expect(state.passage, _origin);
      await tester.tap(find.byTooltip('Close Study tools'));
      await _settle(tester);
      expect(find.byType(StudyWorkspace), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final double width in <double>[640, 1250]) {
    testWidgets(
      'nested notebook preview retains a functional insertion dialog at width $width',
      (WidgetTester tester) async {
        _configureView(tester, Size(width, 900));
        final AppState state = await _createReader(tester);
        await tester.runAsync(() => state.study.notebooks.createNotebook());
        await _showReader(tester, state);

        final Finder scripture = find.descendant(
          of: find.byType(ScriptureVerseText).first,
          matching: find.byType(SelectableText),
        );
        await tester.tapAt(tester.getTopLeft(scripture) + const Offset(24, 15));
        await tester.pump(const Duration(milliseconds: 400));
        await _settle(tester);
        expect(find.byType(StudyWorkspace), findsOneWidget);

        await tester.tap(find.byType(DropdownButtonFormField<StudyTab>));
        await tester.pumpAndSettle();
        await tester.tap(find.text(StudyTab.notes.label).last);
        await _settle(tester);
        expect(find.byType(NotesPanel), findsOneWidget);

        final Finder insertAction = find.text('Insert current Scripture');
        await tester.scrollUntilVisible(
          insertAction,
          200,
          scrollable: find
              .descendant(
                of: find.byKey(const ValueKey<String>('notes-panel-list')),
                matching: find.byType(Scrollable),
              )
              .first,
        );
        await tester.pumpAndSettle();
        await tester.tap(insertAction);
        await _settle(tester);
        expect(find.text('Insert Scripture'), findsOneWidget);

        await tester.tap(find.text('Open reference preview'));
        await _settle(tester);
        await tester.tap(find.text('Open in reader'));
        await _settle(tester);

        // Only the preview owns the dismissed route. The originating Study
        // widget and its pending insertion remain usable on either layout.
        expect(find.byType(StudyWorkspace), findsOneWidget);
        expect(find.byType(NotesPanel), findsOneWidget);
        expect(find.text('Insert Scripture'), findsOneWidget);
        expect(state.passage, _origin);

        await tester.tap(find.widgetWithText(FilledButton, 'Insert'));
        await _settle(tester);
        final bool? saved = await tester.runAsync(state.study.notebooks.flush);
        expect(saved, isTrue);
        final Notebook? notebook = await tester.runAsync<Notebook?>(
          () => state.study.notebooks.repository.notebook(
            state.study.notebooks.selectedId!,
          ),
        );
        expect(notebook!.blocks, hasLength(2));
        expect(notebook.blocks.last.reference!.quotation, 'Kadesh.');
        expect(notebook.blocks.last.reference!.passage, _origin);
        expect(tester.takeException(), isNull);

        await tester.tap(find.byTooltip('Close Study tools'));
        await _settle(tester);
        expect(find.byType(StudyWorkspace), findsNothing);
        expect(state.passage, _origin);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  for (final double width in <double>[320, 720]) {
    testWidgets(
      'compact toolbar stays bounded and accessible at width $width and 200% text',
      (WidgetTester tester) async {
        _configureView(tester, Size(width, 900));
        tester.platformDispatcher.textScaleFactorTestValue = 2;
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        final AppState state = await _createReader(tester);
        await _showReader(tester, state);
        final Finder toolbar = find.byType(AppBar);
        for (final String label in <String>[
          state.ui('searchThisTranslation'),
          state.ui('openAsMarkdown'),
          state.ui('study'),
        ]) {
          final Finder action = find.descendant(
            of: toolbar,
            matching: find.byTooltip(label),
          );
          expect(action, findsOneWidget);
          final Size size = tester.getSize(action);
          expect(size.width, greaterThanOrEqualTo(48));
          expect(size.height, greaterThanOrEqualTo(48));
        }
        expect(
          find.descendant(
            of: toolbar,
            matching: find.byTooltip(state.ui('previousChapter')),
          ),
          findsNothing,
        );
        expect(find.text('Previous'), findsOneWidget);
        expect(find.text('Next'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
}

void _configureView(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Future<AppState> _createReader(WidgetTester tester) async {
  final StudyApiFixture fixture = StudyApiFixture();
  final AppState state = (await tester.runAsync(() async {
    final AppState state = AppState.fromDatabase(
      await LocalDatabase.memory(),
      api: fixture.reader.api,
    );
    await state.settings.saveLastReadingPosition(
      LastReadingPosition(
        passage: _origin,
        verse: 1,
        updatedAt: DateTime.utc(2026, 10, 8),
      ),
    );
    await state.initialize();
    return state;
  }))!;
  addTearDown(state.close);
  return state;
}

Future<void> _showReader(WidgetTester tester, AppState state) async {
  await tester.pumpWidget(
    ChangeNotifierProvider.value(value: state, child: const GetBibleApp()),
  );
  await _settle(tester);
  expect(tester.takeException(), isNull);
}

Future<void> _settle(WidgetTester tester) async {
  await tester.runAsync(
    () async => Future<void>.delayed(const Duration(milliseconds: 40)),
  );
  await tester.pumpAndSettle();
}
