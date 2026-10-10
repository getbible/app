import '../../core/json.dart';
import 'passage.dart';

/// Published bookmark origin, independent of a user's group name and ID.
/// Personal membership in a linked group deliberately has no source of its own.
final class SharedBookmarkSource {
  const SharedBookmarkSource({required this.topicId, this.sourceScope});

  factory SharedBookmarkSource.fromJson(Object? value) {
    final JsonMap json = requireJsonMap(value, 'bookmark source');
    final String topicId = requireString(json, 'topicId');
    if (requireString(json, 'type') != 'shared-bookmark' ||
        !isValidTopicId(topicId)) {
      throw const FormatException('A bookmark contains an invalid source.');
    }
    final String? scope = json['sourceScope'] == null
        ? null
        : requireString(json, 'sourceScope');
    if (scope != null && (scope.isEmpty || scope.length > 2048)) {
      throw const FormatException('Invalid bookmark source scope.');
    }
    return SharedBookmarkSource(topicId: topicId, sourceScope: scope);
  }

  final String topicId;
  final String? sourceScope;
  static const String defaultScope =
      'bookmarks:v1:https://bookmarks.getbible.net/v1';
  String get effectiveScope => sourceScope ?? defaultScope;

  static bool isValidTopicId(String value) =>
      value.length <= 80 &&
      RegExp(r'^[a-z0-9]+(?:-[a-z0-9]+)*$').hasMatch(value);

  JsonMap toJson() => <String, Object?>{
    'type': 'shared-bookmark',
    'topicId': topicId,
    if (sourceScope != null) 'sourceScope': sourceScope,
  };
}

final class MarkingGroup {
  const MarkingGroup({
    required this.id,
    required this.name,
    required this.color,
    this.sortOrder = 0,
    this.isStarter = false,
    required this.updatedAt,
    this.source,
  });

  factory MarkingGroup.fromJson(Object? value) {
    final JsonMap json = requireJsonMap(value, 'marking group');
    final String color = optionalString(
      json,
      'color',
      optionalString(json, 'value'),
    );
    if (!RegExp(r'^#[0-9a-fA-F]{6}$').hasMatch(color)) {
      throw const FormatException('A marking group contains an invalid color.');
    }
    return MarkingGroup(
      id: requireString(json, 'id'),
      name: requireString(json, 'name'),
      color: color.toUpperCase(),
      sortOrder: optionalInt(json, 'sortOrder'),
      isStarter: optionalBool(json, 'isStarter'),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(
        optionalInt(json, 'updatedAt', DateTime.now().millisecondsSinceEpoch),
        isUtc: true,
      ),
      source: json.containsKey('source')
          ? SharedBookmarkSource.fromJson(json['source'])
          : null,
    );
  }

  final String id;
  final String name;
  final String color;
  final int sortOrder;
  final bool isStarter;
  final DateTime updatedAt;
  final SharedBookmarkSource? source;

  MarkingGroup copyWith({
    String? id,
    String? name,
    String? color,
    int? sortOrder,
    DateTime? updatedAt,
  }) => MarkingGroup(
    id: id ?? this.id,
    name: name ?? this.name,
    color: color ?? this.color,
    sortOrder: sortOrder ?? this.sortOrder,
    isStarter: isStarter,
    updatedAt: updatedAt ?? this.updatedAt,
    source: source,
  );

  JsonMap toJson({bool websiteCompatible = false}) => <String, Object?>{
    'id': id,
    'name': name,
    if (source != null) 'source': source!.toJson(),
    if (websiteCompatible) 'value': color.toLowerCase() else 'color': color,
    if (!websiteCompatible) ...<String, Object?>{
      'version': 1,
      'sortOrder': sortOrder,
      'isStarter': isStarter,
      'updatedAt': updatedAt.millisecondsSinceEpoch,
    },
  };
}

final class Marking {
  const Marking({
    required this.id,
    required this.passage,
    required this.verse,
    required this.start,
    required this.end,
    required this.quote,
    required this.reference,
    required this.groupId,
    required this.createdAt,
    this.source,
  });

  factory Marking.fromJson(Object? value) {
    final JsonMap json = requireJsonMap(value, 'marking');
    final Object? startValue = json['start'];
    final Object? endValue = json['end'];
    final int? start = startValue == null ? null : requireInt(json, 'start');
    final int? end = endValue == null ? null : requireInt(json, 'end');
    if ((start == null) != (end == null) ||
        (start != null && (start < 0 || end! <= start))) {
      throw const FormatException('A marking contains an invalid text range.');
    }
    final SharedBookmarkSource? source = json.containsKey('source')
        ? SharedBookmarkSource.fromJson(json['source'])
        : null;
    if (source != null && start != null) {
      throw const FormatException(
        'A shared bookmark must cover a complete verse.',
      );
    }
    return Marking(
      id: requireString(json, 'id'),
      passage: Passage.fromJson(json['passage']),
      verse: requireInt(json, 'verse'),
      start: start,
      end: end,
      quote: requireString(json, 'quote'),
      reference: optionalString(json, 'reference'),
      groupId: requireString(
        json,
        json.containsKey('groupId') ? 'groupId' : 'colorId',
      ),
      createdAt: DateTime.fromMillisecondsSinceEpoch(
        requireInt(json, 'createdAt'),
        isUtc: true,
      ),
      source: source,
    );
  }

  final String id;
  final Passage passage;
  final int verse;
  final int? start;
  final int? end;
  final String quote;
  final String reference;
  final String groupId;
  final DateTime createdAt;
  final SharedBookmarkSource? source;

