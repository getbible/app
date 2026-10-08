import '../../core/errors.dart';
import '../../core/json.dart';
import '../../core/request_cancellation.dart';
import '../../domain/models/bible.dart';
import '../../domain/models/online_search.dart';
import '../../domain/models/search.dart';
import '../../domain/models/service_envelopes.dart';
import '../../domain/repositories/search_repository.dart';
import '../api/api_configuration.dart';
import '../api/api_transport.dart';
import '../api/service_envelope_adapters.dart';

/// On-demand Search v3 pages. This repository never requests a Bible corpus.
final class ApiSearchRepository implements SearchRepository {
  const ApiSearchRepository(this.transport);

  final ApiTransport transport;

  @override
  Future<OnlineSearchPage> search(
    OnlineSearchRequest request, {
    RequestCancellation? cancellation,
  }) async {
    final OnlineSearchCriteria criteria = request.criteria;
    final ApiResponse response = await transport.get(
      ApiService.search,
      request.translation,
      query: <String, Object?>{
        'q': request.text,
        'words': criteria.words.name,
        'match': criteria.match == SearchMatchMode.exact
            ? 'whole_word'
            : 'substring',
        'case_sensitive': criteria.caseSensitive,
        'scope': switch (criteria.scope) {
          OnlineSearchScope.bible => 'bible',
          OnlineSearchScope.oldTestament => 'old_testament',
          OnlineSearchScope.newTestament => 'new_testament',
          OnlineSearchScope.deuterocanon => 'deuterocanon',
        },
        if (criteria.books.isNotEmpty) 'book': criteria.books,
        'diacritics': criteria.diacritics.name,
        if (criteria.exclusions.isNotEmpty) 'exclude': criteria.exclusions,
        'proximity': criteria.proximity,
        'sort': criteria.sort.name,
        'limit': request.limit,
        'offset': request.offset,
      },
      maxBytes: ApiResponseLimits.query,
      cancellation: cancellation,
    );
    try {
      final SearchEnvelope envelope = ServiceEnvelopeAdapters.search(
        response.json,
        selectedTranslation: request.translation,
      );
      return _page(envelope, request);
    } on ApiFormatException {
      transport.discardResponse(response);
      rethrow;
    } on FormatException catch (error) {
      transport.discardResponse(response);
      throw ApiFormatException('Invalid Search v3 response.', error);
    }
  }

  OnlineSearchPage _page(SearchEnvelope envelope, OnlineSearchRequest request) {
    final Map<(int, int, int), (SearchApiChapter, Verse)> verses =
        <(int, int, int), (SearchApiChapter, Verse)>{};
    for (final SearchApiChapter chapter in envelope.chapters.values) {
      if (chapter.abbreviation != null &&
          chapter.abbreviation!.toLowerCase() !=
              request.translation.toLowerCase()) {
        throw const FormatException(
          'A result chapter belongs to another Bible.',
        );
      }
      for (final Verse verse in chapter.verses) {
        final (int, int, int) key = (
          chapter.bookNumber,
          chapter.chapter,
          verse.verse,
        );
        if (verse.chapter != chapter.chapter || verses.containsKey(key)) {
          throw const FormatException(
            'Search contains ambiguous verse coordinates.',
          );
        }
        verses[key] = (chapter, verse);
      }
    }
    final JsonMap query = requireJsonMap(
      envelope.source['query'],
      'search query',
    );
    final Object? rawTranslation = query['translation'];
    final String fallbackDirection = rawTranslation is Map
        ? _direction(
            requireJsonMap(rawTranslation, 'translation'),
            request.direction,
          )
        : request.direction;
    final List<OnlineSearchHit> hits = <OnlineSearchHit>[];
    for (final SearchApiMatch match in envelope.matches) {
      final (SearchApiChapter chapter, Verse verse) =
          verses[(match.book, match.chapter, match.verse)]!;
      hits.add(
        OnlineSearchHit(
          translation: request.translation,
          book: match.book,
          bookName: chapter.bookName ?? match.reference,
          chapter: match.chapter,
          verse: verse,
          reference: match.reference,
          direction: _direction(chapter.source, fallbackDirection),
          terms: List<String>.unmodifiable(match.terms),
          score: match.score,
          occurrences: match.occurrences,
        ),
      );
    }
    final bool reference = envelope.kind == SearchResultKind.reference;
    final int offset = reference ? 0 : envelope.offset ?? request.offset;
    final bool hasMore =
        !reference &&
        (envelope.hasMore ?? offset + envelope.returned < envelope.total);
    if (reference && envelope.total != envelope.returned) {
      throw const FormatException(
        'Reference search did not return the complete passage.',
      );
    }
    if (!reference &&
        (offset != request.offset ||
            offset > 10000 ||
            envelope.returned > request.limit ||
            (envelope.limit != null && envelope.limit! > 100) ||
            (hasMore && envelope.returned == 0) ||
            (envelope.hasMore != null &&
                hasMore != (offset + envelope.returned < envelope.total)))) {
      throw const FormatException('Search returned inconsistent pagination.');
    }
    return OnlineSearchPage(
      kind: envelope.kind,
      hits: List<OnlineSearchHit>.unmodifiable(hits),
      total: envelope.total,
      returned: envelope.returned,
      engineVersion: envelope.engineVersion,
      offset: offset,
      hasMore: hasMore,
      sourceSha: envelope.sourceSha,
    );
  }

  String _direction(JsonMap source, String fallback) {
    final Object? direction = source['direction'];
    if (direction == null) return fallback;
    if (direction != 'LTR' && direction != 'RTL') {
      throw const FormatException('Search has an invalid text direction.');
    }
    return direction as String;
  }
}
