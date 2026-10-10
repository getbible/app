import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:getbible/application/app_state.dart';
import 'package:getbible/data/database/local_database.dart';
import 'package:getbible/domain/models/annotations.dart';
import 'package:getbible/domain/models/passage.dart';
import 'package:getbible/domain/models/service_envelopes.dart';
import 'package:getbible/domain/models/unified_bookmarks.dart';
import 'package:getbible/presentation/widgets/bookmark_assignment_menu.dart';

import 'support/reader_api_fixture.dart';

void main() {
  testWidgets(
    'a short bookmark menu shrinks and expands only when the topic picker opens',
    (tester) async {
      final state = await _menuState(tester);
      addTearDown(state.close);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  minWidth: 360,
                  maxWidth: 360,
                  maxHeight: 620,
                ),
                child: Material(child: _menu(state)),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final collapsed = tester
          .getSize(find.byType(BookmarkAssignmentMenu))
          .height;
      expect(collapsed, lessThan(360));
      expect(find.text('Topic 1').hitTestable(), findsOneWidget);
      expect(find.text('Topic 2').hitTestable(), findsOneWidget);
      expect(
        find.text('Create or manage topics').hitTestable(),
        findsOneWidget,
      );
      await tester.tap(find.text('Add another topic'));
      await tester.pumpAndSettle();
      final expanded = tester
          .getSize(find.byType(BookmarkAssignmentMenu))
          .height;
      expect(expanded, greaterThan(collapsed + 150));
      expect(expanded, lessThanOrEqualTo(620));
      expect(
        find.text('Create or manage topics').hitTestable(),
        findsOneWidget,
      );
      await tester.tap(find.text('Add another topic'));
      await tester.pumpAndSettle();
      expect(
        tester.getSize(find.byType(BookmarkAssignmentMenu)).height,
        collapsed,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('long memberships remain bounded with a keyboard and 200% text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 740);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final state = await _menuState(tester, membershipCount: 12);
    addTearDown(state.close);
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: TextScaler.linear(2),
              viewInsets: const EdgeInsets.only(bottom: 360),
            ),
            child: Scaffold(
              body: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(
                    minWidth: 336,
                    maxWidth: 336,
                    maxHeight: 300,
                  ),
                  child: Material(child: _menu(state)),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      tester.getSize(find.byType(BookmarkAssignmentMenu)).height,
      lessThanOrEqualTo(300),
    );
    await tester.ensureVisible(find.text('Add another topic'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add another topic'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byType(TextField));
    await tester.enterText(find.byType(TextField), 'Topic 29');
    await tester.pumpAndSettle();
    final matchingTopic = find.widgetWithText(ListTile, 'Topic 29');
    await tester.ensureVisible(matchingTopic);
    expect(matchingTopic.hitTestable(), findsOneWidget);
    await tester.ensureVisible(find.text('Create or manage topics'));
    expect(find.text('Create or manage topics').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'contextual bookmark menu exposes independent origins at 200% text and restores focus',
    (tester) async {
      tester.view.physicalSize = const Size(360, 740);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      const passage = Passage(translation: 'tst', book: 1, chapter: 1);
      final state = (await tester.runAsync(() async {
        final db = await LocalDatabase.memory();
        final now = DateTime.utc(2025);
        await db.replaceReaderData(
          groups: [
            MarkingGroup(
              id: 'local',
              name: 'Faith',
              color: '#123456',
              updatedAt: now,
              source: const SharedBookmarkSource(topicId: 'faith'),
            ),
          ],
          markings: [
            for (final global in [false, true])
              Marking(
                id: global ? 'global' : 'personal',
                passage: passage,
                verse: 1,
                start: null,
                end: null,
                quote: 'Original quotation',
                reference: 'Genesis 1:1',
                groupId: 'local',
                createdAt: now,
                source: global
                    ? const SharedBookmarkSource(topicId: 'faith')
                    : null,
              ),
          ],
          notes: [],
        );
        final state = AppState.fromDatabase(db, api: ReaderApiFixture().api);
        state.passage = passage;
        await state.refreshAnnotations();
        state.bookmarks.catalogue = [
          BookmarkTopicMetadata(
            summary: const PublicTopicSummary(
              id: 'faith',
              name: 'Faith',
              color: '#123456',
              aliases: [],
              isDefault: true,
              verseCount: 1,
              source: {},
            ),
          ),
        ];
        return state;
      }))!;
      addTearDown(state.close);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: TextScaler.linear(2)),
                child: BookmarkAssignmentMenu(
                  state: state,
                  passage: passage,
                  verse: 1,
                  quote: 'Original quotation',
                  reference: 'Genesis 1:1',
                  onAdd: (_) async {},
                  onOpenTopic: (_) {},
                  onClose: () {},
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.bySemanticsLabel('Global and personal bookmark'),
        findsOneWidget,
      );
      expect(find.byType(TextField), findsNothing);
      await tester.tap(find.text('Add another topic'));
      await tester.pumpAndSettle();
      final personal = find.byTooltip('Remove personal bookmark');
      await tester.ensureVisible(personal);
      await tester.tap(personal);
      await tester.runAsync(() async {
        for (var i = 0; i < 100 && state.savedMarkings.length != 1; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        expect(state.savedMarkings.single.isSharedBookmark, isTrue);
        expect((await state.database.getMarkings()).single.id, 'global');
      });
      await tester.pumpAndSettle();
      expect(find.byTooltip('Remove personal bookmark'), findsNothing);
      expect(find.bySemanticsLabel('Global bookmark'), findsOneWidget);
      expect(
        tester.widget<TextField>(find.byType(TextField)).focusNode?.hasFocus,
        isTrue,
      );
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(find.byType(TextField));
      await tester.enterText(find.byType(TextField), 'missing');
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('No matching topics.'));
      expect(find.text('No matching topics.'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}

BookmarkAssignmentMenu _menu(AppState state) => BookmarkAssignmentMenu(
  state: state,
  passage: state.passage,
  verse: 1,
  quote: 'Original quotation',
  reference: 'Genesis 1:1',
  onAdd: (_) async {},
  onOpenTopic: (_) {},
  onClose: () {},
);

Future<AppState> _menuState(
  WidgetTester tester, {
  int membershipCount = 2,
}) async => (await tester.runAsync(() async {
  final db = await LocalDatabase.memory();
  final now = DateTime.utc(2026);
  const passage = Passage(translation: 'tst', book: 1, chapter: 1);
  await db.replaceReaderData(
    groups: [
      for (var id = 1; id <= 30; id++)
        MarkingGroup(
          id: 'topic-$id',
          name: 'Topic $id',
          color: '#123456',
          updatedAt: now,
        ),
    ],
    markings: [
      for (var id = 1; id <= membershipCount; id++)
        Marking(
          id: 'mark-$id',
          passage: passage,
          verse: 1,
          start: null,
          end: null,
          quote: 'Original quotation',
          reference: 'Genesis 1:1',
          groupId: 'topic-$id',
          createdAt: now,
        ),
    ],
    notes: [],
  );
  final state = AppState.fromDatabase(db, api: ReaderApiFixture().api)
    ..passage = passage;
  await state.refreshAnnotations();
  state.bookmarks.catalogue = [
    BookmarkTopicMetadata(
      summary: const PublicTopicSummary(
        id: 'fixture',
        name: 'Fixture',
        color: '#123456',
        aliases: [],
        isDefault: true,
        verseCount: 1,
        source: {},
      ),
    ),
  ];
  return state;
}))!;
