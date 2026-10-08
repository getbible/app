import 'reference.dart';

/// Public identities are scoped by service root, never by translated labels.
String scopedPublicTopic(String sourceScope, String topicId) =>
    '$sourceScope|$topicId';

final class PublicTopicCoordinate implements Comparable<PublicTopicCoordinate> {
  const PublicTopicCoordinate(this.book, this.chapter, this.verse);

  final int book;
  final int chapter;
  final int verse;
  String get key => '$book/$chapter/$verse';

  @override
  int compareTo(PublicTopicCoordinate other) {
    final int byBook = book.compareTo(other.book);
    if (byBook != 0) return byBook;
    final int byChapter = chapter.compareTo(other.chapter);
    return byChapter != 0 ? byChapter : verse.compareTo(other.verse);
  }
}

/// A complete single-topic document contains coordinates, not summary counts.
final class PublicTopic {
  PublicTopic({
    required this.id,
    required this.name,
    required this.color,
    required Iterable<String> aliases,
    required this.isDefault,
    required Map<String, String> names,
    required Iterable<PublicTopicCoordinate> coordinates,
  }) : aliases = List<String>.unmodifiable(aliases),
       names = Map<String, String>.unmodifiable(names),
       coordinates = List<PublicTopicCoordinate>.unmodifiable(coordinates);

  final String id;
  final String name;
  final String color;
  final List<String> aliases;
  final bool isDefault;
  final Map<String, String> names;
  final List<PublicTopicCoordinate> coordinates;

  String localizedName(String locale) => names[locale] ?? names['en'] ?? name;

  List<ReferenceSelection> get selections {
    final Map<String, List<PublicTopicCoordinate>> chapters =
        <String, List<PublicTopicCoordinate>>{};
    for (final PublicTopicCoordinate coordinate in coordinates) {
      chapters
          .putIfAbsent('${coordinate.book}/${coordinate.chapter}', () => [])
          .add(coordinate);
    }
    return List<ReferenceSelection>.unmodifiable(
      chapters.values.map(
        (List<PublicTopicCoordinate> chapter) => ReferenceSelection(
          book: chapter.first.book,
          chapter: chapter.first.chapter,
          verses: chapter.map((PublicTopicCoordinate item) => item.verse),
        ),
      ),
    );
  }
}

final class PublicTopicDiscovery {
  PublicTopicDiscovery({
    required this.catalogVersion,
    required this.checksum,
    required this.topicCount,
    required this.associationCount,
    required this.localeCount,
    required Map<String, String> resources,
    required Iterable<String> locales,
  }) : resources = Map<String, String>.unmodifiable(resources),
       locales = List<String>.unmodifiable(locales);

  final int catalogVersion;
  final String checksum;
  final int topicCount;
  final int associationCount;
  final int localeCount;
  final Map<String, String> resources;
  final List<String> locales;
}

final class PublicTopicLocale {
  const PublicTopicLocale({
    required this.code,
    required this.name,
    required this.topicCount,
  });
  final String code;
  final String? name;
  final int topicCount;
}

final class PublicTopicNames {
  PublicTopicNames({required this.locale, required Map<String, String> names})
    : names = Map<String, String>.unmodifiable(names);
  final String locale;
  final Map<String, String> names;
}

final class PublicTopicAssociations {
  PublicTopicAssociations({
    required this.book,
    required this.chapter,
    required Map<int, List<String>> verses,
  }) : verses = Map<int, List<String>>.unmodifiable(
         verses.map(
           (int key, List<String> value) =>
               MapEntry(key, List<String>.unmodifiable(value)),
         ),
       );
  final int book;
  final int chapter;
  final Map<int, List<String>> verses;

  Set<String> forVerse(int? verse) => Set<String>.unmodifiable(
    verse == null
        ? verses.values.expand((List<String> ids) => ids)
        : verses[verse] ?? [],
  );
}

/// A snapshot for an explicit copy confirmation. Private names and annotations
/// are never inferred from the public catalogue's ids or default flag.
final class PublicTopicCopyPreview {
  const PublicTopicCopyPreview({
    required this.topic,
    required this.sourceScope,
    required this.translation,
    required this.groupName,
    required this.alreadyPresent,
    this.existingGroupId,
  });
  final PublicTopic topic;
  final String sourceScope;
  final String translation;
  final String groupName;
  final int alreadyPresent;
  final String? existingGroupId;
  int get newAssociationCount => topic.coordinates.length - alreadyPresent;
}

final class PublicTopicCopyResult {
  const PublicTopicCopyResult({required this.groupId, required this.added});
  final String groupId;
  final int added;
}
