import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:getbible/domain/models/bible.dart';
import 'package:getbible/presentation/widgets/scripture_verse_text.dart';
import 'package:getbible/presentation/widgets/source_annotations.dart';
import 'package:getbible/services/source_annotations.dart';

Verse _sourceVerse() => Verse(
  chapter: 1,
  verse: 1,
  name: 'John 1:1',
  text: 'Exact 😀 words.',
  spans: [
    ScriptureSpan.fromJson({
      'tag': 'q',
      'span': 'words.',
      'word_start': 3,
      'word_end': 3,
      'token_start': 0,
      'token_end': 0,
      'attrs': {'who': '#Jesus'},
    }),
    ScriptureSpan.fromJson({
      'tag': 'note',
      'span': 'A complete source footnote.',
      'word_start': 0,
      'word_end': 0,
      'token_start': -1,
      'token_end': -1,
      'attrs': {'osisRef': 'John.1.3', 'type': 'study'},
    }),
    ScriptureSpan.fromJson({
      'tag': 'reference',
      'span': 'Literal unsafe attribute',
      'word_start': 0,
      'word_end': 0,
      'token_start': -1,
      'token_end': -1,
      'attrs': {'target': 'javascript:alert(1)'},
    }),
  ],
  tokens: [
    ScriptureToken.fromJson({
      'token': 'λόγος',
      'word_start': 0,
      'word_end': 0,
      'lemma': {
        'strong': ['G3056'],
      },
      'morph': {
        'robinson': ['N-NSM'],
      },
    }),
  ],
);

void main() {
  test(
    'notes and unlocated lexical metadata retain source; Jesus is not repeated',
    () {
      final verse = _sourceVerse();
      final annotations = verseSourceAnnotations(verse);
      expect(annotations.length, 3);
      expect(annotations.first.references, ['John.1.3']);
      expect(annotations[1].references, isEmpty);
      expect(annotations.last.details, contains('Lemma (strong): G3056'));
      expect(
        annotations.last.details,
        contains('Morphology (robinson): N-NSM'),
      );
      expect(verse.text, 'Exact 😀 words.');
    },
  );

  testWidgets(
    'marked source notes retain native citation ink and selection at 200% RTL',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(320, 700));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      String? preview;
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(2)),
            child: Directionality(
              textDirection: TextDirection.rtl,
              child: Scaffold(
                body: SingleChildScrollView(
                  child: ColoredBox(
                    color: const Color(0x2d336699),
                    child: Column(
                      children: [
                        ScriptureVerseText(
                          verse: _sourceVerse(),
                          style: const TextStyle(fontSize: 20),
                        ),
                        ScriptureSourceAnnotations(
                          verse: _sourceVerse(),
                          onReference: (value) => preview = value,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      final scripture = tester
          .widgetList<SelectableText>(find.byType(SelectableText))
          .first;
      expect(scripture.textSpan!.toPlainText(), 'Exact 😀 words.');
      final spans = scripture.textSpan!.children!.cast<TextSpan>();
      expect(spans.last.style!.color, const Color(0xffa31524));
      await tester.tap(find.text('Reference').first);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.widgetWithText(TextButton, 'John.1.3'));
      await tester.tap(find.widgetWithText(TextButton, 'John.1.3'));
      expect(preview, 'John.1.3');
      expect(tester.takeException(), isNull);
    },
  );
}