  bool get isWholeVerse => start == null && end == null;

  /// Only the website's exact historical deterministic ID implies provenance.
  /// A personal mark in the same group remains personal. Resolve this before
  /// renaming a colliding ID or remapping its group during backup import.
  SharedBookmarkSource? get sharedSource {
    if (!isWholeVerse) return null;
    if (source != null) return source;
    const String prefix = 'getbible-topic:';
    if (!groupId.startsWith(prefix)) return null;
    final String topicId = groupId.substring(prefix.length);
    if (!SharedBookmarkSource.isValidTopicId(topicId) ||
        id != '$groupId:${passage.book}:${passage.chapter}:$verse') {
      return null;
    }
    return SharedBookmarkSource(topicId: topicId);
  }

  bool get isSharedBookmark => sharedSource != null;
  String get identity => isWholeVerse
      ? '${passage.canonicalKey}|$verse|${isSharedBookmark ? 'shared:${sharedSource!.effectiveScope}:${sharedSource!.topicId}' : 'all'}|$groupId'
      : '${passage.key}|$verse|$start|$end|$quote|$groupId';

  bool matchesPassage(Passage other) => isWholeVerse
      ? passage.canonicalKey == other.canonicalKey
      : passage.key == other.key;

  Marking copyWith({
    String? id,
    int? start,
    int? end,
    String? quote,
    String? groupId,
  }) => Marking(
    id: id ?? this.id,
    passage: passage,
    verse: verse,
    start: start ?? this.start,
    end: end ?? this.end,
    quote: quote ?? this.quote,
    reference: reference,
    groupId: groupId ?? this.groupId,
    createdAt: createdAt,
    source: sharedSource,
  );

  JsonMap toJson({bool websiteCompatible = false}) => <String, Object?>{
    if (!websiteCompatible) 'version': 1,
    'id': id,
    'passage': passage.toJson(),
    'verse': verse,
    'start': start,
    'end': end,
    'quote': quote,
    'reference': reference,
    websiteCompatible ? 'colorId' : 'groupId': groupId,
    'createdAt': createdAt.millisecondsSinceEpoch,
    if (sharedSource != null) 'source': sharedSource!.toJson(),
  };
}

/// Personal whole-verse membership wins over later public imports. The most
/// recent mark within the chosen origin wins; stable IDs break timestamp ties.
Marking? preferredWholeVerseMarking(Iterable<Marking> markings) {
  Marking? preferred;
  for (final Marking marking in markings) {
    if (!marking.isWholeVerse) continue;
    final Marking? previous = preferred;
    if (previous == null ||
        (previous.isSharedBookmark && !marking.isSharedBookmark) ||
        (previous.isSharedBookmark == marking.isSharedBookmark &&
            (marking.createdAt.isAfter(previous.createdAt) ||
                (marking.createdAt == previous.createdAt &&
                    marking.id.compareTo(previous.id) > 0)))) {
      preferred = marking;
    }
  }
  return preferred;
}

final class VerseNote {
  const VerseNote({
    required this.id,
    required this.passage,
    required this.verse,
    required this.reference,
    required this.text,
    required this.createdAt,
    required this.updatedAt,
  });

  factory VerseNote.fromJson(Object? value) {
    final JsonMap json = requireJsonMap(value, 'verse note');
    return VerseNote(
      id: requireString(json, 'id'),
      passage: Passage.fromJson(json['passage']),
      verse: requireInt(json, 'verse'),
      reference: requireString(json, 'reference'),
      text: requireString(json, 'text'),
      createdAt: DateTime.fromMillisecondsSinceEpoch(
        requireInt(json, 'createdAt'),
        isUtc: true,
      ),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(
        requireInt(json, 'updatedAt'),
        isUtc: true,
      ),
    );
  }

  final String id;
  final Passage passage;
  final int verse;
  final String reference;
  final String text;
  final DateTime createdAt;
  final DateTime updatedAt;

  String get canonicalKey => '${passage.canonicalKey}/$verse';

  bool matchesPassage(Passage other) =>
      passage.canonicalKey == other.canonicalKey;

  VerseNote copyWith({String? id}) => VerseNote(
    id: id ?? this.id,
    passage: passage,
    verse: verse,
    reference: reference,
    text: text,
    createdAt: createdAt,
    updatedAt: updatedAt,
  );

  JsonMap toJson() => <String, Object?>{
    'version': 1,
    'id': id,
    'passage': passage.toJson(),
    'verse': verse,
    'reference': reference,
    'text': text,
    'createdAt': createdAt.millisecondsSinceEpoch,
    'updatedAt': updatedAt.millisecondsSinceEpoch,
  };
}

int compareMarkings(Marking left, Marking right) =>
    left.passage.book.compareTo(right.passage.book) != 0
    ? left.passage.book.compareTo(right.passage.book)
    : left.passage.chapter.compareTo(right.passage.chapter) != 0
    ? left.passage.chapter.compareTo(right.passage.chapter)
    : left.verse.compareTo(right.verse) != 0
    ? left.verse.compareTo(right.verse)
    : (left.start ?? -1).compareTo(right.start ?? -1);

int compareNotes(VerseNote left, VerseNote right) =>
    left.passage.book.compareTo(right.passage.book) != 0
    ? left.passage.book.compareTo(right.passage.book)
    : left.passage.chapter.compareTo(right.passage.chapter) != 0
    ? left.passage.chapter.compareTo(right.passage.chapter)
    : left.verse.compareTo(right.verse);
