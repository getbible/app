import 'dart:convert';

import '../../core/request_cancellation.dart';
import '../../domain/models/bible.dart';
import '../../domain/models/online_search.dart';
import '../../domain/models/search.dart';
import '../../domain/models/service_envelopes.dart';
import '../../domain/repositories/search_repository.dart';
import 'installed_bible_repository.dart';
import 'installed_query_repository.dart';

/// SQL narrows candidates inside Drift's worker. This adapter visits bounded
/// batches, retains only a page, and yields between batches for cancellation.
/// Offline matching deliberately has its own documented capabilities; it does
/// not pretend to reproduce the server's folding, proximity or relevance rank.
final class InstalledSearchRepository implements SearchRepository {
  InstalledSearchRepository({required this.installed, required this.query});
  final InstalledBibleRepository installed;
  final InstalledQueryRepository query;

  @override
  Future<OnlineSearchPage> search(
    OnlineSearchRequest request, {
    RequestCancellation? cancellation,
  }) async {
    cancellation?.throwIfCancelled();
    final snapshot = await installed.requireSnapshot(request.translation);
    final books = await installed.booksAt(snapshot);
    final isReference =
        RegExp(r'\d\s*:').hasMatch(request.text) ||
        books.any(
          (book) => RegExp(
            '^${RegExp.escape(book.name)}\\s*\\d',
            caseSensitive: false,
          ).hasMatch(request.text.trim()),
        );
    if (isReference) {
      final result = await query.queryAt(
        snapshot,
        request.text,
        cancellation: cancellation,
      );
      final hits = <OnlineSearchHit>[
        for (final chapter in result.chapters)
          for (final verse in chapter.verses)
            OnlineSearchHit(
              translation: request.translation,
              book: chapter.bookNumber,
              bookName: chapter.bookName,
              chapter: chapter.chapter,
              verse: verse,
              reference: verse.name.isNotEmpty
                  ? verse.name
                  : '${chapter.bookName} ${chapter.chapter}:${verse.verse}',
              direction: chapter.direction,
              terms: const [],
            ),
      ];
      return OnlineSearchPage(
        kind: SearchResultKind.reference,
        hits: hits,
        total: hits.length,
        returned: hits.length,
        engineVersion: 1,
        offset: 0,
        hasMore: false,
        sourceSha: snapshot.resource.revision,
      );
    }
    final criteria = request.criteria;
    if (criteria.diacritics != SearchDiacritics.exact ||
        criteria.sort != SearchSort.canonical ||
        criteria.proximity != null ||
        criteria.scope == OnlineSearchScope.deuterocanon) {
      throw const FormatException(
        'Installed search supports exact diacritics and Bible order. Diacritic folding, relevance ranking, proximity and Deuterocanon scope require Online search. Choose individual discovered books for other offline scopes.',
      );
    }
    String normalize(String text) =>
        criteria.caseSensitive ? text : text.toLowerCase();
    final text = normalize(request.text.trim());
    final terms = _words(text);
    if (terms.length > 50) {
      throw const FormatException(
        'Use no more than 50 words in an offline search.',
      );
    }
    if (criteria.exclusions.any((value) => _words(value).length != 1)) {
      throw const FormatException(
        'Each offline exclusion must contain one word.',
      );
    }
    if (terms.isEmpty) {
      throw const FormatException(
        'Enter at least one word or number to search.',
      );
    }
    final selectedBooks = books
        .where(
          (book) =>
              (criteria.books.isEmpty ||
                  criteria.books.contains(book.number)) &&
              switch (criteria.scope) {
                OnlineSearchScope.bible => true,
                OnlineSearchScope.oldTestament => book.number <= 39,
                OnlineSearchScope.newTestament =>
                  book.number >= 40 && book.number <= 66,
                OnlineSearchScope.deuterocanon => false,
              },
        )
        .map((book) => book.number)
        .toList();
    if (criteria.books.any(
      (book) => !books.any((candidate) => candidate.number == book),
    )) {
      throw const FormatException(
        'A selected book is unavailable in this installed Bible.',
      );
    }
    final hits = <OnlineSearchHit>[];
    int total = 0;
    int cursor = 0;
    while (selectedBooks.isNotEmpty) {
      cancellation?.throwIfCancelled();
      final rows = await installed.store.readSearchVerses(
        snapshot.resource.key,
        terms: terms,
        books: selectedBooks,
        matchAny: criteria.words == SearchWordMode.any,
        caseSensitive: criteria.caseSensitive,
        offset: cursor,
        limit: 100,
        generation: snapshot.generation,
      );
      for (final row in rows) {
        final value = normalize(row.text);
        if (!_matches(value, text, terms, criteria)) continue;
        if (criteria.exclusions.any(
          (excluded) => _excludes(value, normalize(excluded), criteria.match),
        )) {
          continue;
        }
        if (total >= request.offset && hits.length < request.limit) {
          final verse = Verse.fromJson(
            jsonDecode(row.verseJson),
            fallbackChapter: row.chapter,
          );
          hits.add(
            OnlineSearchHit(
              translation: request.translation,
              book: row.book,
              bookName: row.bookName,
              chapter: row.chapter,
              verse: verse,
              reference: verse.name.isNotEmpty
                  ? verse.name
                  : '${row.bookName} ${row.chapter}:${row.verse}',
              direction: row.direction,
              terms: _words(request.text.trim()),
            ),
          );
        }
        total++;
      }
      if (rows.length < 100) break;
      cursor += rows.length;
      await Future<void>.delayed(Duration.zero);
    }
    cancellation?.throwIfCancelled();
    if ((await installed.snapshot(request.translation))?.generation !=
        snapshot.generation) {
      throw const FormatException(
        'The installed Bible changed. Restart this search.',
      );
    }
    return OnlineSearchPage(
      kind: SearchResultKind.search,
      hits: hits,
      total: total,
      returned: hits.length,
      engineVersion: 1,
      offset: request.offset,
      hasMore: request.offset + hits.length < total,
      sourceSha: snapshot.resource.revision,
    );
  }
}

List<String> _words(String value) => RegExp(
  r'[\p{L}\p{N}\p{M}]+',
  unicode: true,
).allMatches(value).map((match) => match.group(0)!).toList();
bool _excludes(String text, String excluded, SearchMatchMode match) =>
    match == SearchMatchMode.partial
    ? text.contains(excluded)
    : _words(text).contains(_words(excluded).single);
bool _matches(
  String text,
  String query,
  List<String> terms,
  OnlineSearchCriteria criteria,
) {
  if (criteria.words == SearchWordMode.phrase &&
      criteria.match == SearchMatchMode.partial) {
    return text.contains(query);
  }
  final words = _words(text);
  if (criteria.words == SearchWordMode.phrase) {
    for (int start = 0; start <= words.length - terms.length; start++) {
      bool matches = true;
      for (int offset = 0; offset < terms.length; offset++) {
        if (words[start + offset] != terms[offset]) {
          matches = false;
          break;
        }
      }
      if (matches) return true;
    }
    return false;
  }
  bool matches(String term) => criteria.match == SearchMatchMode.exact
      ? words.contains(term)
      : words.any((word) => word.contains(term));
  return criteria.words == SearchWordMode.any
      ? terms.any(matches)
      : terms.every(matches);
}
