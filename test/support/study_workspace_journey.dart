import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:getbible_live/application/app_state.dart';
import 'package:getbible_live/data/database/local_database.dart';
import 'package:getbible_live/domain/models/notebook.dart';
import 'package:getbible_live/domain/models/passage.dart';
import 'package:getbible_live/domain/models/preferences.dart';
import 'package:getbible_live/main.dart';
import 'package:getbible_live/presentation/widgets/dictionary_panel.dart';
import 'package:getbible_live/presentation/widgets/scripture_verse_text.dart';
import 'package:getbible_live/presentation/widgets/study_workspace.dart';
import 'package:getbible_live/presentation/widgets/topics_panel.dart';
import 'package:provider/provider.dart';

import 'study_api_fixture.dart';

/// Exercises public resources and private editing through the production reader.
/// The same journey runs in widget CI and the native Linux runner.
void studyWorkspaceJourney({
  bool useDeviceViewport = false,
  Size viewport = const Size(1250, 900),
  TargetPlatformVariant? platform,
}) {
  testWidgets(
    'Study dictionaries, commentary, topics and local notebooks compose without changing Scripture',
    (tester) async {
      if (!useDeviceViewport) {
        tester.view.physicalSize = viewport;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
      }
      final StudyApiFixture fixture = StudyApiFixture();
      const Passage origin = Passage(
        translation: 'tst',
        book: 1,
        chapter: 1,
        verse: 1,
      );
      final AppState state = (await tester.runAsync(() async {
        final AppState state = AppState.fromDatabase(
          await LocalDatabase.memory(),
          api: fixture.reader.api,
        );
        await state.settings.saveLastReadingPosition(
          LastReadingPosition(
            passage: origin,
            verse: 1,
            updatedAt: DateTime.utc(2026, 10, 8),
          ),
        );
        await state.initialize();
        await state.saveVerseNote(1, 'Genesis 1:1', 'Private canonical note');
        return state;
      }))!;
      addTearDown(state.close);
      final int groupsBefore = state.groups.length;
      final String noteId = state.notes.single.id;
      final String originalText = state.current!.verses.first.text;
      await tester.pumpWidget(
        ChangeNotifierProvider.value(value: state, child: const GetBibleApp()),
      );
      await tester.pumpAndSettle();

      Future<void> settle() async {
        // SQLite and source fixtures complete on the real event loop. Keep it
        // and Flutter frames moving until the actual operations are idle;
        // simulator scheduling must not depend on a fixed storage delay.
        final deadline = Stopwatch()..start();
        do {
          await tester.runAsync(
            () async => Future<void>.delayed(const Duration(milliseconds: 1)),
          );
          await tester.pump(const Duration(milliseconds: 20));
          if (deadline.elapsed > const Duration(seconds: 10)) {
            throw TimeoutException('Study operations did not become idle.');
          }
        } while (state.loading ||
            state.study.dictionary.isLoading ||
            state.study.dictionary.isDiscovering ||
            state.study.commentary.isLoading ||
            state.study.topics.loading ||
            state.study.topics.loadingTopic ||
            state.study.topics.loadingNames ||
            state.study.topics.restoringPreferences ||
            state.study.topics.savingPreferences.isNotEmpty ||
            state.study.topics.copying ||
            state.study.notebooks.isLoading ||
            state.study.notebooks.isSaving);
        await tester.pumpAndSettle();
      }

      Future<void> choose(StudyTab tab) async {
        await tester.tap(find.byType(DropdownButtonFormField<StudyTab>));
        await tester.pumpAndSettle();
        await tester.tap(find.text(tab.label).last);
        await settle();
      }

      Future<void> openWord() async {
        final Finder source = find.descendant(
          of: find.byType(ScriptureVerseText).first,
          matching: find.byType(SelectableText),
        );
        await tester.tapAt(tester.getTopLeft(source) + const Offset(24, 15));
        await tester.pump(const Duration(milliseconds: 400));
        await settle();
        expect(find.byType(StudyWorkspace), findsOneWidget);
      }

      await openWord();
      expect(find.text('Source language: en'), findsOneWidget);
      // Use the exact published ID to distinguish repeated definitions. On
      // short native viewports the list tile is not built until scrolled to.
      final Finder definition = find.widgetWithText(ListTile, 'kadesh');
      await tester.scrollUntilVisible(
        definition,
        150,
        scrollable: find
            .descendant(
              of: find.byType(DictionaryPanel),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.pumpAndSettle();
      expect(definition.hitTestable(), findsOneWidget);
      await tester.tap(definition);
      await settle();
      expect(find.textContaining('Preserved paragraphs.'), findsOneWidget);
      expect(state.current!.verses.first.text, originalText);

      await choose(StudyTab.commentary);
      await tester.tap(find.text('Whole chapter'));
      await settle();
      expect(find.textContaining('First ranged comment.'), findsOneWidget);
      final introduction = find.widgetWithText(
        ExpansionTile,
        'Chapter introduction',
      );
      await tester.ensureVisible(introduction);
      await tester.pumpAndSettle();
      expect(introduction.hitTestable(), findsOneWidget);
      await tester.tap(introduction);
      await settle();
      expect(find.text('Chapter introduction.'), findsOneWidget);
      expect(
        fixture.requests.any((uri) => uri.path == '/v1/fixture/1/1.json'),
        isTrue,
      );
      expect(
        fixture.requests.any((uri) => uri.path == '/v1/fixture/1/1/1.json'),
        isFalse,
      );

      await choose(StudyTab.topics);
      final topicScroll = find
          .descendant(
            of: find.byType(TopicsPanel),
            matching: find.byType(Scrollable),
          )
          .first;
      final follow = find.descendant(
        of: find.widgetWithText(Card, 'Authority of the Bible'),
        matching: find.widgetWithText(TextButton, 'Follow'),
      );
      await tester.scrollUntilVisible(follow, 150, scrollable: topicScroll);
      await tester.pumpAndSettle();
      expect(follow.hitTestable(), findsOneWidget);
      await tester.tap(follow);
      await settle();
      expect(state.study.topics.followed, contains('authority-of-the-bible'));
      expect(state.groups.length, groupsBefore);
      expect(state.notes.single.id, noteId);
      final topic = find.widgetWithText(ListTile, 'Authority of the Bible');
      await tester.ensureVisible(topic);
      await tester.pumpAndSettle();
      expect(topic.hitTestable(), findsOneWidget);
      await tester.tap(topic);
      await settle();
      final copy = find.text('Copy to my markings');
      await tester.scrollUntilVisible(copy, 150, scrollable: topicScroll);
      await tester.pumpAndSettle();
      expect(copy.hitTestable(), findsOneWidget);
      await tester.tap(copy);
      await settle();
      expect(find.text('Copy public topic to my markings?'), findsOneWidget);
      await tester.tap(find.text('Copy markings'));
      await settle();
      expect(state.groups.length, groupsBefore + 1);
      expect(state.savedMarkings.length, 3);
      expect(state.notes.single.id, noteId);

      await choose(StudyTab.notes);
      final Finder notebookScroll = find
          .descendant(
            of: find.byKey(const ValueKey<String>('notes-panel-list')),
            matching: find.byType(Scrollable),
          )
          .first;
      final createNotebook = find.text('New notebook');
      await tester.scrollUntilVisible(
        createNotebook,
        150,
        scrollable: notebookScroll,
      );
      await tester.pumpAndSettle();
      expect(createNotebook.hitTestable(), findsOneWidget);
      await tester.tap(createNotebook);
      await settle();
      final Finder title = find.widgetWithText(TextField, 'Notebook title');
      await tester.scrollUntilVisible(title, 150, scrollable: notebookScroll);
      await tester.pumpAndSettle();
      await tester.enterText(title, 'Sunday sermon');
      final Finder block = find.widgetWithText(
        TextFormField,
        'Study or sermon notes',
      );
      await tester.scrollUntilVisible(block, 250, scrollable: notebookScroll);
      await tester.pumpAndSettle();
      await tester.enterText(block, 'Private draft survives closing Study.');
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await settle();
      expect(
        state.study.notebooks.notebook?.blocks.single.text,
        'Private draft survives closing Study.',
      );
      final bool? flushed = await tester.runAsync<bool>(
        state.study.notebooks.flush,
      );
      expect(flushed, isTrue, reason: state.study.notebooks.error?.toString());
      final String notebookId = state.study.notebooks.selectedId!;
      await tester.tap(find.byTooltip('Close Study tools'));
      await settle();
      expect(state.passage, origin);
      expect(find.byType(StudyWorkspace), findsNothing);
      fixture.offline = true;
      await openWord();
      await choose(StudyTab.notes);
      // On a phone the reopened list starts above the editor, outside its
      // lazy viewport. Scroll the actual notes panel to the saved block.
      await tester.scrollUntilVisible(block, 250, scrollable: notebookScroll);
      await tester.pumpAndSettle();
      expect(block.hitTestable(), findsOneWidget);
      expect(
        find.text('Private draft survives closing Study.'),
        findsOneWidget,
      );
      final Notebook? saved = await tester.runAsync<Notebook?>(
        () => state.study.notebooks.repository.notebook(notebookId),
      );
      expect(saved?.title, 'Sunday sermon');
      expect(
        saved?.blocks.single.text,
        'Private draft survives closing Study.',
      );
      expect(state.notes.single.id, noteId);
      expect(state.current!.verses.first.text, originalText);
      expect(
        fixture.requests.any(
          (uri) =>
              uri.path == '/v1/easton.json' ||
              uri.path.endsWith('/all.json') ||
              uri.path.endsWith('/catalog.json'),
        ),
        isFalse,
      );
      await tester.tap(find.byTooltip('Close Study tools'));
      await settle();
      expect(tester.takeException(), isNull);
    },
    variant: platform ?? const DefaultTestVariant(),
  );
}
