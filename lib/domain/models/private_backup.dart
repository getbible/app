import 'dart:convert';

import '../../core/json.dart';
import 'annotations.dart';
import 'backup.dart';
import 'notebook.dart';
import 'preferences.dart';

const int maxPrivateBackupBytes = 64 * 1024 * 1024;
const int maxPrivateBackupRecords = 100000;
const String privateBackupFormat = 'getbible-private-backup';

/// A complete private snapshot, separate from the website's v1/v2 contract.
/// Public caches and installed resources are deliberately absent.
final class PrivateBackup {
  PrivateBackup({
    required this.reader,
    Iterable<Notebook> notebooks = const <Notebook>[],
    Iterable<NotebookDraft> drafts = const <NotebookDraft>[],
    Iterable<PrivateSetting> settings = const <PrivateSetting>[],
    this.isLegacy = false,
  }) : notebooks = List<Notebook>.unmodifiable(notebooks),
       drafts = List<NotebookDraft>.unmodifiable(drafts),
       settings = List<PrivateSetting>.unmodifiable(settings) {
    validate();
  }

  factory PrivateBackup.fromJson(Object? value) {
    final JsonMap json = requireJsonMap(value, 'private backup');
    if (!json.containsKey('format')) {
      return PrivateBackup(reader: BackupData.fromJson(json), isLegacy: true);
    }
    if (json['format'] != privateBackupFormat || json['version'] != 1) {
      throw const FormatException(
        'This complete backup format is not supported.',
      );
    }
    return PrivateBackup(
      reader: BackupData.fromJson(json['reader']),
      notebooks: _boundedList(
        json['notebooks'],
        'notebooks',
      ).map(Notebook.fromJson),
      drafts: _boundedList(json['drafts'], 'drafts').map(privateDraftFromJson),
      settings: _boundedList(
        json['settings'],
        'settings',
      ).map(PrivateSetting.fromJson),
    );
  }

  final BackupData reader;
  final List<Notebook> notebooks;
  final List<NotebookDraft> drafts;
  final List<PrivateSetting> settings;
  final bool isLegacy;

  int get recordCount =>
      reader.groups.length +
      reader.markings.length +
      reader.notes.length +
      notebooks.length +
      drafts.length +
      settings.length +
      notebooks.fold<int>(0, (int n, Notebook item) => n + item.blocks.length) +
      drafts.fold<int>(
        0,
        (int n, NotebookDraft item) => n + item.notebook.blocks.length,
      );

  void validate() {
    if (recordCount > maxPrivateBackupRecords) {
      throw const FormatException(
        'The backup exceeds 100,000 private records.',
      );
    }
    _unique(
      reader.groups.map((MarkingGroup item) => item.id),
      'marking groups',
    );
    _unique(reader.markings.map((Marking item) => item.id), 'markings');
    _unique(reader.notes.map((VerseNote item) => item.id), 'verse notes');
    _unique(
      reader.notes.map((VerseNote item) => item.canonicalKey),
      'canonical verse notes',
    );
    _unique(notebooks.map((Notebook item) => item.id), 'notebooks');
    _unique(
      notebooks.expand(
        (Notebook item) => item.blocks.map((NotebookBlock block) => block.id),
      ),
      'notebook blocks',
    );
    _unique(
      drafts.map(
        (NotebookDraft item) => '${item.notebook.id}/${item.editorId}',
      ),
      'draft journals',
    );
    _unique(settings.map((PrivateSetting item) => item.key), 'settings');
    for (final MarkingGroup group in reader.groups) {
      if (group.id.isEmpty ||
          group.updatedAt.millisecondsSinceEpoch < 0 ||
          !RegExp(r'^#[0-9a-fA-F]{6}$').hasMatch(group.color)) {
        throw const FormatException('A backup marking group is invalid.');
      }
    }
    for (final Marking marking in reader.markings) {
      marking.passage.validated();
      if (marking.id.isEmpty ||
          marking.verse < 1 ||
          marking.passage.chapter < 1 ||
          marking.createdAt.millisecondsSinceEpoch < 0) {
        throw const FormatException(
          'A backup marking has invalid coordinates or timestamps.',
        );
      }
    }
    for (final VerseNote note in reader.notes) {
      note.passage.validated();
      if (note.id.isEmpty ||
          note.verse < 1 ||
          note.passage.chapter < 1 ||
          note.createdAt.millisecondsSinceEpoch < 0 ||
          note.updatedAt.isBefore(note.createdAt)) {
        throw const FormatException(
          'A backup verse note has invalid coordinates or timestamps.',
        );
      }
    }
    final Set<String> groupIds = reader.groups
        .map((MarkingGroup item) => item.id)
        .toSet();
    if (reader.markings.any(
      (Marking item) => !groupIds.contains(item.groupId),
    )) {
      throw const FormatException(
        'A backup marking refers to a missing group.',
      );
    }
    for (final NotebookDraft draft in drafts) {
      validatePrivateDraft(draft);
    }
    final Set<String> notebookIds = <String>{
      ...notebooks.map((Notebook item) => item.id),
      ...drafts.map((NotebookDraft item) => item.notebook.id),
    };
    for (final PrivateSetting setting in settings) {
      setting.validate();
      if (setting.isTopicCopy &&
          !groupIds.contains(
            requireString(
              requireJsonMap(setting.value, 'topic copy'),
              'groupId',
            ),
          )) {
        throw const FormatException(
          'A private topic copy refers to a missing group.',
        );
      }
      if (setting.key == 'notebooks:v1:selected' &&
          !notebookIds.contains(setting.value)) {
        throw const FormatException(
          'The selected notebook is absent from the backup.',
        );
      }
    }
  }

