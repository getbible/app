import '../models/private_backup.dart';

abstract interface class PrivateDataRepository {
  Future<PrivateBackup> snapshot();

  /// Validates before opening the transaction and re-reads local data inside it.
  /// Imports merge; they never reset or erase unrelated private records.
  Future<PrivateImportResult> importBackup(PrivateBackup backup);
}
