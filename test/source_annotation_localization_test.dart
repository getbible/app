import 'package:flutter_test/flutter_test.dart';
import 'package:getbible_live/domain/models/bible.dart';
import 'package:getbible_live/services/source_annotations.dart';

void main() {
  test(
    'localizing source captions preserves Scripture, references and source attributes',
    () {
      final verse = Verse(
        chapter: 1,
        verse: 1,
        name: 'John 1:1',
        text: 'Original Scripture 😀 λόγος',
        spans: [
          ScriptureSpan.fromJson({
            'tag': 'note',
            'span': 'An original footnote.',
            'word_start': 0,
            'word_end': 0,
            'token_start': -1,
            'token_end': -1,
            'attrs': {'osisRef': 'John.1.3', 'type': 'study'},
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
      final seen = <String>[];
      final localized = verseSourceAnnotations(
        verse,
        localizeLabel: (label) {
          seen.add(label);
          return 'translated:$label';
        },
      );
      expect(localized.first.label, 'translated:Reference');
      expect(localized.first.text, 'An original footnote.');
      expect(localized.first.references, ['John.1.3']);
      expect(localized.first.details, ['type: study']);
      expect(localized.last.text, 'λόγος');
      expect(
        localized.last.details,
        contains('translated:Lemma (strong): G3056'),
      );
      expect(
        localized.last.details,
        contains('translated:Morphology (robinson): N-NSM'),
      );
      expect(seen, isNot(contains('λόγος')));
      expect(seen, isNot(contains('John.1.3')));
      expect(verse.text, 'Original Scripture 😀 λόγος');
    },
  );
}
