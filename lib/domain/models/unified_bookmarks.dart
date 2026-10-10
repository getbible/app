import 'package:unorm_dart/unorm_dart.dart' as unicode;

import 'annotations.dart';
import 'public_topic.dart';
import 'service_envelopes.dart';

/// Only catalog labels are normalized. Scripture and saved quotations are never
/// transformed. This is the reference app's NFKD/mark/letter-number contract.
String normalizeBookmarkTopicName(String value) => unicode
    .nfkd(value)
    .replaceAll(RegExp(r'\p{M}', unicode: true), '')
    .toLowerCase()
    .replaceAll(RegExp(r'[^\p{L}\p{N}]', unicode: true), '');

enum BookmarkOrigin { personal, global }

final class BookmarkTopicMetadata {
  BookmarkTopicMetadata({
    required this.summary,
    Map<String, String> names = const {},
  }) : names = Map.unmodifiable(names);
  final PublicTopicSummary summary;
  final Map<String, String> names;
  String get id => summary.id;
  String nameFor(String language) {
    final locale = language.trim().toLowerCase().replaceAll('_', '-');
    return names[locale] ??
        names[locale.split('-').first] ??
        names['en'] ??
        summary.name;
  }

  bool matches(String query) {
    final needle = normalizeBookmarkTopicName(query);
    return [
      id,
      summary.name,
      ...summary.aliases,
      ...names.values,
    ].any((name) => normalizeBookmarkTopicName(name).contains(needle));
  }
}

/// One visible whole verse can retain both independent origins in storage.
/// Selected ranges remain separate, retaining their original text offsets.
final class BookmarkDisplayRow {
  BookmarkDisplayRow(Iterable<Marking> values)
    : markings = List.unmodifiable(values);
  final List<Marking> markings;
  bool get global => markings.any((mark) => mark.isSharedBookmark);
  bool get personal => markings.any((mark) => !mark.isSharedBookmark);
  Marking get marking => markings.reduce((left, right) {
    int preference(Marking value) =>
        (value.isSharedBookmark ? 0 : 2) + (value.quote.trim().isEmpty ? 0 : 1);
    return preference(right) > preference(left) ? right : left;
  });
}

List<BookmarkDisplayRow> bookmarkDisplayRows(Iterable<Marking> markings) {
  final rows = <String, List<Marking>>{};
  for (final mark in markings) {
    final key = mark.isWholeVerse
        ? '${mark.groupId}|${mark.passage.canonicalKey}|${mark.verse}'
        : 'range:${mark.id}';
    rows.putIfAbsent(key, () => []).add(mark);
  }
  return rows.values.map(BookmarkDisplayRow.new).toList()
    ..sort((left, right) => compareMarkings(left.marking, right.marking));
}

final class BookmarkReconciliation {
  BookmarkReconciliation({
    required this.groups,
    required this.markings,
    required this.groupIds,
  });
  final List<MarkingGroup> groups;
  final List<Marking> markings;
  final Map<String, String> groupIds;
}

