import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:getbible/application/app_state.dart';
import 'package:getbible/application/reference_preview_controller.dart';
import 'package:getbible/data/database/local_database.dart';
import 'package:getbible/domain/models/notebook.dart';
import 'package:getbible/domain/models/passage.dart';
import 'package:getbible/presentation/widgets/reference_preview.dart';
import 'support/reader_api_fixture.dart';

void main() {
  testWidgets('stored citation preview identifies its own Bible', (
    tester,
  ) async {
    final fixture = ReaderApiFixture();
    final state = AppState.fromDatabase(
      await LocalDatabase.memory(),
      api: fixture.api,
    );
    final controller = ReferencePreviewController(
      lookup: state.referenceLookup,
    );
    addTearDown(() async {
      controller.dispose();
      await state.close();
    });
    final reference = NotebookReference(
      passage: const Passage(translation: 'kjv', book: 1, chapter: 1, verse: 1),
      label: 'Genesis1:1',
    );
    await tester.runAsync(() => controller.open(reference.previewRequest));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ReferencePreview(
            controller: controller,
            selectedTranslation: 'tst',
            translationName: 'Other reader Bible',
            onOpenInReader: (_) async {},
            onClose: () {},
          ),
        ),
      ),
    );
    expect(find.text('Other reader Bible'), findsNothing);
    expect(find.text('KJV'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'Genesis 1:1');
    await tester.tap(find.text('Preview'));
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 30));
    });
    await tester.pumpAndSettle();
    expect(controller.request!.translation, 'kjv');
    expect(find.text('Other reader Bible'), findsNothing);
  });
}
