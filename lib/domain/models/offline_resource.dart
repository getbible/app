import '../../core/json.dart';

enum OfflineResourceKind { bible, dictionary, commentary, bookmarks }

/// A public resource is scoped to its exact configured service root. Installed
/// data from one host can never silently answer requests against another host.
final class OfflineResourceDescriptor {
  OfflineResourceDescriptor({
    required this.kind,
    required this.id,
    required this.title,
    required this.sourceUri,
    required this.revision,
    this.estimatedBytes,
    this.attribution = '',
  }) {
    if (id.isEmpty ||
        id.length > 256 ||
        title.isEmpty ||
        title.length > 1000 ||
        !['https', 'http'].contains(sourceUri.scheme) ||
        sourceUri.host.isEmpty ||
        sourceUri.hasQuery ||
        sourceUri.hasFragment ||
        sourceUri.userInfo.isNotEmpty ||
        sourceUri.toString().length > 2048 ||
        attribution.length > 65536 ||
        revision.length > 256 ||
        (estimatedBytes != null && estimatedBytes! < 0)) {
      throw ArgumentError('Invalid offline resource identity.');
    }
  }

  factory OfflineResourceDescriptor.fromJson(Object? value) {
    final json = requireJsonMap(value, 'offline resource');
    return OfflineResourceDescriptor(
      kind: OfflineResourceKind.values.byName(requireString(json, 'kind')),
      id: requireString(json, 'id'),
      title: requireString(json, 'title'),
      sourceUri: Uri.parse(requireString(json, 'sourceUri')),
      revision: requireString(json, 'revision'),
      estimatedBytes: json['estimatedBytes'] as int?,
      attribution: optionalString(json, 'attribution'),
    );
  }

  final OfflineResourceKind kind;
  final String id;
  final String title;
  final Uri sourceUri;
  final String revision;
  final int? estimatedBytes;
  final String attribution;
  String get key =>
      '${kind.name}|${sourceUri.toString().replaceFirst(RegExp(r'/+$'), '')}|${Uri.encodeComponent(id)}';
  JsonMap toJson() => {
    'kind': kind.name,
    'id': id,
    'title': title,
    'sourceUri': sourceUri.toString(),
    'revision': revision,
    'estimatedBytes': estimatedBytes,
    'attribution': attribution,
  };
}

final class OfflineInstalledResource {
  const OfflineInstalledResource({
    required this.resource,
    required this.generation,
    required this.installedAt,
    required this.byteCount,
  });
  final OfflineResourceDescriptor resource;
  final String generation;
  final DateTime installedAt;

  /// Logical persisted UTF-8 payload and index bytes, excluding SQLite overhead.
  final int byteCount;
}

final class OfflineSearchVerse {
  const OfflineSearchVerse({
    required this.book,
    required this.chapter,
    required this.verse,
    required this.bookName,
    required this.direction,
    required this.verseJson,
    required this.text,
    required this.normalizedText,
  });
  final int book;
  final int chapter;
  final int verse;
  final String bookName;
  final String direction;
  final String verseJson;
  final String text;
  final String normalizedText;
}

enum OfflineAttemptState { running, cancelled, interrupted, failed }

final class OfflineInstallAttempt {
  const OfflineInstallAttempt({
    required this.resource,
    required this.state,
    required this.message,
    required this.updatedAt,
  });
  final OfflineResourceDescriptor resource;
  final OfflineAttemptState state;
  final String message;
  final DateTime updatedAt;
}

final class OfflineProgress {
  const OfflineProgress({
    required this.resourceKey,
    required this.completed,
    required this.total,
    required this.label,
    this.bytes = 0,
  });
  final String resourceKey;
  final int completed;
  final int? total;
  final String label;
  final int bytes;
  double? get fraction =>
      total != null && total! > 0 ? (completed / total!).clamp(0.0, 1.0) : null;
}

final class OfflineStorageException implements Exception {
  const OfflineStorageException(this.message, [this.cause]);
  final String message;
  final Object? cause;
  @override
  String toString() => message;
}
