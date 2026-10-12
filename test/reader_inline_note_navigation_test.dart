import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:getbible/application/app_state.dart';
import 'package:getbible/data/database/local_database.dart';
import 'package:getbible/domain/models/annotations.dart';
import 'package:getbible/domain/models/passage.dart';
import 'package:getbible/domain/models/preferences.dart';
import 'package:getbible/main.dart';
import 'package:provider/provider.dart';

import 'support/reader_api_fixture.dart';

const Passage _origin = Passage(
  translation: 'tst',
  book: 1,
  chapter: 1,
  verse: 1,
);
const Passage _other = Passage(
  translation: 'tst',
  book: ReaderApiFixture.extendedBook,
  chapter: 7,
  verse: 1,
);

void main() {
  testWidgets(
    'Home, passage and translation controls preserve an unsaved canonical verse note',
    (WidgetTester tester) async {
      final ReaderApiFixture fixture = ReaderApiFixture();
      final AppState state = await _createReader(tester, fixture);
      await _showReader(tester, state);
      await _editNote(tester);
      final List<String> requests = List<String>.of(fixture.paths);

      await tester.tap(find.text('getBible'));
      await tester.pumpAndSettle();
      expect(state.passage, _origin);
      expect(fixture.paths, requests);
      expect(
        find.text(
          'Save or close the verse note before opening another passage.',
        ),
        findsOneWidget,
      );
      expect(_draft(tester), 'Retained private draft');

      _expectPassageEnabled(tester, false);
      await tester.tap(find.byTooltip(state.ui('readerOptions')));
      await tester.pumpAndSettle();
      _expectBackupEnabled(tester, false);
      expect(
        find.textContaining('Passage controls are temporarily unavailable.'),
        findsOneWidget,
      );
      await tester.tapAt(const Offset(620, 300));
      await tester.pumpAndSettle();
      expect(_draft(tester), 'Retained private draft');

      await tester.tap(find.widgetWithText(FilledButton, 'Save note'));
      await _settle(tester);
      expect(
        state.savedNotes.single.passage.canonicalKey,
        _origin.canonicalKey,
      );
      expect(state.savedNotes.single.verse, 1);
      expect(state.savedNotes.single.text, 'Retained private draft');
      expect(find.byTooltip('Close note editor'), findsNothing);

      _expectPassageEnabled(tester, true);
      await tester.tap(find.byTooltip(state.ui('readerOptions')));
      await tester.pumpAndSettle();
      _expectBackupEnabled(tester, true);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('a retained verse draft cannot save or delete another passage', (
    WidgetTester tester,
  ) async {
    final AppState state = await _createReader(tester, ReaderApiFixture());
    await tester.runAsync(() async {
      await state.loadPassage(_other);
      await state.saveVerseNote(1, 'Extended Book 7:1', 'Other saved note');
      await state.loadPassage(_origin);
    });
    expect(_savedText(state, _other), 'Other saved note');
    await _showReader(tester, state);
    await _editNote(tester);

    // Reader controls prevent this navigation. A caller outside the widget
    // tree must still never rebind the editor's draft to the new passage.
    await tester.runAsync(() => state.loadPassage(_other));
    await _settle(tester);
    expect(state.passage, _other);
    expect(state.notes.single.text, 'Other saved note');
    expect(_draft(tester), 'Retained private draft');

    await tester.tap(find.widgetWithText(FilledButton, 'Save note'));
    await _settle(tester);
    await tester.tap(find.byTooltip('Delete note'));
    await _settle(tester);
    expect(_savedText(state, _origin), 'Saved original note');
    expect(_savedText(state, _other), 'Other saved note');
    expect(_draft(tester), 'Retained private draft');
    expect(
      find.text(
        'Return to Genesis 1:1 before changing this retained verse-note draft.',
      ),
      findsOneWidget,
    );

    await tester.runAsync(() => state.loadPassage(_origin));
    await _settle(tester);
    await tester.tap(find.widgetWithText(FilledButton, 'Save note'));
    await _settle(tester);
    expect(_savedText(state, _origin), 'Retained private draft');
    expect(_savedText(state, _other), 'Other saved note');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

Future<AppState> _createReader(
  WidgetTester tester,
  ReaderApiFixture fixture,
) async {
  tester.view.physicalSize = const Size(640, 900);
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
        passage: _origin,
        verse: 1,
        updatedAt: DateTime.utc(2026, 10, 8),
      ),
    );
    await state.initialize();
    await state.saveVerseNote(1, 'Genesis 1:1', 'Saved original note');
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
}

final Finder _noteInput = find.byWidgetPredicate(
  (Widget widget) =>
      widget is TextField && widget.decoration?.hintText == 'Write your note…',
);

Future<void> _editNote(WidgetTester tester) async {
  await tester.tap(find.text('Saved original note'));
  await tester.pumpAndSettle();
  await tester.enterText(_noteInput, 'Retained private draft');
}

String? _draft(WidgetTester tester) =>
    tester.widget<TextField>(_noteInput).controller?.text;

String _savedText(AppState state, Passage passage) => state.savedNotes
    .singleWhere(
      (VerseNote note) => note.passage.canonicalKey == passage.canonicalKey,
    )
    .text;

void _expectPassageEnabled(WidgetTester tester, bool enabled) {
  for (final key in [
    'reader-passage-selector',
    'reader-mobile-passage-selector',
  ]) {
    final field = tester.widget<TextButton>(find.byKey(ValueKey(key)));
    expect(field.onPressed != null, enabled);
  }
  final translation = tester.widget<OutlinedButton>(
    find.byKey(const ValueKey('reader-translation-selector')),
  );
  expect(translation.onPressed != null, enabled);
}

void _expectBackupEnabled(WidgetTester tester, bool enabled) {
  final backup = tester.widget<ListTile>(
    find.widgetWithText(ListTile, 'Backup and restore'),
  );
  expect(backup.onTap != null, enabled);
  expect(
    find.descendant(
      of: find.byType(Drawer),
      matching: find.byType(DropdownButtonFormField<int>),
    ),
    findsNothing,
  );
}

Future<void> _settle(WidgetTester tester) async {
  await tester.runAsync(
    () async => Future<void>.delayed(const Duration(milliseconds: 40)),
  );
  await tester.pumpAndSettle();
}
