import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:getbible/application/app_state.dart';
import 'package:getbible/data/database/local_database.dart';
import 'package:getbible/domain/models/annotations.dart';
import 'package:getbible/domain/models/passage.dart';
import 'package:getbible/domain/models/preferences.dart';
import 'package:getbible/presentation/widgets/my_annotations_panel.dart';

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
      await tester.scrollUntilVisible(
        find.text(_longName),
        80,
        scrollable: _panelScroll(),
      );
      expect(find.text(_longName), findsOneWidget);
      await tester.ensureVisible(find.text(_longName));
      await tester.pumpAndSettle();
      expect(find.text(_longName).hitTestable(), findsOneWidget);
      await tester.tap(find.text(_longName));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(state.preferences.activeMarkingGroupId, _groupId);
      await tester.scrollUntilVisible(
        find.text('Genesis 1:3 · TST'),
        80,
        scrollable: _panelScroll(),
      );
      await tester.pumpAndSettle();
      expect(find.text('Genesis 1:3 · TST').hitTestable(), findsOneWidget);
      await tester.tap(find.text('Genesis 1:3 · TST'));
      await tester.pumpAndSettle();
      expect(opened.single, _passage.copyWith(verse: 3));
      await tester.ensureVisible(find.byTooltip('Remove personal bookmark'));
      await tester.pumpAndSettle();
      expect(
        find.byTooltip('Remove personal bookmark').hitTestable(),
        findsOneWidget,
      );
      await tester.tap(find.byTooltip('Remove personal bookmark'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(state.savedMarkings, hasLength(1));
      await tester.tap(find.byTooltip('Remove personal bookmark'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Remove'));
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
      await tester.ensureVisible(find.text('Manage groups'));
      await tester.pumpAndSettle();
      expect(find.text('Manage groups').hitTestable(), findsOneWidget);
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
    'global-only rows use discovered extended book names without rewriting saved text',
    (tester) async {
      final state = await _state(tester);
      addTearDown(state.close);
      const storedReference = 'Book 1000000042 7:1';
      await tester.runAsync(() async {
        await state.database.saveMarking(
          Marking(
            id: 'global-reference',
            passage: const Passage(
              translation: 'tst',
              book: ReaderApiFixture.extendedBook,
              chapter: 7,
            ),
            verse: 1,
            start: null,
            end: null,
            quote: 'Preserved imported quotation',
            reference: storedReference,
            groupId: _groupId,
            createdAt: DateTime.utc(2026),
            source: const SharedBookmarkSource(topicId: 'faith'),
          ),
        );
        await state.refreshAnnotations();
      });
      await _pump(tester, state, (_) {}, initialGroupId: _groupId);
      await tester.scrollUntilVisible(
        find.text('Extended Book 7:1 · TST'),
        100,
        scrollable: _panelScroll(),
      );
      await tester.pumpAndSettle();
      expect(find.text('Extended Book 7:1 · TST'), findsOneWidget);
      final saved = state.savedMarkings.singleWhere(
        (mark) => mark.id == 'global-reference',
      );
      expect(saved.reference, storedReference);
      expect(saved.quote, 'Preserved imported quotation');
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

// Scripture is a native selectable document and has its own Scrollable. The
// gesture must target the outer topic list, not those nested text viewports.
Finder _panelScroll() => find
    .descendant(
      of: find
          .descendant(
            of: find.byType(MyAnnotationsPanel),
            matching: find.byType(CustomScrollView),
          )
          .first,
      matching: find.byType(Scrollable),
    )
    .first;

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
  String? initialGroupId,
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
          initialGroupId: initialGroupId,
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
