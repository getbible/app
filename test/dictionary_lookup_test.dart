import 'package:flutter_test/flutter_test.dart';
import 'package:getbible/application/dictionary_lookup.dart';
import 'package:getbible/domain/models/bible.dart';
import 'package:getbible/domain/models/dictionary.dart';
import 'package:getbible/domain/models/dictionary_folding.dart';
import 'package:getbible/domain/models/passage.dart';
import 'package:getbible/domain/models/reference.dart';
import 'package:getbible/domain/models/study_citation.dart';
import 'package:getbible/domain/models/study_context.dart';

void main() {
  test(
    'native word range finds every Strong ID, lemma, morphology and xlit',
    () {
      final Verse verse = Verse.fromJson(<String, Object?>{
        'verse': 1,
        'chapter': 1,
        'text': 'A😀 Word, end.',
        'tokens': <Object?>[
          <String, Object?>{
            'token': 'Word',
            'word_start': 2,
            'word_end': 2,
            'lemma': <String, Object?>{
              'strong': <String>['G3056', 'G4487'],
              'greek': <String>['λόγος'],
            },
            'morph': <String, Object?>{
              'robinson': <String>['N-NSM'],
            },
            'xlit': <String, Object?>{
              'latin': <String>['logos'],
            },
          },
          <String, Object?>{
            'token': 'unlocated',
            'word_start': 0,
            'word_end': 0,
            'lemma': <String, Object?>{
              'strong': <String>['H0430'],
            },
          },
        ],
      });
      final DictionaryLookup lookup = DictionaryLookupBuilder.fromContext(
        _context(verse, 4, 9),
      );
      expect(lookup.sourceWord, 'Word,');
      expect(lookup.strongs, <String>['G3056', 'G4487']);
      expect(lookup.lemmas, <String>['λόγος']);
      expect(lookup.morphology, <String>['N-NSM']);
      expect(lookup.transliterations, <String>['logos']);
      expect(
        lookup.candidates,
        containsAll(<String>['Word,', 'Word', 'G3056', 'G4487']),
      );
      expect(lookup.family, 'strong:G');
      expect(verse.text, 'A😀 Word, end.');
    },
  );

  test(
    'plain word punctuation and precomposed/decomposed accents match all definitions',
    () {
      final DictionaryIndex index = DictionaryIndex(
        dictionary: 'fixture',
        language: 'en',
        name: 'Fixture',
        uniqueKeyCount: 1,
        entries: <DictionaryIndexEntry>[
          DictionaryIndexEntry(
            id: 'exact-path',
            key: 'Kadesh',
            search: 'kadesh',
            aliases: <String>['Kádésh'],
          ),
          DictionaryIndexEntry(
            id: 'exact-path--2',
            key: 'Kadesh',
            search: 'kadesh',
            occurrence: 2,
          ),
        ],
      );
      final Verse verse = Verse.fromJson(<String, Object?>{
        'verse': 1,
        'chapter': 1,
        'text': '“Kádésh,”',
      });
      final DictionaryLookup lookup = DictionaryLookupBuilder.fromContext(
        _context(verse, 0, verse.text.length),
      );
      expect(lookup.strongs, isEmpty);
      expect(
        DictionaryIndexLookup.exact(
          index,
          lookup.candidates,
        ).map((DictionaryIndexEntry item) => item.id),
        <String>['exact-path', 'exact-path--2'],
      );
      expect(foldDictionaryKey('Ka\u0301de\u0301sh'), 'kadesh');
      expect(foldDictionaryKey('ΛΌΓΟΣ'), 'λογοσ');
      expect(foldDictionaryKey('λόγος'), 'λογοσ');
    },
  );

  test(
    'published Hebrew identifier is retained and no URL ID is synthesized',
    () {
      final DictionaryIndex index = DictionaryIndex(
        dictionary: 'hebrew',
        language: 'en',
        name: 'Hebrew',
        uniqueKeyCount: 1,
        entries: <DictionaryIndexEntry>[
          DictionaryIndexEntry(
            id: 'H0430',
            key: '00430',
            search: '00430',
            aliases: <String>['H0430'],
          ),
        ],
      );
      expect(
        DictionaryIndexLookup.exact(index, <String>['H0430']).single.id,
        'H0430',
      );
      expect(DictionaryIndexLookup.exact(index, <String>['H430']), isEmpty);
      final DictionaryIndex odd = DictionaryIndex(
        dictionary: 'odd',
        language: 'en',
        name: 'Odd',
        uniqueKeyCount: 1,
        entries: <DictionaryIndexEntry>[
          DictionaryIndexEntry(
            id: 'different-id',
            key: 'alpha',
            search: 'alpha',
          ),
        ],
      );
      expect(DictionaryIndexLookup.exact(odd, <String>['G1']), isEmpty);
    },
  );

  test('citations keep labels, ranges and v2 extended-book fallback', () {
    final StudyContext context = _context(
      Verse.fromJson(<String, Object?>{
        'verse': 1,
        'chapter': 1,
        'text': 'word',
      }),
      0,
      4,
    );
    final StudyCitation citation = StudyCitation(
      reference: 'Source label',
      osis: 'John.1.1',
      book: 43,
      chapter: 1,
      verse: 1,
      verses: <int>[1, 3],
    );
    final StructuredReferenceRequest request =
        citation.requestFor(context) as StructuredReferenceRequest;
    expect(request.sourceLabel, 'Source label');
    expect(request.translation, 'kjv');
    expect(request.selections.single.verses, <int>[1, 3]);
    expect(
      StudyCitation(
        reference: 'Source chapter',
        osis: 'John.1',
        book: 43,
        chapter: 1,
      ).requestFor(context),
      isA<TextReferenceRequest>(),
    );
    expect(
      StudyCitation(
        reference: 'Extended source',
        osis: 'Wis.1.1',
        book: 67,
        chapter: 1,
        verse: 1,
      ).requestFor(context),
      isA<TextReferenceRequest>(),
    );
    expect(
      () => StudyCitation(
        reference: 'Introduction',
        osis: 'John.0',
        book: 43,
        chapter: 0,
        verse: 0,
      ).requestFor(context),
      throwsA(isA<ReferenceLookupException>()),
    );
  });
}

StudyContext _context(Verse verse, int start, int end) => StudyContext(
  passage: const Passage(translation: 'kjv', book: 1, chapter: 1, verse: 1),
  bookName: 'Genesis',
  language: 'en',
  verse: verse,
  selectionStart: start,
  selectionEnd: end,
);
