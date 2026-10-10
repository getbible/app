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
