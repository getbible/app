import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../core/errors.dart';
import '../core/request_cancellation.dart';
import '../domain/models/offline_resource.dart';
import '../domain/repositories/offline_resource_repository.dart';

/// Keeps public resources ready offline without blocking the reader. One worker
/// validates and activates each generation; source-specific installers retain
/// ownership of manifests, exact-byte checks and bounded parsing/indexing.
final class OfflineController extends ChangeNotifier {
  OfflineController({
    required this.store,
    required List<OfflineResourceInstaller> installers,
    OfflineFreshnessStore? freshness,
    DateTime Function()? clock,
    this.clearPublicCaches,
    this.quotaBytes = 1024 * 1024 * 1024,
  }) : _installers = List.unmodifiable(installers),
       freshness = freshness ?? _MemoryFreshnessStore(),
       _clock = clock ?? DateTime.now;

  static const checkInterval = Duration(days: 30);
  static const initialRetryDelay = Duration(minutes: 15);
  static const maximumRetryDelay = Duration(days: 1);
  static const maximumQueuedResources = 512;

  final OfflineResourceStore store;
  final OfflineFreshnessStore freshness;
  final List<OfflineResourceInstaller> _installers;
  final DateTime Function() _clock;
  final Future<void> Function()? clearPublicCaches;
  final int quotaBytes;
  List<OfflineResourceDescriptor> catalog = const [];
  List<OfflineInstalledResource> installed = const [];
  List<OfflineInstallAttempt> attempts = const [];
  OfflineProgress? progress;
  int usedBytes = 0;
  bool loading = false;
  bool checking = false;
  bool _disposed = false;
  String? error;
  final Map<String, String> _failures = {};
  final Set<String> _excludedKeys = {};
  final Set<String> _removing = {};
  final Set<String> _suppressedUntilUse = {};
  final LinkedHashMap<String, _OfflineJob> _jobs = LinkedHashMap();
  // Admission remains bounded. Foreground work can displace a waiting automatic
  // job here, then the same worker re-admits it as soon as a slot opens.
  final LinkedHashMap<String, _OfflineJob> _deferredJobs = LinkedHashMap();
  final RequestOwner _discovery = RequestOwner();
  final RequestOwner _automaticDiscovery = RequestOwner();
  final Set<Future<void>> _pending = {};
  _OfflineJob? _active;
  Future<void>? _runner;
  Future<void>? _preferences;
  Future<void>? _updates;
  Future<void>? _clearFuture;
  Future<void> _controlTail = Future.value();
  bool _restoreAutomaticOnUse = false;
  int _workEpoch = 0;
  bool _closing = false;
  Future<void>? _closeFuture;

  /// Foreground reads capture this before I/O; Clear invalidates their callbacks.
  int get contentEpoch => _workEpoch;
  bool get closing => _closing;
  bool get installing => progress != null;
  bool get busy =>
      checking ||
      _jobs.isNotEmpty ||
      _deferredJobs.isNotEmpty ||
      _clearFuture != null;
  int get queuedCount =>
      _jobs.length + _deferredJobs.length - (_active == null ? 0 : 1);
  Set<String> get excludedKeys => Set.unmodifiable(_excludedKeys);
  Map<String, String> get failures => Map.unmodifiable(_failures);

  Future<void> initialize() => _track(() async {
    final epoch = _workEpoch;
    try {
      await _loadPreferences();
    } catch (failure) {
      error = _message(failure);
      _notify();
      return;
    }
    await _initialize();
    if (_canSchedule(epoch)) unawaited(checkForUpdates());
  });

  Future<void> _loadPreferences() => _preferences ??= () async {
    try {
      _excludedKeys.addAll(await freshness.readExcludedKeys());
    } catch (_) {
      _preferences = null;
      rethrow;
    }
  }();

  Future<void> _initialize() async {
    try {
      await _loadPreferences();
      _mergeCatalogue(await freshness.readAutomaticResources());
      await _refreshInstalled();
    } catch (failure) {
      error = _message(failure);
      _notify();
    }
  }

  Future<void> refreshInstalled() => _track(_initialize);

