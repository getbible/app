import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:getbible/domain/models/bible.dart';
import 'package:getbible/presentation/widgets/reader_translation_picker.dart';

const _english = Translation(
  translation: 'King James Version',
  abbreviation: 'kjv',
  lang: 'en',
  language: 'English',
  direction: 'LTR',
  sha: 'kjv-sha',
  description: 'An English Bible translation.',
  distributionLicense: 'Public domain',
);
const _afrikaans = Translation(
  translation: 'Afrikaanse Bybel',
  abbreviation: 'af1933',
  lang: 'af',
  language: 'Afrikaans',
  direction: 'LTR',
  sha: 'af1933-sha',
  description: 'Die volledige beskrywing.',
  distributionLicense: 'Source license preserved verbatim.',
  distributionAbout: 'Published source contact information.',
);
const _hebrew = Translation(
  translation: 'תנ״ך עברי',
  abbreviation: 'hebrew',
  lang: 'he',
  language: 'עברית',
  direction: 'RTL',
  sha: 'hebrew-sha',
);
const _translations = [_english, _afrikaans, _hebrew];

Finder _key(String key) => find.byKey(ValueKey(key));

Future<void> _pump(
  WidgetTester tester, {
  List<Translation> translations = _translations,
  Future<void> Function(String)? onOpen,
  VoidCallback? onClose,
  double width = 480,
  double height = 560,
  double textScale = 1,
  TextDirection direction = TextDirection.ltr,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Center(
          child: MediaQuery(
            data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
            child: Directionality(
              textDirection: direction,
              child: SizedBox(
                width: width,
                height: height,
                child: ReaderTranslationPicker(
                  translations: translations,
                  value: _english.abbreviation,
                  onOpen: onOpen ?? (_) async {},
                  onClose: onClose ?? () {},
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  final visible = tester
      .getRect(finder)
      .intersect(tester.getRect(_key('translation-picker-scroll')));
  await tester.tapAt(visible.center);
  await tester.pumpAndSettle();
}

Future<void> _choose(WidgetTester tester, String abbreviation) async {
  await _tap(tester, _key('translation-picker-choice'));
  final option = _key('translation-picker-option-$abbreviation');
  await tester.scrollUntilVisible(
    option,
    100,
    scrollable: find
        .descendant(
          of: _key('translation-picker-scroll'),
          matching: find.byType(Scrollable),
        )
        .first,
  );
  await _tap(tester, option);
}

void main() {
  testWidgets('browsing chooses one metadata card before explicitly opening', (
    tester,
  ) async {
    final opened = <String>[];
    await _pump(tester, onOpen: (value) async => opened.add(value));

    expect(_key('translation-picker-details'), findsOneWidget);
    expect(find.text('Translation details'), findsOneWidget);
    expect(find.text('An English Bible translation.'), findsOneWidget);
    expect(find.text('Public domain'), findsOneWidget);
    expect(find.text('Current translation'), findsOneWidget);

    await _choose(tester, _afrikaans.abbreviation);

    expect(opened, isEmpty);
    expect(_key('translation-picker-details'), findsOneWidget);
    expect(find.text('Die volledige beskrywing.'), findsOneWidget);
    expect(find.text('Source license preserved verbatim.'), findsOneWidget);
    expect(find.text('Published source contact information.'), findsOneWidget);
    expect(find.text('An English Bible translation.'), findsNothing);
    expect(find.text(_english.translation), findsOneWidget);

    await _tap(tester, _key('translation-picker-open'));
    expect(opened, [_afrikaans.abbreviation]);
  });

  testWidgets('closing a different candidate does not commit it', (
    tester,
  ) async {
    final opened = <String>[];
    var closed = 0;
    await _pump(
      tester,
      onOpen: (value) async => opened.add(value),
      onClose: () => closed++,
    );
    await _choose(tester, _afrikaans.abbreviation);
    await _tap(tester, _key('translation-picker-close'));

    expect(opened, isEmpty);
    expect(closed, 1);
  });

  for (final query in ['Afrikaanse', 'AFRIKAANS', 'af1933', 'af bybel']) {
    testWidgets('catalogue search matches $query without opening Scripture', (
      tester,
    ) async {
      final opened = <String>[];
      await _pump(tester, onOpen: (value) async => opened.add(value));
      await _tap(tester, _key('translation-picker-choice'));
      await tester.enterText(_key('translation-picker-search'), query);
      await tester.pumpAndSettle();

      expect(_key('translation-picker-option-af1933'), findsOneWidget);
      expect(_key('translation-picker-option-kjv'), findsNothing);
      expect(_key('translation-picker-option-hebrew'), findsNothing);
      expect(opened, isEmpty);
    });
  }

  testWidgets('keyboard search selects its sole match without opening', (
    tester,
  ) async {
    final opened = <String>[];
    await _pump(tester, onOpen: (value) async => opened.add(value));
    await _tap(tester, _key('translation-picker-choice'));
    await tester.enterText(_key('translation-picker-search'), 'hebrew');
    await tester.pumpAndSettle();
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();

    expect(opened, isEmpty);
    expect(_key('translation-picker-search'), findsNothing);
    final hebrewName = tester.widget<Text>(find.text(_hebrew.translation).last);
    expect(hebrewName.textDirection, TextDirection.rtl);
    await _tap(tester, _key('translation-picker-open'));
    expect(opened, [_hebrew.abbreviation]);
  });

  testWidgets('search exposes no matches and can reset the filter', (
    tester,
  ) async {
    await _pump(tester);
    await _tap(tester, _key('translation-picker-choice'));
    await tester.enterText(
      _key('translation-picker-search'),
      'nothing matches this translation',
    );
    await tester.pumpAndSettle();

    expect(find.text('No matching resources.'), findsOneWidget);
    expect(_key('translation-picker-option-kjv'), findsNothing);
    await _tap(tester, find.byTooltip('Reset filters'));
    expect(find.text('No matching resources.'), findsNothing);
    expect(_key('translation-picker-option-kjv'), findsOneWidget);
  });

  testWidgets('empty catalogue explains unavailability and allows close', (
    tester,
  ) async {
    var closed = false;
    await _pump(tester, translations: [], onClose: () => closed = true);
    expect(find.text('No translations are available.'), findsOneWidget);
    expect(_key('translation-picker-open'), findsNothing);
    await _tap(tester, _key('translation-picker-close'));
    expect(closed, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('failed open retains its candidate and offers a working retry', (
    tester,
  ) async {
    final opened = <String>[];
    await _pump(
      tester,
      onOpen: (value) async {
        opened.add(value);
        if (opened.length == 1) throw StateError('Connection unavailable');
      },
    );
    await _choose(tester, _afrikaans.abbreviation);
    await _tap(tester, _key('translation-picker-open'));

    expect(find.text('Unable to open this passage'), findsOneWidget);
    expect(find.textContaining('Connection unavailable'), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);
    await _tap(tester, _key('translation-picker-open'));
    expect(opened, [_afrikaans.abbreviation, _afrikaans.abbreviation]);
    expect(find.text('Try again'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('an in-flight open disables repeated submissions', (
    tester,
  ) async {
    final completion = Completer<void>();
    var opened = 0;
    await _pump(
      tester,
      onOpen: (_) {
        opened++;
        return completion.future;
      },
    );
    await tester.ensureVisible(_key('translation-picker-open'));
    await tester.tap(_key('translation-picker-open'));
    await tester.pump();

    expect(opened, 1);
    expect(find.text('Opening Bible'), findsOneWidget);
    expect(
      tester.widget<FilledButton>(_key('translation-picker-open')).onPressed,
      isNull,
    );
    completion.complete();
    await tester.pumpAndSettle();
    expect(find.text('Open in reader'), findsOneWidget);
  });

  testWidgets('close remains available while an open is pending', (
    tester,
  ) async {
    final completion = Completer<void>();
    var closed = false;
    await _pump(
      tester,
      onOpen: (_) => completion.future,
      onClose: () => closed = true,
    );
    await tester.ensureVisible(_key('translation-picker-open'));
    await tester.tap(_key('translation-picker-open'));
    await tester.pump();
    await tester.ensureVisible(_key('translation-picker-close'));
    await tester.tap(_key('translation-picker-close'));
    await tester.pump();

    expect(closed, isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
    completion.completeError(StateError('Cancelled route finished later'));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('long RTL catalogue at 200% keeps all controls reachable', (
    tester,
  ) async {
    const long = Translation(
      translation:
          'A complete translation with an extraordinarily long published name '
          'that must remain readable on a compact phone',
      abbreviation: 'long',
      lang: 'en',
      language: 'English with a long source language description',
      direction: 'LTR',
      sha: 'long-sha',
      description: 'The publisher retains this complete source description.',
      distributionLicense: 'Complete license and copyright terms are retained.',
    );
    final translations = [
      _english,
      for (var index = 0; index < 200; index++)
        Translation(
          translation: 'Catalogue translation $index',
          abbreviation: 'translation$index',
          lang: 'en',
          language: 'English',
          direction: 'LTR',
          sha: '$index-sha',
        ),
      long,
    ];
    final opened = <String>[];
    await _pump(
      tester,
      translations: translations,
      width: 320,
      height: 220,
      textScale: 2,
      direction: TextDirection.rtl,
      onOpen: (value) async => opened.add(value),
    );
    await _tap(tester, _key('translation-picker-choice'));
    await tester.ensureVisible(_key('translation-picker-search'));
    await tester.enterText(
      _key('translation-picker-search'),
      'extraordinarily',
    );
    await tester.pumpAndSettle();
    await _tap(tester, _key('translation-picker-option-long'));

    expect(_key('translation-picker-details'), findsOneWidget);
    expect(find.byType(CustomScrollView), findsOneWidget);
    expect(tester.takeException(), isNull);
    await _tap(tester, _key('translation-picker-open'));
    expect(opened, ['long']);
    expect(tester.takeException(), isNull);
  });
}
