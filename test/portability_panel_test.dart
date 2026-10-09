import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:getbible_live/application/portability_controller.dart';
import 'package:getbible_live/domain/models/annotations.dart';
import 'package:getbible_live/domain/models/backup.dart';
import 'package:getbible_live/domain/models/private_backup.dart';
import 'package:getbible_live/domain/repositories/private_data_repository.dart';
import 'package:getbible_live/presentation/widgets/portability_panel.dart';
import 'package:getbible_live/services/text_file_service.dart';

void main() {
  testWidgets(
    'file import previews validated data and only mutates after confirmation',
    (WidgetTester tester) async {
      final FakeRepository repository = FakeRepository();
      final PortabilityController controller = PortabilityController(
        repository: repository,
      );
      addTearDown(controller.dispose);
      final FakeFiles files = FakeFiles()
        ..selected = encodePrivateBackup(repository.backup);
      await tester.pumpWidget(_app(controller, files));
      await tester.runAsync(() async {
        await tester.tap(find.text('Choose backup file'));
        // The controller validates JSON in an isolate.
        while (controller.busy || controller.preparedImport == null) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      });
      await tester.pumpAndSettle();
      expect(find.text('Complete private backup preview'), findsOneWidget);
      expect(repository.imports, 0);
      await tester.scrollUntilVisible(find.text('Confirm import'), 200);
      await tester.tap(find.text('Confirm import'));
      await tester.pumpAndSettle();
      expect(repository.imports, 1);
      expect(find.textContaining('Import complete:'), findsOneWidget);
    },
  );

  testWidgets(
    'malformed and cancelled file selections do not import anything',
    (WidgetTester tester) async {
      final FakeRepository repository = FakeRepository();
      final PortabilityController controller = PortabilityController(
        repository: repository,
      );
      addTearDown(controller.dispose);
      final FakeFiles files = FakeFiles();
      await tester.pumpWidget(_app(controller, files));
      await tester.tap(find.text('Choose backup file'));
      await tester.pumpAndSettle();
      expect(find.text('File selection cancelled.'), findsOneWidget);
      files.selected = '{"format":"future","version":999}';
      await tester.runAsync(() async {
        await tester.tap(find.text('Choose backup file'));
        while (controller.busy || controller.error == null) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      });
      await tester.pumpAndSettle();
      expect(
        find.text('This complete backup format is not supported.'),
        findsOneWidget,
      );
      expect(find.text('Confirm import'), findsNothing);
      expect(repository.imports, 0);
    },
  );

  testWidgets('complete and website exports produce distinct reusable files', (
    WidgetTester tester,
  ) async {
    final FakeRepository repository = FakeRepository();
    final PortabilityController controller = PortabilityController(
      repository: repository,
    );
    addTearDown(controller.dispose);
    final FakeFiles files = FakeFiles();
    await tester.pumpWidget(_app(controller, files));
    await tester.runAsync(() async {
      await tester.tap(find.text('Prepare complete backup'));
      while (controller.busy) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save file'));
    await tester.pumpAndSettle();
    expect(
      (jsonDecode(files.saved!) as Map<String, dynamic>)['format'],
      privateBackupFormat,
    );
    expect(files.filename, startsWith('getbible-private-'));
    expect(find.text('File saved.'), findsOneWidget);
    await tester.runAsync(() async {
      await tester.tap(find.text('Prepare website backup'));
      while (controller.busy) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save file'));
    await tester.pumpAndSettle();
    expect(
      (jsonDecode(files.saved!) as Map<String, dynamic>).containsKey('format'),
      isFalse,
    );
    expect(files.filename, startsWith('getbible-website-'));
  });
}

Widget _app(PortabilityController controller, FakeFiles files) => MaterialApp(
  home: Scaffold(
    body: PortabilityPanel(controller: controller, files: files),
  ),
);

class FakeRepository implements PrivateDataRepository {
  int imports = 0;
  final PrivateBackup backup = PrivateBackup(
    reader: BackupData(
      version: 2,
      exportedAt: DateTime.utc(2026),
      groups: const <MarkingGroup>[],
      markings: const <Marking>[],
      notes: const <VerseNote>[],
    ),
  );
  @override
  Future<PrivateBackup> snapshot() async => backup;
  @override
  Future<PrivateImportResult> importBackup(PrivateBackup backup) async {
    imports++;
    return const PrivateImportResult(
      groupsAdded: 0,
      markingsAdded: 0,
      notesChanged: 0,
      notebooksAdded: 0,
      draftsAdded: 0,
      notebookConflicts: 0,
      settingsRestored: 0,
    );
  }
}

class FakeFiles implements TextFileService {
  String? selected;
  String? saved;
  String? filename;
  @override
  Future<void> copyText(String text) async {}
  @override
  Future<String?> pickText({int maxBytes = maxTextFileBytes}) async => selected;
  @override
  Future<TextSaveResult> saveText({
    required String text,
    required String filename,
    required String mimeType,
  }) async {
    saved = text;
    this.filename = filename;
    return TextSaveResult.saved;
  }

  @override
  Future<TextShareResult> shareText({
    required String text,
    required String subject,
  }) async => TextShareResult.unsupported;
}
