import 'dart:isolate';

import '../domain/models/bible.dart';
import '../domain/models/search.dart';

Future<List<SearchVerse>> searchTranslation(
  WholeTranslation corpus,
  String query,
  SearchOptions options,
) => Isolate.run(() => _search(corpus, query, options));

List<SearchVerse> _search(
  WholeTranslation corpus,
  String rawQuery,
  SearchOptions options,
) {
  final String query = _normalize(rawQuery.trim(), options);
  final List<String> terms = _words(query);
  if (terms.isEmpty) return const <SearchVerse>[];
  final List<SearchVerse> result = <SearchVerse>[];
  for (final WholeTranslationBook book in corpus.books) {
    if (!options.scope.includes(book.number)) continue;
    for (final WholeTranslationChapter chapter in book.chapters) {
      for (final Verse verse in chapter.verses) {
        if (_matches(verse.text, query, terms, options)) {
          result.add(
            SearchVerse(
              book: book.number,
              bookName: book.name,
              chapter: chapter.chapter,
              verse: verse.verse,
              reference: verse.name.isNotEmpty
                  ? verse.name
                  : '${book.name} ${chapter.chapter}:${verse.verse}',
              text: verse.text,
            ),
          );
        }
      }
    }
  }
  return result;
}

bool _matches(
  String rawText,
  String query,
  List<String> queryWords,
  SearchOptions options,
) {
  final String text = _normalize(rawText, options);
  final List<String> verseWords = _words(text);
  if (options.words == SearchWordMode.phrase) {
    if (options.match == SearchMatchMode.partial) return text.contains(query);
    if (queryWords.length > verseWords.length) return false;
    for (
      int start = 0;
      start <= verseWords.length - queryWords.length;
      start++
    ) {
      bool equal = true;
      for (int offset = 0; offset < queryWords.length; offset++) {
        if (verseWords[start + offset] != queryWords[offset]) {
          equal = false;
          break;
        }
      }
      if (equal) return true;
    }
    return false;
  }
  bool contains(String term) => options.match == SearchMatchMode.exact
      ? verseWords.contains(term)
      : verseWords.any((String word) => word.contains(term));
  return options.words == SearchWordMode.all
      ? queryWords.every(contains)
      : queryWords.any(contains);
}

String _normalize(String value, SearchOptions options) =>
    options.caseSensitive ? value : value.toLowerCase();

List<String> _words(String value) => RegExp(
  r'[\p{L}\p{N}\p{M}]+',
  unicode: true,
).allMatches(value).map((RegExpMatch match) => match.group(0)!).toList();
