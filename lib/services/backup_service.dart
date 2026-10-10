import 'dart:convert';

import '../domain/models/annotations.dart';
import '../domain/models/backup.dart';

/// The reference website only models its official bookmark provider. Exporting
/// a foreign origin there could silently merge it into an official membership.
final class WebsiteBackupScopeException extends FormatException {
  const WebsiteBackupScopeException()
    : super(
        'This backup contains bookmarks from another provider. Export a complete private backup to preserve their source.',
      );
}

String encodeBackup(BackupData backup) {
  final sources = <SharedBookmarkSource?>[
    ...backup.groups.map((group) => group.source),
    ...backup.markings.map((marking) => marking.sharedSource),
  ];
  if (sources.any(
    (source) =>
        source != null &&
        source.effectiveScope != SharedBookmarkSource.defaultScope,
  )) {
    throw const WebsiteBackupScopeException();
  }
  return const JsonEncoder.withIndent('  ').convert(backup.toJson());
}

BackupData decodeBackup(String source) {
  try {
    return BackupData.fromJson(jsonDecode(source));
  } on FormatException {
    rethrow;
  } catch (error) {
    throw FormatException(
      'The selected file is not a valid getBible backup.',
      error,
    );
  }
}
