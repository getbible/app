import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../core/errors.dart';
import '../core/request_cancellation.dart';
import '../domain/models/offline_resource.dart';
import '../domain/repositories/offline_resource_repository.dart';

/// Coordinates explicitly requested installations. Builders own source formats;
/// this coordinator owns visibility, cancellation, quota and recovery.
final class OfflineController extends ChangeNotifier {
  OfflineController({
    required this.store,
    required List<OfflineResourceInstaller> installers,
    this.quotaBytes = 1024 * 1024 * 1024,
  }) : _installers = List.unmodifiable(installers);
  final OfflineResourceStore store;
  final List<OfflineResourceInstaller> _installers;
  final int quotaBytes;
  List<OfflineResourceDescriptor> catalog = const [];
  List<OfflineInstalledResource> installed = const [];
  List<OfflineInstallAttempt> attempts = const [];
  OfflineProgress? progress;
  int usedBytes = 0;
  bool loading = false;
  bool _disposed = false;
  String? error;
  RequestCancellation? _installation;
  final RequestOwner _discovery = RequestOwner();
  final Set<Future<void>> _pending = {};
  bool _closing = false;
  Future<void>? _closeFuture;
  bool get closing => _closing;
  bool get installing => _installation != null;

  Future<void> initialize() => _track(_initialize);

  Future<void> _initialize() async {
    try {
      await _refreshInstalled();
    } catch (failure) {
      error = _message(failure);
      _notify();
    }
  }

  Future<void> refreshInstalled() => _track(_initialize);

  Future<void> _refreshInstalled() async {
    await store.recoverInterrupted();
    installed = await store.listInstalled();
    attempts = await store.listAttempts();
    usedBytes = await store.usedBytes();
    _notify();
  }

  /// Each catalogue is independent: a missing Study server must not hide a
  /// available Bible catalogue or already installed resources.
  Future<void> discover() => _track(_discover);

  Future<void> _discover() async {
    final request = _discovery.begin();
    loading = true;
    error = null;
    _notify();
    final found = <String, OfflineResourceDescriptor>{};
    final failures = <String>[];
    try {
      for (final installer in _installers) {
        try {
          final resources = await installer.discover(request);
          request.throwIfCancelled();
          for (final resource in resources) {
            if (!installer.supportedKinds.contains(resource.kind)) {
              throw StateError(
                'An installer returned an unsupported resource.',
              );
            }
            found[resource.key] = resource;
          }
        } on RequestCancelledException {
          rethrow;
        } catch (failure) {
          failures.add(_message(failure));
        }
      }
      if (_discovery.owns(request)) {
        catalog = found.values.toList()
          ..sort(
            (a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()),
          );
        error = failures.isEmpty ? null : failures.join('\n');
      }
    } on RequestCancelledException {
      // The previous catalogue remains useful after dismissing discovery.
    } finally {
      if (_discovery.owns(request)) {
        loading = false;
        _notify();
      }
    }
  }

  Future<void> install(OfflineResourceDescriptor resource) {
    if (installing || _closing || _disposed) return Future.value();
    final cancellation = RequestCancellation();
    _installation = cancellation;
    return _track(() => _install(resource, cancellation));
  }

  Future<void> _install(
    OfflineResourceDescriptor resource,
    RequestCancellation cancellation,
  ) async {
    final generation = const Uuid().v4();
    var began = false;
    Timer? heartbeat;
    error = null;
    progress = OfflineProgress(
      resourceKey: resource.key,
      completed: 0,
      total: null,
      label: 'Preparing download',
    );
    _notify();
    try {
      final installer = _installers.firstWhere(
        (item) => item.supportedKinds.contains(resource.kind),
      );
      await store.begin(resource, generation, quotaBytes: quotaBytes);
      began = true;
      cancellation.throwIfCancelled();
      heartbeat = Timer.periodic(const Duration(seconds: 20), (_) {
        if (cancellation.isCancelled) return;
        final beat = store.heartbeat(generation).catchError((Object failure) {
          error = _message(failure);
          cancellation.cancel();
        });
        _retain(beat);
      });
      final sink = _InstallSink(
        store: store,
        generation: generation,
        resourceKey: resource.key,
        quotaBytes: quotaBytes,
        cancellation: cancellation,
        onProgress: (value) {
          progress = value;
          _notify();
        },
      );
      await installer.install(resource, sink, cancellation);
      cancellation.throwIfCancelled();
      await store.activate(generation);
    } catch (failure) {
      final cancelled = failure is RequestCancelledException;
      error = cancelled
          ? 'Download cancelled. Existing installed data is unchanged.'
          : _message(failure);
      if (began) {
        try {
          await store.abandon(
            generation,
            cancelled
                ? OfflineAttemptState.cancelled
                : OfflineAttemptState.failed,
            error!,
          );
        } catch (cleanupFailure) {
          error =
              '$error Temporary download cleanup could not finish: ${_message(cleanupFailure)}';
        }
      }
    } finally {
      heartbeat?.cancel();
      _installation = null;
      progress = null;
      try {
        await _refreshInstalled();
      } catch (failure) {
        error = _message(failure);
      }
      _notify();
    }
  }

  void cancel() => _installation?.cancel();

