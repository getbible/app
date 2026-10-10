import '../../core/json.dart';
import 'annotations.dart';
import 'preferences.dart';

final class BackupData {
  const BackupData({
    required this.version,
    required this.exportedAt,
    required this.groups,
    required this.markings,
    required this.notes,
    this.preferences,
  });

  factory BackupData.fromJson(Object? value) {
    final JsonMap json = requireJsonMap(value, 'getBible backup');
    final int version = requireInt(json, 'version');
    if (version != 1 && version != 2) {
      throw const FormatException(
        'This getBible backup version is not supported.',
      );
    }
    final List<MarkingGroup> groups = requireJsonList(
      json['colors'],
      'backup colors',
    ).map(MarkingGroup.fromJson).toList(growable: false);
    final Set<String> groupIds = groups
        .map((MarkingGroup item) => item.id)
        .toSet();
    if (groupIds.length != groups.length) {
      throw const FormatException(
        'The backup contains duplicate marking group IDs.',
      );
    }
    final List<Marking> markings = requireJsonList(
      json['markings'],
      'backup markings',
    ).map(Marking.fromJson).toList(growable: false);
    if (markings.any((Marking item) => !groupIds.contains(item.groupId))) {
      throw const FormatException(
        'A backup marking refers to a missing marking group.',
      );
    }
    final Object? notesValue = json['notes'];
    final List<VerseNote> notes = notesValue == null
        ? const <VerseNote>[]
        : requireJsonList(
            notesValue,
            'backup notes',
          ).map(VerseNote.fromJson).toList(growable: false);
    return BackupData(
      version: version,
      exportedAt: DateTime.parse(requireString(json, 'exportedAt')).toUtc(),
      groups: groups,
      markings: markings,
      notes: notes,
      preferences: json['preferences'] == null
          ? null
          : ReaderPreferences.fromJson(json['preferences']),
    );
  }

  final int version;
  final DateTime exportedAt;
  final List<MarkingGroup> groups;
  final List<Marking> markings;
  final List<VerseNote> notes;
  final ReaderPreferences? preferences;

  JsonMap toJson() => <String, Object?>{
    'version': 2,
    'exportedAt': exportedAt.toIso8601String(),
    'colors': groups
        .map((MarkingGroup item) => item.toJson(websiteCompatible: true))
        .toList(),
    'markings': markings
        .map((Marking item) => item.toJson(websiteCompatible: true))
        .toList(),
    'notes': notes.map((VerseNote item) => item.toJson()).toList(),
    if (preferences != null) 'preferences': preferences!.toJson(),
    'source': <String, Object?>{
      'application': 'getBible',
      'schemaVersion': 1,
    },
  };
}

List<MarkingGroup> mergeMarkingGroups(
  List<MarkingGroup> current,
  List<MarkingGroup> imported,
) {
  final Map<String, MarkingGroup> merged = <String, MarkingGroup>{
    for (final MarkingGroup item in current) item.id: item,
  };
  for (final MarkingGroup item in imported) {
    merged.putIfAbsent(item.id, () => item);
  }
  return merged.values.toList()..sort(
    (MarkingGroup left, MarkingGroup right) =>
        left.sortOrder.compareTo(right.sortOrder),
  );
}

List<Marking> mergeMarkings(List<Marking> current, List<Marking> imported) {
  final Set<String> identities = current
      .map((Marking item) => item.identity)
      .toSet();
  final Set<String> ids = current.map((Marking item) => item.id).toSet();
  final List<Marking> merged = List<Marking>.from(current);
  for (final Marking item in imported) {
    if (identities.contains(item.identity)) continue;
    String id = item.id;
    int suffix = 1;
    while (ids.contains(id)) {
      id = '${item.id}-imported-${suffix++}';
    }
    final Marking next = id == item.id ? item : item.copyWith(id: id);
    merged.add(next);
    identities.add(next.identity);
    ids.add(next.id);
  }
  return merged..sort(compareMarkings);
}