  JsonMap toJson() => <String, Object?>{
    'format': privateBackupFormat,
    'version': 1,
    'reader': <String, Object?>{
      ...reader.toJson(),
      // Website export intentionally omits these app-local group properties.
      // Complete portability retains their exact saved ordering and timestamps.
      'colors': reader.groups
          .map(
            (MarkingGroup item) => <String, Object?>{
              ...item.toJson(websiteCompatible: true),
              'sortOrder': item.sortOrder,
              'isStarter': item.isStarter,
              'updatedAt': item.updatedAt.millisecondsSinceEpoch,
            },
          )
          .toList(),
    },
    'notebooks': notebooks.map((Notebook item) => item.toJson()).toList(),
    'drafts': drafts.map(privateDraftToJson).toList(),
    'settings': settings.map((PrivateSetting item) => item.toJson()).toList(),
  };
}

/// Only known private settings cross the portability boundary. An imported
/// file cannot insert cache state, an installation record, or arbitrary keys.
final class PrivateSetting {
  PrivateSetting({
    required this.key,
    required Object? value,
    required this.updatedAt,
  }) : value = _freezePrivateJson(value) {
    validate();
  }
  factory PrivateSetting.fromJson(Object? value) {
    final JsonMap json = requireJsonMap(value, 'private setting');
    return PrivateSetting(
      key: requireString(json, 'key'),
      value: json['value'],
      updatedAt: DateTime.fromMillisecondsSinceEpoch(
        requireInt(json, 'updatedAt'),
        isUtc: true,
      ),
    );
  }
  final String key;
  final Object? value;
  final DateTime updatedAt;
  bool get isTopicCopy =>
      key.startsWith('topic-copy:v1:') ||
      key.startsWith('topic-copy-alternate:v1:');

  static bool isPortableKey(String key) =>
      key == 'readerPreferences' ||
      key == 'lastReadingPosition' ||
      key == 'notebooks:v1:selected' ||
      key == 'bookmarks:v1:recent' ||
      key.startsWith('study:v1:dictionary:') ||
      key.startsWith('study:v1:commentary:') ||
      key.startsWith('study:v1:topic-followed:') ||
      key.startsWith('study:v1:topic-hidden:') ||
      key.startsWith('topic-copy:v1:') ||
      key.startsWith('topic-copy-alternate:v1:');

  void validate() {
    if (!isPortableKey(key) ||
        key.length > 4096 ||
        updatedAt.millisecondsSinceEpoch < 0) {
      throw const FormatException(
        'The backup contains an invalid private setting.',
      );
    }
    if (key == 'readerPreferences') {
      final JsonMap json = requireJsonMap(value, 'reader preferences');
      if (json['version'] != 1) {
        throw const FormatException('Unsupported reader preferences.');
      }
      ReaderPreferences.fromJson(json);
    } else if (key == 'lastReadingPosition') {
      final JsonMap json = requireJsonMap(value, 'reading position');
      final LastReadingPosition position = LastReadingPosition.fromJson(json);
      if (json['version'] != 1 ||
          position.verse < 1 ||
          position.updatedAt.millisecondsSinceEpoch < 0) {
        throw const FormatException('The saved reading position is invalid.');
      }
    } else if (key == 'bookmarks:v1:recent') {
      if (value is! List ||
          (value! as List).length > 6 ||
          (value! as List).any(
            (item) => item is! String || item.isEmpty || item.length > 4096,
          )) {
        throw const FormatException('Invalid recent bookmark topics.');
      }
    } else if (isTopicCopy) {
      final JsonMap json = requireJsonMap(value, 'topic copy provenance');
      if (json['version'] != 1 || requireString(json, 'groupId').isEmpty) {
        throw const FormatException('Invalid topic copy provenance.');
      }
      if (key.startsWith('topic-copy-alternate:') &&
          !requireString(json, 'provenanceKey').startsWith('topic-copy:v1:')) {
        throw const FormatException('Invalid alternate topic copy provenance.');
      }
    } else if (key.startsWith('study:v1:topic-')) {
      if (value is! bool) {
        throw const FormatException('A topic choice must be true or false.');
      }
    } else if (value is! String ||
        (value! as String).length > 4096 ||
        (value! as String).isEmpty) {
      throw const FormatException('The private preference value is invalid.');
    }
    if (key != 'readerPreferences' &&
        key != 'lastReadingPosition' &&
        key != 'notebooks:v1:selected' &&
        key != 'bookmarks:v1:recent') {
      final List<String> parts = key.split(':');
      final int expected = key.startsWith('study:v1:dictionary:')
          ? 5
          : key.startsWith('study:')
          ? 4
          : 3;
      if (parts.length != expected ||
          parts
              .skip(key.startsWith('study:') ? 3 : 2)
              .any((String item) => item.isEmpty)) {
        throw const FormatException(
          'A scoped private preference key is invalid.',
        );
      }
      for (final String part in parts.skip(key.startsWith('study:') ? 3 : 2)) {
        Uri.decodeComponent(part);
      }
    }
  }