  Future<void> remove(String resourceKey) => _track(() => _remove(resourceKey));

  Future<void> _remove(String resourceKey) async {
    if (installing) return;
    error = null;
    try {
      await store.remove(resourceKey);
      await _refreshInstalled();
    } catch (failure) {
      error = _message(failure);
      _notify();
    }
  }

  Future<void> _track(Future<void> Function() operation) {
    if (_closing || _disposed) return Future.value();
    final future = operation();
    _retain(future);
    return future;
  }

  void _retain(Future<void> future) {
    _pending.add(future);
    unawaited(
      future.then(
        (_) {
          _pending.remove(future);
        },
        onError: (Object _, StackTrace _) {
          _pending.remove(future);
        },
      ),
    );
  }

  /// Stop new work, cancel public I/O, then drain every owned DB operation
  /// before AppState closes its shared database.
  Future<void> close() => _closeFuture ??= _close();
  Future<void> _close() async {
    _closing = true;
    _discovery.cancel();
    loading = false;
    cancel();
    while (_pending.isNotEmpty) {
      await Future.wait(_pending.toList());
    }
  }

  /// A later private-journal failure can abort application shutdown. Reopen the
  /// gate without automatically restarting any download or network discovery.
  void resume() {
    if (_disposed) return;
    _closing = false;
    _closeFuture = null;
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _discovery.cancel();
    cancel();
    super.dispose();
  }
}

final class _InstallSink implements OfflineInstallSink {
  _InstallSink({
    required this.store,
    required this.generation,
    required this.resourceKey,
    required this.quotaBytes,
    required this.cancellation,
    required this.onProgress,
  });
  final OfflineResourceStore store;
  final String generation;
  final String resourceKey;
  final int quotaBytes;
  final RequestCancellation cancellation;
  final ValueChanged<OfflineProgress> onProgress;
  int _bytes = 0;

  @override
  Future<void> setVerifiedDescriptor(OfflineResourceDescriptor resource) async {
    cancellation.throwIfCancelled();
    if (resource.key != resourceKey) {
      throw ArgumentError('An installer cannot change resource identity.');
    }
    await store.updateDescriptor(generation, resource);
  }

  @override
  Future<void> writeDocument(
    String path,
    String rawJson, {
    String? sha256,
    String? sha1,
  }) async {
    cancellation.throwIfCancelled();
    if (rawJson.length > 8 * 1024 * 1024) {
      throw const OfflineStorageException(
        'A source document exceeds the 8 MiB installation limit.',
      );
    }
    if (sha256 != null || sha1 != null) {
      final bytes = utf8.encode(rawJson);
      if (sha256 != null &&
              await _digest(crypto.sha256, bytes) != sha256.toLowerCase() ||
          sha1 != null &&
              await _digest(crypto.sha1, bytes) != sha1.toLowerCase()) {
        throw const ApiFormatException(
          'Downloaded source bytes failed integrity verification. The existing installation is unchanged.',
        );
      }
    }
    cancellation.throwIfCancelled();
    _bytes += await store.writeDocument(
      generation,
      path,
      rawJson,
      quotaBytes: quotaBytes,
    );
    await Future<void>.delayed(Duration.zero);
  }

  Future<String> _digest(crypto.Hash hash, List<int> bytes) async {
    final output = _DigestSink();
    final input = hash.startChunkedConversion(output);
    for (var index = 0; index < bytes.length; index += 64 * 1024) {
      cancellation.throwIfCancelled();
      input.add(
        bytes.sublist(index, (index + 64 * 1024).clamp(0, bytes.length)),
      );
      await Future<void>.delayed(Duration.zero);
    }
    input.close();
    return output.value!.toString();
  }

  @override
  Future<void> writeDocuments(Map<String, String> documents) async {
    cancellation.throwIfCancelled();
    _bytes += await store.writeDocuments(
      generation,
      documents,
      quotaBytes: quotaBytes,
    );
    await Future<void>.delayed(Duration.zero);
  }

  @override
  Future<void> writeSearchVerses(List<OfflineSearchVerse> verses) async {
    cancellation.throwIfCancelled();
    _bytes += await store.writeSearchVerses(
      generation,
      verses,
      quotaBytes: quotaBytes,
    );
    await Future<void>.delayed(Duration.zero);
  }

  @override
  void progress(int completed, int? total, String label) {
    cancellation.throwIfCancelled();
    if (completed < 0 || total != null && (total < 0 || completed > total)) {
      throw ArgumentError('Invalid installation progress.');
    }
    onProgress(
      OfflineProgress(
        resourceKey: resourceKey,
        completed: completed,
        total: total,
        label: label,
        bytes: _bytes,
      ),
    );
  }
}

final class _DigestSink implements Sink<crypto.Digest> {
  crypto.Digest? value;
  @override
  void add(crypto.Digest data) {
    value = data;
  }

  @override
  void close() {}
}

String _message(Object error) {
  if (error is StorageException && error.cause != null) {
    if (error.cause is OfflineStorageException) return error.cause.toString();
    return 'Local storage could not complete the download. Free device or browser storage and retry. Existing installed resources and private data are preserved.';
  }
  if (error is OfflineStorageException || error is AppException) {
    return error.toString();
  }
  return 'The offline resource could not be installed: $error';
}