List<VerseNote> mergeNotes(List<VerseNote> current, List<VerseNote> imported) {
  final Map<String, VerseNote> merged = <String, VerseNote>{
    for (final VerseNote item in current) item.canonicalKey: item,
  };
  for (final VerseNote item in imported) {
    final VerseNote? existing = merged[item.canonicalKey];
    if (existing == null || item.updatedAt.isAfter(existing.updatedAt)) {
      merged[item.canonicalKey] = item;
    }
  }
  final List<VerseNote> ordered = merged.values.toList()..sort(compareNotes);
  // A lower canonical coordinate must never let an imported collision take a
  // local note's stable ID. Reserve ownership before ordering the result.
  final Map<String, String> owners = <String, String>{
    for (final VerseNote item in current)
      if (merged[item.canonicalKey]?.id == item.id) item.id: item.canonicalKey,
  };
  for (final VerseNote item in ordered) {
    owners.putIfAbsent(item.id, () => item.canonicalKey);
  }
  // Protect even later-sorted original IDs from generated -imported-N suffixes.
  final Set<String> reserved = <String>{
    ...current.map((VerseNote item) => item.id),
    ...ordered.map((VerseNote item) => item.id),
  };
  return <VerseNote>[
    for (final VerseNote item in ordered)
      if (owners[item.id] == item.canonicalKey)
        item
      else
        item.copyWith(id: _uniqueImportedId(item.id, reserved)),
  ];
}

String _uniqueImportedId(String source, Set<String> ids) {
  int suffix = 1;
  String id;
  do {
    id = '$source-imported-${suffix++}';
  } while (ids.contains(id));
  ids.add(id);
  return id;
}

BackupData mergeBackupData(BackupData current, BackupData imported) =>
    mergeReaderBackup(current, imported).data;

/// Remapping is part of the merge result so preferences and copy provenance
/// follow the same group identity as their annotations.
final class ReaderBackupMerge {
  const ReaderBackupMerge(this.data, this.importedGroupIds);
  final BackupData data;
  final Map<String, String> importedGroupIds;
}

ReaderBackupMerge mergeReaderBackup(BackupData current, BackupData imported) {
  final List<MarkingGroup> groups = List<MarkingGroup>.from(current.groups);
  final Set<String> ids = groups.map((MarkingGroup item) => item.id).toSet();
  final Map<String, String> importedGroupIds = <String, String>{};

  for (final MarkingGroup importedGroup in imported.groups) {
    // Labels and colors are user-editable, so equality never makes unrelated
    // stable group IDs interchangeable. Reuse only the original ID or a prior
    // collision-renamed copy of this same imported identity.
    final String collisionPrefix = '${importedGroup.id}-imported-';
    final MarkingGroup? identical = groups
        .where(
          (MarkingGroup item) =>
              (item.id == importedGroup.id ||
                  (ids.contains(importedGroup.id) &&
                      item.id.startsWith(collisionPrefix) &&
                      RegExp(
                        r'^[1-9][0-9]*$',
                      ).hasMatch(item.id.substring(collisionPrefix.length)))) &&
              item.name == importedGroup.name &&
              item.color.toUpperCase() == importedGroup.color.toUpperCase() &&
              item.source?.topicId == importedGroup.source?.topicId &&
              item.source?.effectiveScope ==
                  importedGroup.source?.effectiveScope,
        )
        .firstOrNull;
    if (identical != null) {
      importedGroupIds[importedGroup.id] = identical.id;
      continue;
    }
    String id = importedGroup.id;
    int suffix = 1;
    while (ids.contains(id)) {
      id = '${importedGroup.id}-imported-${suffix++}';
    }
    final MarkingGroup next = importedGroup.copyWith(
      id: id,
      sortOrder: groups.length,
    );
    groups.add(next);
    ids.add(id);
    importedGroupIds[importedGroup.id] = id;
  }

  final List<Marking> importedMarkings = imported.markings
      .map(
        (Marking item) => item.copyWith(
          groupId: importedGroupIds[item.groupId] ?? item.groupId,
        ),
      )
      .toList(growable: false);
  return ReaderBackupMerge(
    BackupData(
      version: 2,
      exportedAt: DateTime.now().toUtc(),
      groups: groups,
      markings: mergeMarkings(current.markings, importedMarkings),
      notes: mergeNotes(current.notes, imported.notes),
      preferences: imported.preferences == null
          ? current.preferences
          : imported.preferences!.copyWith(
              activeMarkingGroupId:
                  importedGroupIds[imported
                      .preferences!
                      .activeMarkingGroupId] ??
                  imported.preferences!.activeMarkingGroupId,
            ),
    ),
    Map<String, String>.unmodifiable(importedGroupIds),
  );
}
