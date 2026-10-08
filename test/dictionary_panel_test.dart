import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:getbible_live/application/dictionary_controller.dart';
import 'package:getbible_live/domain/models/reference.dart';
import 'package:getbible_live/presentation/widgets/dictionary_panel.dart';

import 'support/dictionary_fixture.dart';

void main() {
  testWidgets(
    'native dictionary lookup, links and shared selected-Bible citation work',
    (WidgetTester tester) async {
      final DictionaryFixture fixture = DictionaryFixture();
      final DictionaryController controller = DictionaryController(
        repository: fixture.repository,
        preferences: MemoryStudyPreferences(),
      );
      addTearDown(() {
        controller.dispose();
        fixture.close();
      });
      ReferenceRequest? preview;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DictionaryPanel(
              controller: controller,
              context: dictionaryContext(strongs: <String>['G3056']),
              onPreviewReference: (ReferenceRequest request) async {
                preview = request;
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Word; speech.\n\nA second paragraph.'), findsOneWidget);
      expect(find.text('Source language: en'), findsOneWidget);
      expect(find.text('G3056--2 · definition 2'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.widgetWithText(ActionChip, 'John 1:1'),
        150,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.widgetWithText(ActionChip, 'John 1:1'));
      await tester.pump();
      expect(preview, isA<StructuredReferenceRequest>());
      expect(preview!.translation, 'kjv');
      expect(preview!.sourceLabel, 'John 1:1');
      final Finder link = find.widgetWithText(ActionChip, 'ῥῆμα');
      await tester.scrollUntilVisible(
        link,
        150,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(link);
      await tester.pumpAndSettle();
      expect(find.text('A saying.'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('Previous dictionary word'),
        -150,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('Previous dictionary word'));
      await tester.pumpAndSettle();
      expect(find.text('Word; speech.\n\nA second paragraph.'), findsOneWidget);
    },
  );

  testWidgets(
    'RTL narrow surface at 200% text keeps native index controls accessible',
    (WidgetTester tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final DictionaryFixture fixture = DictionaryFixture();
      final DictionaryController controller = DictionaryController(
        repository: fixture.repository,
        preferences: MemoryStudyPreferences(),
      );
      addTearDown(() {
        controller.dispose();
        fixture.close();
      });
      await tester.pumpWidget(
        MaterialApp(
          builder: (BuildContext context, Widget? child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(2)),
            child: Directionality(
              textDirection: TextDirection.rtl,
              child: child!,
            ),
          ),
          home: Scaffold(
            body: DictionaryPanel(
              controller: controller,
              context: dictionaryContext(word: 'Kádésh,'),
              onPreviewReference: (_) async {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('A place. <b>Plain text</b>\n\nPreserved paragraphs.'),
        150,
        scrollable: find.byType(Scrollable).first,
      );
      expect(
        find.text('A place. <b>Plain text</b>\n\nPreserved paragraphs.'),
        findsOneWidget,
      );
      expect(find.byType(SelectableText), findsWidgets);
      await tester.scrollUntilVisible(
        find.byType(TextField),
        -100,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.enterText(find.byType(TextField), 'Ka\u0301de\u0301sh');
      await tester.pumpAndSettle();
      expect(controller.matches.length, 2);
      expect(tester.takeException(), isNull);
      final Finder moduleField = find.byType(DropdownButtonFormField<String>);
      await tester.scrollUntilVisible(
        moduleField,
        -150,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(moduleField);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );
}
