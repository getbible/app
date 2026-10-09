import '../../domain/models/private_backup.dart';
import '../../domain/repositories/private_data_repository.dart';
import '../database/local_database.dart';

final class SqlPrivateDataRepository implements PrivateDataRepository {
  const SqlPrivateDataRepository(this.database);
  final LocalDatabase database;
  @override
  Future<PrivateBackup> snapshot() => database.privateSnapshot();
  @override
  Future<PrivateImportResult> importBackup(PrivateBackup backup) =>
      database.importPrivateBackup(backup);
}
