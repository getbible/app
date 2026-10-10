import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:getbible/domain/models/bible.dart';
import 'package:getbible/presentation/widgets/reader_translation_field.dart';

void main() {
  const Translation longTranslation = Translation(
    translation:
        'The extraordinarily long complete translation name used for overflow testing',
    abbreviation: 'long',
    lang: 'en',
    language: 'English',
    direction: 'LTR',
    sha: 'translation-sha',
  );

  testWidgets('selected translation stays within a narrow large-text field', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(
            size: Size(280, 640),
            textScaler: TextScaler.linear(2),
          ),
          child: Scaffold(
            body: SizedBox(
              width: 244,
              child: ReaderTranslationField(
                translations: const <Translation>[longTranslation],
                value: longTranslation.abbreviation,
                onChanged: (_) {},
              ),
            ),
          ),
        ),
      ),
    );

    expect(find.byType(ReaderTranslationField), findsOneWidget);
    expect(find.textContaining('extraordinarily long'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('opens the menu and reports a changed translation', (
    WidgetTester tester,
  ) async {
    const Translation second = Translation(
      translation: 'Second translation',
      abbreviation: 'second',
      lang: 'en',
      language: 'English',
      direction: 'LTR',
      sha: 'second-sha',
    );
    String? changed;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ReaderTranslationField(
            translations: const <Translation>[longTranslation, second],
            value: longTranslation.abbreviation,
            onChanged: (String? value) => changed = value,
          ),
        ),
      ),
    );

    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Second translation').last);
    await tester.pumpAndSettle();

    expect(changed, second.abbreviation);
    expect(tester.takeException(), isNull);
  });
}