  JsonMap toJson() => <String, Object?>{
    'key': key,
    'value': value,
    'updatedAt': updatedAt.millisecondsSinceEpoch,
  };
}

Object? _freezePrivateJson(Object? value) {
  if (value == null || value is String || value is bool || value is num) {
    return value;
  }
  if (value is Map<String, Object?>) {
    return Map<String, Object?>.unmodifiable(
      value.map(
        (String key, Object? item) => MapEntry(key, _freezePrivateJson(item)),
      ),
    );
  }
  if (value is List<Object?>) {
    return List<Object?>.unmodifiable(value.map(_freezePrivateJson));
  }
  throw const FormatException(
    'A private setting contains an unsupported value.',
  );
}

void validatePrivateDraft(NotebookDraft draft) {
  if (!RegExp(r'^[a-zA-Z0-9_-]{1,128}$').hasMatch(draft.editorId) ||
      (draft.baseRevision != null &&
          (draft.baseRevision! < 1 ||
              draft.baseRevision! >= draft.notebook.revision))) {
    throw const FormatException(
      'A retained notebook draft has an invalid owner or base revision.',
    );
  }
}

NotebookDraft privateDraftFromJson(Object? value) {
  final JsonMap json = requireJsonMap(value, 'draft journal');
  final NotebookDraft draft = NotebookDraft(
    notebook: Notebook.fromJson(json['notebook']),
    baseRevision: json['baseRevision'] == null
        ? null
        : requireInt(json, 'baseRevision'),
    editorId: requireString(json, 'editorId'),
  );
  validatePrivateDraft(draft);
  return draft;
}

JsonMap privateDraftToJson(NotebookDraft draft) => <String, Object?>{
  'notebook': draft.notebook.toJson(),
  'baseRevision': draft.baseRevision,
  'editorId': draft.editorId,
};

PrivateBackup decodePrivateBackup(String source) {
  if (source.length > maxPrivateBackupBytes ||
      utf8.encode(source).length > maxPrivateBackupBytes) {
    throw const FormatException('A private backup is limited to 64 MiB.');
  }
  return PrivateBackup.fromJson(jsonDecode(source));
}

String encodePrivateBackup(PrivateBackup backup) {
  backup.validate();
  final String output = const JsonEncoder.withIndent(
    '  ',
  ).convert(backup.toJson());
  if (utf8.encode(output).length > maxPrivateBackupBytes) {
    throw const FormatException(
      'The complete backup exceeds the 64 MiB file limit.',
    );
  }
  return output;
}

List<Object?> _boundedList(Object? value, String label) {
  final List<Object?> items = requireJsonList(value, label);
  if (items.length > maxPrivateBackupRecords) {
    throw FormatException('Too many $label.');
  }
  return items;
}

void _unique(Iterable<String> identities, String label) {
  final Set<String> seen = <String>{};
  if (identities.any((String value) => !seen.add(value))) {
    throw FormatException('The backup contains duplicate $label.');
  }
}

final class PrivateImportResult {
  const PrivateImportResult({
    required this.groupsAdded,
    required this.markingsAdded,
    required this.notesChanged,
    required this.notebooksAdded,
    required this.draftsAdded,
    required this.notebookConflicts,
    required this.settingsRestored,
  });
  final int groupsAdded;
  final int markingsAdded;
  final int notesChanged;
  final int notebooksAdded;
  final int draftsAdded;
  final int notebookConflicts;
  final int settingsRestored;
}
