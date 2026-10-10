import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:getbible/application/dictionary_controller.dart';
import 'package:getbible/domain/models/reference.dart';
import 'package:getbible/presentation/widgets/dictionary_panel.dart';

import 'support/dictionary_fixture.dart';

void main() {
  for (final scale in [1.0, 2.0]) {
    testWidgets(
      'selected dictionary name is fully visible at ${scale * 100}% text',
      (tester) async {
        tester.view.physicalSize = Size(scale == 1 ? 840 : 320, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final fixture = DictionaryFixture();
        final controller = DictionaryController(
          repository: fixture.repository,
          preferences: MemoryStudyPreferences(),
        );
        addTearDown(() {
          controller.dispose();
          fixture.close();
        });
        await tester.pumpWidget(
          MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(scale)),
              child: Directionality(
                textDirection: scale == 1
                    ? TextDirection.ltr
                    : TextDirection.rtl,
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
        final field = find.byKey(const ValueKey('dictionary-resource-choice'));
        final module = controller.selectedModule!;
        final name = '${module.name} (${module.language})';
        final paragraph = tester.renderObject<RenderParagraph>(
          find.descendant(of: field, matching: find.text(name)),
        );
        // Widget existence alone misses a dense dropdown's internal text clip.
        // Compare its allocated height to the complete, naturally wrapped text.
        final text = TextPainter(
          text: paragraph.text,
          textDirection: paragraph.textDirection,
          textScaler: paragraph.textScaler,
        )..layout(maxWidth: paragraph.size.width);
        addTearDown(text.dispose);
        expect(paragraph.size.height, greaterThanOrEqualTo(text.height - 0.01));
        if (scale == 2) {
          expect(text.computeLineMetrics().length, greaterThan(1));
        }
        final fieldBounds = tester.getRect(field);
        final origin = paragraph.localToGlobal(Offset.zero);
        // Selection boxes for trailing wrap spaces may extend beyond a line;
        // check the actual visible glyphs rather than those invisible spaces.
        final boxes = [
          for (var offset = 0; offset < name.length; offset++)
            if (name[offset].trim().isNotEmpty)
              ...paragraph.getBoxesForSelection(
                TextSelection(baseOffset: offset, extentOffset: offset + 1),
              ),
        ];
        expect(boxes, isNotEmpty);
        for (final box in boxes) {
          final bounds = box.toRect().shift(origin);
          expect(
            fieldBounds.contains(bounds.topLeft),
            isTrue,
            reason: '$bounds should be within $fieldBounds',
          );
          expect(
            fieldBounds.contains(bounds.bottomRight),
            isTrue,
            reason: '$bounds should be within $fieldBounds',
          );
        }
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'word lookup shows every definition and actionable lexical chips',
    (tester) async {
      final fixture = DictionaryFixture();
      final controller = DictionaryController(
        repository: fixture.repository,
        preferences: MemoryStudyPreferences(),
      );
      addTearDown(() {
        controller.dispose();
        fixture.close();
      });
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DictionaryPanel(
              controller: controller,
              context: dictionaryContext(strongs: ['G3056', 'G4487']),
              onPreviewReference: (_) async {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Browse all dictionaries'), findsNothing);
      expect(find.text('Look up'), findsOneWidget);
      final chooser = tester.widget<DropdownButton<String>>(
        find.descendant(
          of: find.byKey(const ValueKey('dictionary-resource-choice')),
          matching: find.byType(DropdownButton<String>),
        ),
      );
      expect(
        chooser.items!.map((item) => item.value),
        isNot(contains('oddgreek')),
      );
      await tester.scrollUntilVisible(
        find.byKey(
          const ValueKey('dictionary-definition-strongsgreek/G3056--2'),
        ),
        150,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('A distinct definition.'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.widgetWithText(ActionChip, 'G4487'),
        -150,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ActionChip, 'G4487'));
      await tester.pumpAndSettle();
      expect(controller.query, 'G4487');
      expect(controller.definitions.single.id, 'G4487');
      expect(controller.choices.map((module) => module.id), ['strongsgreek']);
      expect(controller.isBrowsing, isFalse);
      final field = tester.widget<TextField>(
        find.byKey(const ValueKey('dictionary-lookup-query')),
      );
      expect(field.controller!.text, 'G4487');
      expect(tester.takeException(), isNull);
    },
  );

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
      expect(controller.metadata!.language, 'en');
      expect(controller.matches.map((match) => match.id), contains('G3056--2'));
      await tester.scrollUntilVisible(
        find.text('Word; speech.\n\nA second paragraph.'),
        150,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('Word; speech.\n\nA second paragraph.'), findsOneWidget);
      final Finder citation = find.widgetWithText(ActionChip, 'John 1:1');
      await tester.scrollUntilVisible(
        citation,
        150,
        scrollable: find.byType(Scrollable).first,
      );
      // ensureVisible changes the scroll position synchronously, but the
      // resulting layout must be painted before a pointer can hit the chip.
      await tester.pumpAndSettle();
      expect(citation.hitTestable(), findsOneWidget);
      await tester.tap(citation);
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
      await tester.pumpAndSettle();
      expect(link.hitTestable(), findsOneWidget);
      await tester.tap(link);
      await tester.pumpAndSettle();
      expect(find.text('A saying.'), findsOneWidget);
      final Finder previous = find.widgetWithText(
        TextButton,
        'Previous dictionary word',
      );
      await tester.scrollUntilVisible(
        previous,
        -150,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      expect(previous.hitTestable(), findsOneWidget);
      await tester.tap(previous);
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
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Ka\u0301de\u0301sh');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      expect(controller.matches.length, 2);
      expect(tester.takeException(), isNull);
      final Finder moduleField = find.byType(DropdownButtonFormField<String>);
      await tester.scrollUntilVisible(
        moduleField,
        -150,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      expect(moduleField.hitTestable(), findsOneWidget);
      await tester.tap(moduleField);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );
}
