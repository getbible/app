import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:getbible/application/notebook_controller.dart';
import 'package:getbible/data/database/local_database.dart';
import 'package:getbible/data/repositories/sql_notebook_repository.dart';
import 'package:getbible/domain/models/bible.dart';
import 'package:getbible/domain/models/notebook.dart';
import 'package:getbible/domain/models/passage.dart';
import 'package:getbible/domain/models/reference.dart';
import 'package:getbible/domain/models/study_context.dart';
import 'package:getbible/presentation/widgets/notes_panel.dart';

void main() {
  testWidgets(
    'Unicode title edits match the accepted private document and overflowing input is visibly rejected',
    (WidgetTester tester) async {
      final LocalDatabase database = await LocalDatabase.memory();
      final NotebookController controller = NotebookController(
        SqlNotebookRepository(database),
        autosaveDelay: const Duration(hours: 1),
      );
      addTearDown(() async {
        await controller.flush();
        controller.dispose();
        await database.close();
      });
      await controller.createNotebook(title: 'Saved title');
      const StudyContext source = StudyContext(
        passage: Passage(translation: 'fx', book: 1, chapter: 1),
        bookName: 'Genesis',
        language: 'en',
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: NotesPanel(
              controller: controller,
              context: source,
              onPreviewReference: (_) async {},
              onOpenPassage: (_) async {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final Finder titleField = find.widgetWithText(
        TextFormField,
        'Notebook title',
      );
      await tester.ensureVisible(titleField);
      await tester.pumpAndSettle();
      await tester.enterText(
        titleField,
        List<String>.filled(110, 'e\u0301').join(),
      );
      await tester.pumpAndSettle();
      final EditableText editor = tester.widget<EditableText>(
        find.descendant(of: titleField, matching: find.byType(EditableText)),
      );
      expect(editor.controller.text, 'Saved title');
      expect(editor.controller.text, controller.notebook!.title);
      expect(controller.inputLimitMessage, contains('Shorten the text'));
      expect(find.text(controller.inputLimitMessage!), findsOneWidget);
      final String accepted = List<String>.filled(100, 'e\u0301').join();
      await tester.enterText(titleField, accepted);
      await tester.pumpAndSettle();
      expect(editor.controller.text, accepted);
      expect(controller.notebook!.title, accepted);
      expect(controller.isDirty, isTrue);
      expect(controller.inputLimitMessage, isNull);
      await tester.runAsync(() => controller.flush());
      expect(
        (await database.getNotebook(controller.selectedId!))!.title,
        accepted,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'compact RTL Notes supports local editing, keyboard save, reference preview and exact quotation insertion at 200%',
    (WidgetTester tester) async {
      tester.view.physicalSize = const Size(320, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final LocalDatabase database = await LocalDatabase.memory();
      final NotebookController controller = NotebookController(
        SqlNotebookRepository(database),
        autosaveDelay: const Duration(hours: 1),
      );
      addTearDown(() async {
        await controller.flush();
        controller.dispose();
        await database.close();
      });
      await controller.createNotebook(title: 'دراسة شخصية');
      final List<ReferenceRequest> previews = <ReferenceRequest>[];
      final List<Passage> opens = <Passage>[];
      const StudyContext source = StudyContext(
        passage: Passage(translation: 'fx', book: 1, chapter: 1, verse: 3),
        bookName: 'تكوين',
        language: 'ar',
        direction: 'RTL',
        verse: Verse(
          chapter: 1,
          verse: 3,
          text: 'في البدء 😀 كان الكلمة',
          name: 'تكوين 1:3',
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(
              size: Size(320, 1200),
              textScaler: TextScaler.linear(2),
            ),
            child: Directionality(
              textDirection: TextDirection.rtl,
              child: Scaffold(
                body: SizedBox(
                  width: 320,
                  child: NotesPanel(
                    controller: controller,
                    context: source,
                    onPreviewReference: (ReferenceRequest request) async {
                      previews.add(request);
                    },
                    onOpenPassage: (Passage passage) async {
                      opens.add(passage);
                    },
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final Finder textField = find.widgetWithText(
        TextFormField,
        'Study or sermon notes',
      );
      await tester.scrollUntilVisible(
        textField,
        300,
        scrollable: find
            .descendant(
              of: find.byKey(const ValueKey<String>('notes-panel-list')),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        textField,
        'Private sermon thoughts\nRemain local 😃',
      );
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.runAsync(() => controller.flush());
      await tester.pumpAndSettle();
      expect(
        (await database.getNotebook(
          controller.selectedId!,
        ))!.blocks.single.text,
        'Private sermon thoughts\nRemain local 😃',
      );
      expect(previews, isEmpty);
      final Finder insert = find.text('Insert current Scripture');
      await tester.scrollUntilVisible(
        insert,
        300,
        scrollable: find
            .descendant(
              of: find.byKey(const ValueKey<String>('notes-panel-list')),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.pumpAndSettle();
      await tester.tap(insert);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(find.text('Open reference preview'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Open reference preview'));
      await tester.pumpAndSettle();
      expect(previews.single, isA<StructuredReferenceRequest>());
      expect(previews.single.translation, 'fx');
      expect(previews.single.translationDirection, 'RTL');
      await tester.ensureVisible(find.widgetWithText(FilledButton, 'Insert'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Insert'));
      await tester.pumpAndSettle();
      final NotebookReference reference =
          controller.notebook!.blocks.last.reference!;
      expect(reference.quotation, source.verse!.text);
      expect(reference.direction, 'RTL');
      expect(reference.passage.verse, 3);
      await tester.scrollUntilVisible(
        find.text('Open in reader'),
        300,
        scrollable: find
            .descendant(
              of: find.byKey(const ValueKey<String>('notes-panel-list')),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Open in reader'));
      await tester.runAsync(() => controller.flush());
      await tester.pumpAndSettle();
      expect(opens.single, reference.passage);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() => controller.flush());
    },
  );

  testWidgets(
    'note blocks reorder and delete after confirmation without converting canonical verse notes',
    (WidgetTester tester) async {
      tester.view.physicalSize = const Size(800, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final LocalDatabase database = await LocalDatabase.memory();
      final NotebookController controller = NotebookController(
        SqlNotebookRepository(database),
        autosaveDelay: const Duration(hours: 1),
      );
      addTearDown(() async {
        await controller.flush();
        controller.dispose();
        await database.close();
      });
      await controller.createNotebook();
      controller.updateBlockText(
        controller.notebook!.blocks.single.id,
        'First block',
      );
      controller.addTextBlock();
      controller.updateBlockText(
        controller.notebook!.blocks.last.id,
        'Second block',
      );
      await controller.flush();
      const StudyContext source = StudyContext(
        passage: Passage(translation: 'fx', book: 1, chapter: 1),
        bookName: 'Genesis',
        language: 'en',
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: NotesPanel(
              controller: controller,
              context: source,
              onPreviewReference: (_) async {},
              onOpenPassage: (_) async {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final Finder moveUp = find.byTooltip('Move block up').last;
      await tester.ensureVisible(moveUp);
      await tester.pumpAndSettle();
      await tester.tap(moveUp);
      await tester.pumpAndSettle();
      expect(controller.notebook!.blocks.first.text, 'Second block');
      final Finder delete = find.byTooltip('Delete note block').first;
      await tester.ensureVisible(delete);
      await tester.pumpAndSettle();
      await tester.tap(delete);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
      await tester.pumpAndSettle();
      expect(controller.notebook!.blocks.single.text, 'First block');
      await tester.runAsync(() => controller.flush());
      expect(await database.getNotes(), isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
