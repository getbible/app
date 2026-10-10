import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:getbible/application/notebook_controller.dart';
import 'package:getbible/data/database/local_database.dart';
import 'package:getbible/data/repositories/sql_notebook_repository.dart';
import 'package:getbible/domain/models/notebook.dart';
import 'package:getbible/domain/models/passage.dart';
import 'package:getbible/domain/models/study_context.dart';
import 'package:getbible/presentation/widgets/notes_panel.dart';
import 'package:getbible/services/markdown_service.dart';
import 'package:getbible/services/text_file_service.dart';

void main() {
  test(
    'notebook Markdown preserves private whitespace and attributed Scripture',
    () {
      final DateTime now = DateTime.utc(2026, 1, 1);
      final Notebook notebook = Notebook(
        id: 'study',
        title: 'Study 😃',
        createdAt: now,
        updatedAt: now,
        revision: 1,
        blocks: <NotebookBlock>[
          NotebookBlock(
            id: 'block',
            text: '  Private text\nSecond line  ',
            createdAt: now,
            updatedAt: now,
            reference: NotebookReference(
              passage: const Passage(
                translation: 'fx',
                book: 1,
                chapter: 1,
                verse: 2,
              ),
              label: 'Genesis 1:2',
              quotation: ' Original text 😃\nNext line ',
              direction: 'RTL',
            ),
          ),
        ],
      );
      expect(
        exportNotebookMarkdown(notebook),
        contains('  Private text\nSecond line  '),
      );
      expect(
        exportNotebookMarkdown(notebook),
        contains('>  Original text 😃\n> Next line '),
      );
      expect(exportNotebookMarkdown(notebook), contains('Genesis 1:2 (FX)'));
    },
  );

  testWidgets(
    'notebook export flushes current edits and saves their Markdown through the file boundary',
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
      await controller.createNotebook(title: 'My sermon');
      controller.updateBlockText(
        controller.notebook!.blocks.single.id,
        'Current unflushed text 😃',
      );
      final _Files files = _Files();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: NotesPanel(
              controller: controller,
              context: const StudyContext(
                passage: Passage(translation: 'fx', book: 1, chapter: 1),
                bookName: 'Genesis',
                language: 'en',
              ),
              onPreviewReference: (_) async {},
              onOpenPassage: (_) async {},
              files: files,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Export notebook Markdown'));
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pumpAndSettle();
      expect(find.textContaining('restorable copy'), findsOneWidget);
      expect(controller.hasUndurableDrafts, isFalse);
      await tester.tap(find.text('Save file'));
      await tester.pumpAndSettle();
      expect(files.saved, contains('Current unflushed text 😃'));
      expect(files.filename, 'getbible-notebook.md');
      expect(files.mimeType, 'text/markdown');
      expect(find.text('File saved.'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}

final class _Files implements TextFileService {
  String? saved;
  String? filename;
  String? mimeType;
  @override
  Future<String?> pickText({int maxBytes = maxTextFileBytes}) async => null;
  @override
  Future<TextSaveResult> saveText({
    required String text,
    required String filename,
    required String mimeType,
  }) async {
    saved = text;
    this.filename = filename;
    this.mimeType = mimeType;
    return TextSaveResult.saved;
  }

  @override
  Future<TextShareResult> shareText({
    required String text,
    required String subject,
  }) async => TextShareResult.unsupported;
  @override
  Future<void> copyText(String text) async {}
}
