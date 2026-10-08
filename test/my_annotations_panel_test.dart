import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:getbible_live/application/app_state.dart';
import 'package:getbible_live/data/database/local_database.dart';
import 'package:getbible_live/domain/models/annotations.dart';
import 'package:getbible_live/domain/models/passage.dart';
import 'package:getbible_live/domain/models/preferences.dart';
import 'package:getbible_live/presentation/widgets/my_annotations_panel.dart';

import 'support/reader_api_fixture.dart';

const String _longName = 'An intentionally descriptive personal study group';
const String _groupId = 'large-text-private-group';
const Passage _passage = Passage(translation: 'tst', book: 1, chapter: 1);

void main() {
  testWidgets(
    'group search, selected markings and confirmed removal fit a short RTL surface at 200 percent text',
    (WidgetTester tester) async {
      _setViewport(tester);
      final AppState state = await _state(tester);
      addTearDown(state.close);
      final List<Passage> opened = <Passage>[];
      await _pump(tester, state, opened.add);
      await tester.enterText(find.byType(TextField), 'intentionally');
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text(_longName), findsOneWidget);
      await tester.ensureVisible(find.text(_longName));
      await tester.tap(find.text(_longName));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(state.preferences.activeMarkingGroupId, _groupId);
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -620));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(opened.single, _passage.copyWith(verse: 3));
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -48));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete marking'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(state.savedMarkings, hasLength(1));
      await tester.tap(find.text('Delete marking'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
      await tester.pumpAndSettle();
      expect(state.savedMarkings, isEmpty);
      expect(
        state.savedNotes.single.text,
        'This private canonical note survives.',
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'group management scrolls with keyboard insets and preserves an invalid draft for correction',
    (WidgetTester tester) async {
      _setViewport(tester);
      final AppState state = await _state(tester);
      addTearDown(state.close);
      await _pump(tester, state, (_) {});
      await tester.tap(find.text('Manage groups'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final Finder dialog = find.byType(Dialog);
      final Finder name = find.descendant(
        of: dialog,
        matching: find.widgetWithText(TextField, 'Group name'),
      );
      final Finder color = find.descendant(
        of: dialog,
        matching: find.widgetWithText(TextField, 'Color'),
      );
      await tester.ensureVisible(name);
      await tester.enterText(name, 'New private study');
      await tester.ensureVisible(color);
      await tester.enterText(color, 'invalid');
      await tester.ensureVisible(find.text('Add group'));
      await tester.tap(find.text('Add group'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Enter a group name'), findsOneWidget);
      expect(
        (tester.widget<TextField>(name).controller!).text,
        'New private study',
      );
      expect((tester.widget<TextField>(color).controller!).text, 'invalid');
      await tester.ensureVisible(color);
      await tester.enterText(color, '#123456');
      await tester.ensureVisible(find.text('Add group'));
      await tester.tap(find.text('Add group'));
      await tester.pumpAndSettle();
      expect(
        state.groups.where(
          (MarkingGroup group) => group.name == 'New private study',
        ),
        hasLength(1),
      );
      expect(state.savedMarkings, hasLength(1));
      expect(state.savedNotes, hasLength(1));
      await tester.drag(
        find.descendant(of: dialog, matching: find.byType(CustomScrollView)),
        const Offset(0, 800),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Close marking groups'));
      await tester.pumpAndSettle();
      expect(dialog, findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'verse-note navigation remains canonical and readable on a short scaled surface',
    (WidgetTester tester) async {
      _setViewport(tester);
      final AppState state = await _state(tester);
      addTearDown(state.close);
      final List<Passage> opened = <Passage>[];
      await _pump(tester, state, opened.add, showNotes: true);
      expect(tester.takeException(), isNull);
      expect(
        find.text('This private canonical note survives.'),
        findsOneWidget,
      );
      await tester.tap(find.text('Genesis 1:1'));
      await tester.pumpAndSettle();
      expect(opened.single, _passage.copyWith(verse: 1));
      expect(state.savedNotes.single.id, 'kept-verse-note');
      expect(state.savedMarkings, hasLength(1));
    },
  );
}

void _setViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(320, 360);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Future<void> _pump(
  WidgetTester tester,
  AppState state,
  ValueChanged<Passage> onOpen, {
  bool showNotes = false,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      builder: (BuildContext context, Widget? child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: TextScaler.linear(2),
          viewInsets: const EdgeInsets.only(bottom: 120),
        ),
        child: Directionality(textDirection: TextDirection.rtl, child: child!),
      ),
      home: Scaffold(
        body: MyAnnotationsPanel(
          state: state,
          onOpenPassage: onOpen,
          showNotes: showNotes,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<AppState> _state(WidgetTester tester) async =>
    (await tester.runAsync(() async {
      final LocalDatabase database = await LocalDatabase.memory();
      final ReaderApiFixture fixture = ReaderApiFixture();
      final AppState state = AppState.fromDatabase(database, api: fixture.api);
      final DateTime now = DateTime.utc(2026);
      await database.saveGroup(
        MarkingGroup(
          id: _groupId,
          name: _longName,
          color: '#AABBCC',
          updatedAt: now,
        ),
      );
      await database.saveMarking(
        Marking(
          id: 'kept-marking',
          passage: _passage,
          verse: 3,
          start: null,
          end: null,
          quote: 'An original quote with enough words to wrap safely.',
          reference: 'Genesis 1:3',
          groupId: _groupId,
          createdAt: now,
        ),
      );
      await database.saveNote(
        VerseNote(
          id: 'kept-verse-note',
          passage: _passage.copyWith(translation: 'web'),
          verse: 1,
          reference: 'Genesis 1:1',
          text: 'This private canonical note survives.',
          createdAt: now,
          updatedAt: now,
        ),
      );
      await state.settings.saveLastReadingPosition(
        LastReadingPosition(passage: _passage, verse: 1, updatedAt: now),
      );
      await state.initialize();
      return state;
    }))!;
