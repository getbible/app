import 'bible.dart';
import 'search.dart';
import 'service_envelopes.dart';

enum SearchExecutionMode { online, installed }

enum OnlineSearchScope { bible, oldTestament, newTestament, deuterocanon }

enum SearchDiacritics { fold, exact }

enum SearchSort { canonical, relevance }

/// Immutable, service-native criteria. Locale is intentionally absent: the
/// Search API owns Unicode/script analysis and does not accept a locale filter.
final class OnlineSearchCriteria {
  OnlineSearchCriteria({
    this.words = SearchWordMode.all,
    this.match = SearchMatchMode.exact,
    this.caseSensitive = false,
    this.scope = OnlineSearchScope.bible,
    List<int> books = const <int>[],
    this.diacritics = SearchDiacritics.fold,
    List<String> exclusions = const <String>[],
    this.proximity,
    this.sort = SearchSort.canonical,
  }) : books = List<int>.unmodifiable(books),
       exclusions = List<String>.unmodifiable(exclusions) {
    if (books.length > 83 || books.any((int book) => book < 1)) {
      throw const FormatException('Select at most 83 valid books.');
    }
    if (exclusions.length > 32 ||
        exclusions.any(
          (String term) => term.trim().isEmpty || term.runes.length > 100,
        )) {
      throw const FormatException(
        'Use at most 32 exclusions of 1–100 characters each.',
      );
    }
    if (proximity != null &&
        (words != SearchWordMode.all || proximity! < 0 || proximity! > 100)) {
      throw const FormatException(
        'Proximity must be 0–100 and requires All words.',
      );
    }
  }

  factory OnlineSearchCriteria.fromOptions(
    SearchOptions options, {
    SearchDiacritics diacritics = SearchDiacritics.fold,
  }) => OnlineSearchCriteria(
    words: options.words,
    match: options.match,
    caseSensitive: options.caseSensitive,
    diacritics: diacritics,
    scope: switch (options.scope.type) {
      SearchScopeType.oldTestament => OnlineSearchScope.oldTestament,
      SearchScopeType.newTestament => OnlineSearchScope.newTestament,
      SearchScopeType.all || SearchScopeType.book => OnlineSearchScope.bible,
    },
    books: options.scope.book == null
        ? const <int>[]
        : <int>[options.scope.book!],
  );

  final SearchWordMode words;
  final SearchMatchMode match;
  final bool caseSensitive;
  final OnlineSearchScope scope;
  final List<int> books;
  final SearchDiacritics diacritics;
  final List<String> exclusions;
  final int? proximity;
  final SearchSort sort;
}

/// An explicitly requested Scripture search, bounded by the shared page contract.
/// [text] is retained exactly, including an original selected phrase.
final class OnlineSearchRequest {
  OnlineSearchRequest({
    required this.translation,
    required this.text,
    required this.criteria,
    this.limit = 25,
    this.offset = 0,
    this.direction = 'LTR',
  }) {
    if (!RegExp(r'^[a-zA-Z0-9_-]+$').hasMatch(translation) ||
        translation.length > 100) {
      throw const FormatException('Select a valid Bible translation.');
    }
    if (text.trim().isEmpty || text.runes.length > 500) {
      throw const FormatException('Search must contain 1–500 characters.');
    }
    if (limit < 1 || limit > 100 || offset < 0 || offset > 10000) {
      throw const FormatException(
        'Search pages require a limit of 1–100 and offset of 0–10000.',
      );
    }
    if (direction != 'LTR' && direction != 'RTL') {
      throw const FormatException('Unsupported Scripture direction.');
    }
  }

  final String translation;
  final String text;
  final OnlineSearchCriteria criteria;
  final int limit;
  final int offset;
  final String direction;

  OnlineSearchRequest atOffset(int value) => OnlineSearchRequest(
    translation: translation,
    text: text,
    criteria: criteria,
    limit: limit,
    offset: value,
    direction: direction,
  );
}

/// One ranked API match and its unchanged source verse. Match terms are words,
/// never text offsets; lexical enrichment remains available to Study callers.
final class OnlineSearchHit {
  const OnlineSearchHit({
    required this.translation,
    required this.book,
    required this.bookName,
    required this.chapter,
    required this.verse,
    required this.reference,
    required this.direction,
    required this.terms,
    this.score,
    this.occurrences,
  });

  final String translation;
  final int book;
  final String bookName;
  final int chapter;
  final Verse verse;
  final String reference;
  final String direction;
  final List<String> terms;
  final double? score;
  final int? occurrences;

  String get identity => '$translation/$book/$chapter/${verse.verse}';

  SearchVerse toSearchVerse() => SearchVerse(
    book: book,
    bookName: bookName,
    chapter: chapter,
    verse: verse.verse,
    reference: reference,
    text: verse.text,
  );
}

final class OnlineSearchPage {
  const OnlineSearchPage({
    required this.kind,
    required this.hits,
    required this.total,
    required this.returned,
    required this.engineVersion,
    required this.offset,
    required this.hasMore,
    required this.sourceSha,
  });

  final SearchResultKind kind;
  final List<OnlineSearchHit> hits;
  final int total;
  final int returned;
  final int engineVersion;
  final int offset;
  final bool hasMore;
  final String? sourceSha;

  int get nextOffset => offset + returned;
}