  void _mergeCatalogue(Iterable<OfflineResourceDescriptor> resources) {
    final merged = {for (final item in catalog) item.key: item};
    for (final resource in resources) {
      if (_matchesSource(resource)) merged[resource.key] = resource;
    }
    catalog = merged.values.toList()
      ..sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
    _notify();
  }

  Future<void> _refreshInstalled() async {
    await store.recoverInterrupted();
    installed = await store.listInstalled();
    attempts = await store.listAttempts();
    usedBytes = await store.usedBytes();
    _notify();
  }

  /// Catalogue browsing remains optional. Default Study preparation uses its
  /// own cancellable discovery, so opening this panel cannot interrupt it.
  Future<void> discover() => _track(_discover);

  Future<void> _discover() async {
    final request = _discovery.begin();
    loading = true;
    _notify();
    final found = <String, OfflineResourceDescriptor>{};
    final failures = <String>[];
    try {
      for (final installer in _installers) {
        try {
          final resources = await installer.discover(request);
          request.throwIfCancelled();
          for (final resource in resources) {
            _validateDescriptor(installer, resource);
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
        if (failures.isNotEmpty) error = failures.join('\n');
      }
    } on RequestCancelledException {
      // Retain the previous catalogue while a panel is dismissed.
    } finally {
      if (_discovery.owns(request)) {
        loading = false;
        _notify();
      }
    }
  }

  /// Used resources become durable automatically. Bookmarks are deliberately
  /// excluded: their complete public dataset is an explicit manager choice.
  Future<void> ensureAvailable(
    OfflineResourceKind kind,
    String id, {
    int? expectedEpoch,
  }) => _track(() async {
    final epoch = expectedEpoch ?? _workEpoch;
    if (kind == OfflineResourceKind.bookmarks || !_canSchedule(epoch)) return;
    try {
      await _loadPreferences();
      if (!_canSchedule(epoch)) return;
      final installer = _installer(kind);
      if (installer == null) return;
      final resource = OfflineResourceDescriptor(
        kind: kind,
        id: id,
        title: id,
        sourceUri: installer.sourceUri,
        revision: '',
      );
      _suppressedUntilUse.remove(resource.key);
      if (_restoreAutomaticOnUse) {
        _restoreAutomaticOnUse = false;
        unawaited(checkForUpdates());
      }
      await _enqueue(resource, priority: true);
    } catch (failure) {
      error = _message(failure);
      _notify();
    }
  });

  /// Rechecks source hashes, never blindly re-downloads unchanged bodies.
  /// Calls at startup, foreground resume and resource use provide the monthly
  /// cadence while the app is running; there is no operating-system daemon.
  Future<void> checkForUpdates({bool force = false}) {
    if (_closing || _disposed || _clearFuture != null) return Future.value();
    return _updates ??= _track(() async {
      checking = true;
      if (force) {
        _clearRevisionCaches();
        _suppressedUntilUse.clear();
      }
      _notify();
      final epoch = _workEpoch;
      try {
        await _loadPreferences();
        final known = await freshness.readAutomaticResources();
        if (!_canSchedule(epoch)) return;
        _mergeCatalogue(known);
        for (final resource in known) {
          if (_automatic(resource.kind) && _matchesSource(resource)) {
            unawaited(_enqueue(resource, force: force));
          }
        }
        final current = await store.listInstalled();
        if (!_canSchedule(epoch)) return;
        for (final item in current) {
          if (_matchesSource(item.resource)) {
            unawaited(_enqueue(item.resource, force: force));
          }
        }
        await _discoverAutomatic(force: force, epoch: epoch);
      } catch (failure) {
        error = _message(failure);
      } finally {
        checking = false;
        _updates = null;
        _notify();
      }
    });
  }

  Future<void> _discoverAutomatic({
    required bool force,
    required int epoch,
  }) async {
    final request = _automaticDiscovery.begin();
    for (final installer in _installers) {
      for (final kind in installer.supportedKinds.where(_automatic)) {
        if (!_canSchedule(epoch)) return;
        final key = 'catalogue|${installer.sourceUri}|${kind.name}';
        try {
          final status = await freshness.read(key);
          request.throwIfCancelled();
          if (!force && !_due(status, null)) continue;
          await _recordAttempt(key, status);
          final resources = await installer.discover(request);
          request.throwIfCancelled();
          for (final resource in resources) {
            _validateDescriptor(installer, resource);
            if (resource.kind != kind) {
              throw StateError('An automatic catalogue returned another kind.');
            }
          }
          await freshness.saveAutomaticResources(
            kind,
            installer.sourceUri,
            resources,
          );
          request.throwIfCancelled();
          await freshness.recordCatalogueSuccess(key, _clock().toUtc());
          if (!_canSchedule(epoch)) return;
          _mergeCatalogue(resources);
          for (final resource in resources) {
            unawaited(_enqueue(resource, force: force));
          }
          _succeeded(key);
        } on RequestCancelledException {
          return;
        } catch (failure) {
          _failed(key, failure);
        }
      }
    }
  }

  void _clearRevisionCaches() {
    for (final installer in _installers) {
      if (installer is OfflineRevisionCache) {
        (installer as OfflineRevisionCache).clearRevisionCache();
      }
    }
  }

  bool _canSchedule(int epoch) =>
      epoch == _workEpoch && !_closing && !_disposed && _clearFuture == null;

  bool _automatic(OfflineResourceKind kind) =>
      kind == OfflineResourceKind.dictionary ||
      kind == OfflineResourceKind.commentary;

  OfflineResourceInstaller? _installer(OfflineResourceKind kind) {
    for (final installer in _installers) {
      if (installer.supportedKinds.contains(kind)) return installer;
    }
    return null;
  }

  bool _matchesSource(OfflineResourceDescriptor resource) =>
      _installer(resource.kind)?.sourceUri == resource.sourceUri;

  void _validateDescriptor(
    OfflineResourceInstaller installer,
    OfflineResourceDescriptor resource,
  ) {
    if (!installer.supportedKinds.contains(resource.kind) ||
        resource.sourceUri != installer.sourceUri) {
      throw StateError('An installer returned a resource from another source.');
    }
  }

  /// Explicit catalogue installs also use the shared sequential worker. This
  /// action may install optional public bookmarks, unlike automatic preparation.
  Future<void> install(OfflineResourceDescriptor resource) => _track(
    () => _enqueue(
      resource,
      force: true,
      reinstall: true,
      explicit: true,
      priority: true,
    ),
  );

  Future<void> _enqueue(
    OfflineResourceDescriptor resource, {
    bool force = false,
    bool reinstall = false,
    bool explicit = false,
    bool priority = false,
  }) {
    if (_closing ||
        _disposed ||
        _clearFuture != null ||
        _removing.contains(resource.key) ||
        !explicit &&
            (_excludedKeys.contains(resource.key) ||
                _suppressedUntilUse.contains(resource.key))) {
      return Future.value();
    }
    final previous = _jobs[resource.key] ?? _deferredJobs[resource.key];
    if (previous != null) {
      previous.force |= force;
      previous.reinstall |= reinstall;
      previous.priority |= priority;
      if (priority && _deferredJobs.remove(resource.key) != null) {
        _admit(previous);
      }
      return previous.done.future;
    }
    final job = _OfflineJob(
      resource,
      force: force,
      reinstall: reinstall,
      priority: priority,
    );
    _admit(job);
    _notify();
    _runner ??= _track(_run);
    return job.done.future;
  }

  void _admit(_OfflineJob job) {
    if (_jobs.length >= maximumQueuedResources && job.priority) {
      final waiting = _jobs.values
          .where((item) => !item.priority && !identical(item, _active))
          .lastOrNull;
      if (waiting != null && _deferredJobs.length < maximumQueuedResources) {
        _jobs.remove(waiting.resource.key);
        _deferredJobs[waiting.resource.key] = waiting;
      }
    }
    if (_jobs.length < maximumQueuedResources) {
      _jobs[job.resource.key] = job;
    } else if (_deferredJobs.length < maximumQueuedResources) {
      _deferredJobs[job.resource.key] = job;
    } else {
      _failed(
        job.resource.key,
        const OfflineStorageException(
          'The offline preparation queue is full. Retry after current downloads finish.',
        ),
      );
      job.done.complete();
    }
  }

  void _admitDeferred() {
    if (_closing || _disposed || _clearFuture != null) return;
    while (_jobs.length < maximumQueuedResources && _deferredJobs.isNotEmpty) {
      final next = _nextJob(_deferredJobs);
      _deferredJobs.remove(next.resource.key);
      _jobs[next.resource.key] = next;
    }
  }

  _OfflineJob _nextJob(LinkedHashMap<String, _OfflineJob> queue) => queue.values
      .firstWhere((job) => job.priority, orElse: () => queue.values.first);

  Future<void> _run() async {
    try {
      while (_jobs.isNotEmpty && !_closing && !_disposed) {
        final job = _nextJob(_jobs);
        _active = job;
        try {
          await _prepare(job);
        } on RequestCancelledException {
          // Removal/shutdown owns cancellation; existing active data survives.
        } catch (failure) {
          _failed(job.resource.key, failure);
        } finally {
          _jobs.remove(job.resource.key);
          _active = null;
          if (!job.done.isCompleted) job.done.complete();
          _admitDeferred();
          _notify();
        }
      }
    } finally {
      _runner = null;
    }
  }

  Future<void> _prepare(_OfflineJob job) async {
    final resource = job.resource;
    final cancellation = job.cancellation;
    final installer = _installer(resource.kind);
    if (installer == null || installer.sourceUri != resource.sourceUri) {
      throw const OfflineStorageException(
        'This resource belongs to another source.',
      );
    }
    final current = await store.find(
      resource.kind,
      resource.id,
      resource.sourceUri,
    );
    final status = await freshness.read(resource.key);
    cancellation.throwIfCancelled();
    if (!job.force && !_due(status, current)) return;
    await _recordAttempt(resource.key, status);
    cancellation.throwIfCancelled();
    final resolved = job.reinstall
        ? resource
        : current == null
        ? await installer.resolve(resource.kind, resource.id, cancellation)
        : await installer.checkRevision(current.resource, cancellation);
    _validateDescriptor(installer, resolved);
    if (resolved.key != resource.key) {
      throw StateError('A revision check changed resource identity.');
    }
    cancellation.throwIfCancelled();
    if (!job.reinstall &&
        current != null &&
        resolved.revision.isNotEmpty &&
        current.resource.revision == resolved.revision) {
      await freshness.recordSuccess(
        resource.key,
        current.generation,
        _clock().toUtc(),
      );
      _succeeded(resource.key);
      return;
    }
    final generation = await _install(resolved, cancellation);
    cancellation.throwIfCancelled();
    if (generation != null) {
      await freshness.recordSuccess(resource.key, generation, _clock().toUtc());
      _succeeded(resource.key);
    }
  }

  bool _due(OfflineFreshness? status, OfflineInstalledResource? current) {
    final now = _clock().toUtc();
    if (status?.retryAfter case final retry? when retry.isAfter(now)) {
      return false;
    }
    final checked = current == null
        ? (status?.checkedGeneration == 'catalogue' ? status?.checkedAt : null)
        : status?.checkedGeneration == current.generation
        ? status?.checkedAt
        : current.installedAt;
    return checked == null || !now.isBefore(checked.add(checkInterval));
  }

  Future<void> _recordAttempt(String key, OfflineFreshness? previous) {
    var delay = initialRetryDelay;
    final lastAttempt = previous?.lastAttemptAt;
    final retry = previous?.retryAfter;
    if (lastAttempt != null && retry != null) {
      final doubled = retry.difference(lastAttempt).inMilliseconds * 2;
      delay = Duration(
        milliseconds: doubled.clamp(
          initialRetryDelay.inMilliseconds,
          maximumRetryDelay.inMilliseconds,
        ),
      );
    }
    final now = _clock().toUtc();
    return freshness.recordAttempt(key, now, now.add(delay));
  }

  Future<String?> _install(
    OfflineResourceDescriptor resource,
    RequestCancellation cancellation,
  ) async {
    final generation = const Uuid().v4();
    var began = false;
    Timer? heartbeat;
    progress = OfflineProgress(
      resourceKey: resource.key,
      completed: 0,
      total: null,
      label: 'Preparing download',
    );
    _notify();
    try {
      final installer = _installer(resource.kind)!;
      await store.begin(resource, generation, quotaBytes: quotaBytes);
      began = true;
      cancellation.throwIfCancelled();
      heartbeat = Timer.periodic(const Duration(seconds: 20), (_) {
        if (cancellation.isCancelled) return;
        _retain(
          store.heartbeat(generation).catchError((Object failure) {
            _failed(resource.key, failure);
            cancellation.cancel();
          }),
        );
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
      return generation;
    } catch (failure) {
      final cancelled = failure is RequestCancelledException;
      final message = cancelled
          ? 'Download cancelled. Existing installed data is unchanged.'
          : _message(failure);
      error = message;
      if (!cancelled) _failures[resource.key] = message;
      if (began) {
        try {
          await store.abandon(
            generation,
            cancelled
                ? OfflineAttemptState.cancelled
                : OfflineAttemptState.failed,
            message,
          );
        } catch (cleanupFailure) {
          _failed(resource.key, cleanupFailure);
        }
      }
      return null;
    } finally {
      heartbeat?.cancel();
      progress = null;
      try {
        await _refreshInstalled();
      } catch (failure) {
        _failed(resource.key, failure);
      }
      _notify();
    }
  }

  void _failed(String key, Object failure) {
    error = _message(failure);
    _failures[key] = error!;
    _notify();
  }

  void _succeeded(String key) {
    _failures.remove(key);
    error = _failures.isEmpty ? null : _failures.values.last;
    _notify();
  }

  void cancel() => _active?.cancellation.cancel();

  Future<void> setAutomaticDownload(
    OfflineResourceDescriptor resource,
    bool enabled,
  ) => _control(() async {
    if (!_automatic(resource.kind) || !_matchesSource(resource)) return;
    try {
      await _loadPreferences();
      await freshness.setExcluded(resource.key, !enabled);
      if (enabled) {
        _excludedKeys.remove(resource.key);
        _suppressedUntilUse.remove(resource.key);
        _notify();
        unawaited(_enqueue(resource, force: true, priority: true));
      } else {
        _excludedKeys.add(resource.key);
        await _remove(resource.key);
      }
      _notify();
    } catch (failure) {
      _failed(resource.key, failure);
    }
  });

  Future<void> remove(String resourceKey) =>
      _control(() => _remove(resourceKey));

  Future<void> _remove(String resourceKey) async {
    _suppressedUntilUse.add(resourceKey);
    _removing.add(resourceKey);
    try {
      await _cancelJob(resourceKey);
      await store.remove(resourceKey);
      await freshness.remove(resourceKey);
      _failures.remove(resourceKey);
      await _refreshInstalled();
      _succeeded(resourceKey);
    } catch (failure) {
      _failed(resourceKey, failure);
    } finally {
      _removing.remove(resourceKey);
    }
  }

  Future<void> _cancelJob(String key) async {
    final job = _jobs[key] ?? _deferredJobs[key];
    if (job == null) return;
    job.cancellation.cancel();
    if (!identical(job, _active)) {
      _jobs.remove(key);
      _deferredJobs.remove(key);
      job.done.complete();
    }
    await job.done.future;
  }

  /// Clear only public downloaded content. Exclusions and private records stay
  /// intact. The next use/startup resumes defaults; optional bookmarks stay gone.
  Future<void> clearDownloads() {
    if (_closing || _disposed) return Future.value();
    if (_clearFuture != null) return _clearFuture!;
    _workEpoch++;
    _automaticDiscovery.cancel();
    _discovery.cancel();
    _clearRevisionCaches();
    loading = false;
    return _clearFuture = _control(() async {
      try {
        final keys = [..._jobs.keys, ..._deferredJobs.keys];
        for (final job in [..._jobs.values, ..._deferredJobs.values]) {
          job.cancellation.cancel();
        }
        for (final key in keys) {
          await _cancelJob(key);
        }
        await _updates;
        final resources = await store.listInstalled();
        final attempts = await store.listAttempts();
        for (final key in {
          ...resources.map((r) => r.resource.key),
          ...attempts.map((a) => a.resource.key),
        }) {
          await store.remove(key);
        }
        await freshness.clear();
        await clearPublicCaches?.call();
        _failures.clear();
        error = null;
        _restoreAutomaticOnUse = true;
        await _refreshInstalled();
      } catch (failure) {
        error = _message(failure);
      } finally {
        _clearFuture = null;
        _notify();
      }
    });
  }

  /// User preferences and deletion commands retain their invocation order.
  /// Downloads themselves do not hold this lock, so clear can cancel immediately.
  Future<void> _control(Future<void> Function() operation) {
    if (_closing || _disposed) return Future.value();
    final previous = _controlTail;
    final complete = Completer<void>();
    _controlTail = complete.future;
    return _track(() async {
      await previous;
      try {
        await operation();
      } finally {
        complete.complete();
      }
    });
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

  /// Cancel public I/O and drain every owned DB operation before SQLite closes.
  Future<void> close() => _closeFuture ??= _close();
  Future<void> _close() async {
    _closing = true;
    _workEpoch++;
    _automaticDiscovery.cancel();
    _discovery.cancel();
    loading = false;
    for (final key in [..._jobs.keys, ..._deferredJobs.keys]) {
      unawaited(_cancelJob(key));
    }
    while (_pending.isNotEmpty) {
      await Future.wait(_pending.toList());
    }
  }

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
    _automaticDiscovery.cancel();
    _discovery.cancel();
    for (final key in [..._jobs.keys, ..._deferredJobs.keys]) {
      unawaited(_cancelJob(key));
    }
    super.dispose();
  }
}

final class _OfflineJob {
  _OfflineJob(
    this.resource, {
    required this.force,
    required this.reinstall,
    required this.priority,
  });
  final OfflineResourceDescriptor resource;
  bool force;
  bool reinstall;
  bool priority;
  final cancellation = RequestCancellation();
  final done = Completer<void>();
}

/// Keeps lightweight controller fixtures usable without a database. Production
/// composition supplies SqlOfflineFreshnessStore for durable checks/preferences.
final class _MemoryFreshnessStore implements OfflineFreshnessStore {
  final Map<String, OfflineFreshness> _records = {};
  final Set<String> _excluded = {};
  final Map<String, OfflineResourceDescriptor> _resources = {};
  @override
  Future<OfflineFreshness?> read(String key) async => _records[key];
  @override
  Future<void> recordAttempt(
    String key,
    DateTime at,
    DateTime retryAfter,
  ) async {
    final old = _records[key];
    _records[key] = OfflineFreshness(
      checkedGeneration: old?.checkedGeneration,
      checkedAt: old?.checkedAt,
      lastAttemptAt: at,
      retryAfter: retryAfter,
    );
  }

  @override
  Future<void> recordSuccess(String key, String generation, DateTime at) async {
    _records[key] = OfflineFreshness(
      checkedGeneration: generation,
      checkedAt: at,
    );
  }

  @override
  Future<void> recordCatalogueSuccess(String key, DateTime at) =>
      recordSuccess(key, 'catalogue', at);
  @override
  Future<void> remove(String key) async {
    _records.remove(key);
  }

  @override
  Future<void> clear() async {
    _records.clear();
  }

  @override
  Future<Set<String>> readExcludedKeys() async => Set.of(_excluded);
  @override
  Future<void> setExcluded(String key, bool excluded) async {
    if (excluded) {
      _excluded.add(key);
    } else {
      _excluded.remove(key);
    }
  }

  @override
  Future<List<OfflineResourceDescriptor>> readAutomaticResources() async =>
      _resources.values.toList();
  @override
  Future<void> saveAutomaticResources(
    OfflineResourceKind kind,
    Uri sourceUri,
    List<OfflineResourceDescriptor> resources,
  ) async {
    _resources.removeWhere(
      (_, value) => value.kind == kind && value.sourceUri == sourceUri,
    );
    _resources.addEntries(resources.map((r) => MapEntry(r.key, r)));
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
