import 'dart:async';

import 'package:flutter/foundation.dart';

import '../domain/models/private_backup.dart';
import '../domain/repositories/private_data_repository.dart';
import '../services/backup_service.dart';

/// Coordinates explicit export and preview/confirmed merge. File selection and
/// platform sharing stay outside this controller and are independently testable.
final class PortabilityController extends ChangeNotifier {
  PortabilityController({
    required this.repository,
    this.beforeSnapshot,
    this.afterImport,
  });
  final PrivateDataRepository repository;
  final Future<void> Function()? beforeSnapshot;
  final Future<void> Function()? afterImport;
  bool _busy = false;
  bool _disposed = false;
  bool _closing = false;
  Future<void>? _activeOperation;
  String? _error;
  PrivateBackup? _preparedImport;
  PrivateImportResult? _importResult;
  bool get busy => _busy;
  String? get error => _error;
  PrivateBackup? get preparedImport => _preparedImport;
  PrivateImportResult? get importResult => _importResult;

  Future<void> prepareImport(String source) async {
    if (_busy || _disposed) return;
    _preparedImport = null;
    _importResult = null;
    await _run<void>(() async {
      final PrivateBackup backup = await compute(decodePrivateBackup, source);
      if (!_disposed) _preparedImport = backup;
    });
  }

  void clearImport() {
    if (_busy || _disposed) return;
    _preparedImport = null;
    _importResult = null;
    _error = null;
    notifyListeners();
  }

  Future<void> confirmImport() async {
    final PrivateBackup? backup = _preparedImport;
    if (backup == null || _busy || _disposed) return;
    await _run<void>(() async {
      await beforeSnapshot?.call();
      final PrivateImportResult result = await repository.importBackup(backup);
      if (!_disposed) {
        _importResult = result;
        _preparedImport = null;
      }
      try {
        await afterImport?.call();
      } catch (_) {
        // The transaction already committed. Do not misreport a failed import
        // and encourage retries when only the open reader failed to refresh.
        if (!_disposed) {
          _error =
              'The backup was imported. Reopen the reader to refresh its saved data.';
        }
      }
    });
  }

  Future<String?> exportComplete() => _run<String>(() async {
    await beforeSnapshot?.call();
    final PrivateBackup snapshot = await repository.snapshot();
    return compute(encodePrivateBackup, snapshot);
  });

  Future<String?> exportWebsite() => _run<String>(() async {
    await beforeSnapshot?.call();
    final PrivateBackup snapshot = await repository.snapshot();
    return compute(encodeBackup, snapshot.reader);
  });

  Future<T?> _run<T>(Future<T> Function() operation) async {
    if (_busy || _disposed || _closing) return null;
    _busy = true;
    final Completer<void> completion = Completer<void>();
    _activeOperation = completion.future;
    _error = null;
    notifyListeners();
    try {
      return await operation();
    } catch (error) {
      if (!_disposed) {
        _error = error is FormatException
            ? error.message
            : 'The private data operation failed. Your saved data remains available. Please retry.';
      }
      return null;
    } finally {
      _busy = false;
      _activeOperation = null;
      completion.complete();
      if (!_disposed) notifyListeners();
    }
  }

  /// Application shutdown awaits this before closing the repository/database.
  /// Closing a visual panel alone does not cancel an already confirmed merge.
  Future<void> close() async {
    _closing = true;
    await _activeOperation;
  }

  /// A later notebook shutdown failure leaves the database open for Retry.
  void resume() {
    if (!_disposed) _closing = false;
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
