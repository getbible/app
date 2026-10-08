import '../../core/json.dart';
import 'bible.dart';

/// Source fields are retained so new capability/attribution data survives while
/// callers use named typed properties for the current discovery contracts.
final class DictionaryModule {
  const DictionaryModule({
    required this.id,
    required this.name,
    required this.language,
    required this.license,
    required this.entryCount,
    required this.uniqueKeyCount,
    required this.strongPrefix,
    required this.bytes,
    required this.source,
  });
  final String id;
  final String name;
  final String language;
  final String license;
  final int entryCount;
  final int uniqueKeyCount;
  final String? strongPrefix;
  final int bytes;
  final JsonMap source;
}

final class DictionaryCatalogue {
  const DictionaryCatalogue({required this.modules, required this.source});
  final List<DictionaryModule> modules;
  final JsonMap source;
}

final class CommentaryModule {
  const CommentaryModule({
    required this.id,
    required this.name,
    required this.language,
    required this.license,
    required this.bookCount,
    required this.chapterCount,
    required this.entryCount,
    required this.bytes,
    required this.source,
  });
  final String id;
  final String name;
  final String language;
  final String license;
  final int bookCount;
  final int chapterCount;
  final int entryCount;
  final int bytes;
  final JsonMap source;
}

final class CommentaryCatalogue {
  const CommentaryCatalogue({required this.modules, required this.source});
  final List<CommentaryModule> modules;
  final JsonMap source;
}

/// Public topic identity is separate from private marking group identity.
/// `verseCount` is an association count, never a list of passage coordinates.
final class PublicTopicSummary {
  const PublicTopicSummary({
    required this.id,
    required this.name,
    required this.color,
    required this.aliases,
    required this.isDefault,
    required this.verseCount,
    required this.source,
  });
  final String id;
  final String name;
  final String color;
  final List<String> aliases;
  final bool isDefault;
  final int verseCount;
  final JsonMap source;
}

final class PublicTopicCatalogue {
  const PublicTopicCatalogue({required this.topics, required this.source});
  final List<PublicTopicSummary> topics;
  final JsonMap source;
}

/// Search/Query assembled chapters may omit all display metadata. Coordinates
/// and selected verses remain useful without inventing book or chapter names.
final class SearchApiChapter {
  const SearchApiChapter({
    required this.bookNumber,
    required this.chapter,
    required this.verses,
    required this.source,
    this.abbreviation,
    this.bookName,
    this.name,
  });
  final int bookNumber;
  final int chapter;
  final List<Verse> verses;
  final String? abbreviation;
  final String? bookName;
  final String? name;
  final JsonMap source;
}

enum SearchResultKind { search, reference }

/// Matches retain server order and describe verse coordinates, not text offsets.
final class SearchApiMatch {
  const SearchApiMatch({
    required this.reference,
    required this.book,
    required this.chapter,
    required this.verse,
    required this.source,
    this.score,
    this.occurrences,
    this.terms = const [],
  });
  final String reference;
  final int book;
  final int chapter;
  final int verse;
  final double? score;
  final int? occurrences;
  final List<String> terms;
  final JsonMap source;
}

/// A native v3 envelope, without implying the future paginated Search UI exists.
/// Reference results intentionally have no full-text pagination or source SHA.
final class SearchEnvelope {
  const SearchEnvelope({
    required this.kind,
    required this.translation,
    required this.total,
    required this.returned,
    required this.engineVersion,
    required this.chapters,
    required this.matches,
    required this.source,
    this.offset,
    this.limit,
    this.hasMore,
    this.sourceSha,
  });
  final SearchResultKind kind;
  final String? translation;
  final int total;
  final int returned;
  final int engineVersion;
  final Map<String, SearchApiChapter> chapters;
  final List<SearchApiMatch> matches;
  final int? offset;
  final int? limit;
  final bool? hasMore;
  final String? sourceSha;
  final JsonMap source;
}
