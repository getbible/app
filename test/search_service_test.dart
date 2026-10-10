import 'package:flutter_test/flutter_test.dart';
import 'package:getbible/domain/models/bible.dart';
import 'package:getbible/domain/models/search.dart';
import 'package:getbible/services/search_service.dart';

void main() {
  final WholeTranslation corpus = WholeTranslation(
    translation: 'Test',
    abbreviation: 'tst',
    language: 'Test',
    lang: 'en',
    direction: 'LTR',
    books: <WholeTranslationBook>[
      WholeTranslationBook(
        number: 1,
        name: 'Genesis',
        chapters: <WholeTranslationChapter>[
          WholeTranslationChapter(
            chapter: 1,
            name: 'Genesis 1',
            verses: const <Verse>[
              Verse(
                chapter: 1,
                verse: 1,
                name: '',
                text: 'Beginning begins begun.',
              ),
              Verse(chapter: 1, verse: 2, name: '', text: 'שלום עולם ושלום'),
            ],
          ),
        ],
      ),
    ],
  );

  test('distinguishes exact and partial word matching', () async {
    final List<SearchVerse> exact = await searchTranslation(
      corpus,
      'begin',
      const SearchOptions(match: SearchMatchMode.exact),
    );
    final List<SearchVerse> partial = await searchTranslation(
      corpus,
      'begin',
      const SearchOptions(match: SearchMatchMode.partial),
    );

    expect(exact, isEmpty);
    expect(partial, hasLength(1));
  });

  test('matches Unicode exact words', () async {
    final List<SearchVerse> results = await searchTranslation(
      corpus,
      'שלום',
      const SearchOptions(match: SearchMatchMode.exact),
    );

    expect(results, hasLength(1));
    expect(results.single.verse, 2);
  });

  test('matches exact multi-word phrases by token sequence', () async {
    final List<SearchVerse> results = await searchTranslation(
      corpus,
      'Beginning begins',
      const SearchOptions(
        words: SearchWordMode.phrase,
        match: SearchMatchMode.exact,
      ),
    );

    expect(results, hasLength(1));
  });
}