/// Pure migration planning; the SQL adapter applies this against the latest
/// persisted snapshot inside one transaction. Explicit origins outrank names.
BookmarkReconciliation reconcileBookmarkGroups({
  required List<MarkingGroup> groups,
  required List<Marking> markings,
  required List<BookmarkTopicMetadata> topics,
  required String sourceScope,
  required String locale,
  required DateTime now,
}) {
  final byId = {for (final topic in topics) topic.id: topic};
  if (byId.length != topics.length) {
    throw const FormatException('Duplicate public topic IDs.');
  }
  BookmarkTopicMetadata? match(MarkingGroup group) {
    if (group.source case final source?) {
      return source.effectiveScope == sourceScope ? byId[source.topicId] : null;
    }
    // Unscoped historical ids belong to the official service only.
    if (sourceScope != SharedBookmarkSource.defaultScope) return null;
    if (group.id.startsWith('getbible-topic:')) {
      return byId[group.id.substring('getbible-topic:'.length)];
    }
    if (byId[group.id] case final direct?) return direct;
    final name = normalizeBookmarkTopicName(group.name);
    if (name.isEmpty) return null;
    final canonical = topics
        .where(
          (topic) => [
            topic.summary.name,
            ...topic.names.values,
          ].any((label) => normalizeBookmarkTopicName(label) == name),
        )
        .toList();
    if (canonical.isNotEmpty) {
      return canonical.length == 1 ? canonical.single : null;
    }
    final aliases = topics
        .where(
          (topic) => topic.summary.aliases.any(
            (label) => normalizeBookmarkTopicName(label) == name,
          ),
        )
        .toList();
    return aliases.length == 1 ? aliases.single : null;
  }

  final matches = <String, List<MarkingGroup>>{};
  for (final group in groups) {
    final topic = match(group);
    if (topic != null) matches.putIfAbsent(topic.id, () => []).add(group);
  }
  final used = groups.map((group) => group.id).toSet();
  final replacements = <String, MarkingGroup>{};
  final fresh = <MarkingGroup>[];
  for (final topic in topics) {
    var candidates = matches[topic.id] ?? <MarkingGroup>[];
    // Two independent personal groups with the same label are not evidence of
    // one identity. Keep both intact instead of silently discarding metadata.
    final personal = candidates
        .where(
          (group) =>
              group.source == null && !group.id.startsWith('getbible-topic:'),
        )
        .toList();
    if (personal.length > 1) {
      candidates = candidates
          .where(
            (group) =>
                group.source != null || group.id.startsWith('getbible-topic:'),
          )
          .toList();
    }
    final existing =
        candidates
            .where((group) => !group.id.startsWith('getbible-topic:'))
            .firstOrNull ??
        candidates.firstOrNull;
    String id = existing?.id ?? 'getbible-topic:${topic.id}';
    if (existing == null) {
      final base = id;
      var suffix = 1;
      while (!used.add(id)) {
        id = '$base:${suffix++}';
      }
    }
    final linked = MarkingGroup(
      id: id,
      name: existing?.name ?? topic.nameFor(locale),
      color: existing?.color ?? topic.summary.color.toUpperCase(),
      sortOrder: existing?.sortOrder ?? groups.length + fresh.length,
      isStarter: existing?.isStarter ?? false,
      updatedAt: existing?.updatedAt ?? now,
      source: SharedBookmarkSource(
        topicId: topic.id,
        sourceScope: sourceScope == SharedBookmarkSource.defaultScope
            ? null
            : sourceScope,
      ),
    );
    for (final group in candidates) {
      replacements[group.id] = linked;
    }
    if (existing == null) fresh.add(linked);
  }
  final next = <MarkingGroup>[];
  final seen = <String>{};
  final ids = <String, String>{};
  for (final group in groups) {
    final target = replacements[group.id] ?? group;
    ids[group.id] = target.id;
    if (seen.add(target.id)) next.add(target);
  }
  next.addAll(fresh);
  final globalIdentities = <String>{};
  final nextMarks = <Marking>[];
  for (final marking in markings) {
    final target = ids[marking.groupId] ?? marking.groupId;
    final migrated = marking.copyWith(groupId: target);
    final origin = migrated.sharedSource;
    final identity =
        '${origin?.effectiveScope}|${origin?.topicId}|${migrated.identity}';
    if (origin != null && !globalIdentities.add(identity)) continue;
    nextMarks.add(migrated);
  }
  return BookmarkReconciliation(
    groups: next,
    markings: nextMarks,
    groupIds: ids,
  );
}

BookmarkTopicMetadata metadataOf(PublicTopic topic) => BookmarkTopicMetadata(
  summary: PublicTopicSummary(
    id: topic.id,
    name: topic.name,
    color: topic.color,
    aliases: topic.aliases,
    isDefault: topic.isDefault,
    verseCount: topic.coordinates.length,
    source: const {},
  ),
  names: topic.names,
);
