import 'dart:convert';

import '../domain/models/backup.dart';

String encodeBackup(BackupData backup) =>
    const JsonEncoder.withIndent('  ').convert(backup.toJson());

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
