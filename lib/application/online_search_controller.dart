import 'package:flutter/foundation.dart';

import '../core/errors.dart';
import '../core/request_cancellation.dart';
import '../domain/models/online_search.dart';
import '../domain/models/service_envelopes.dart';
import '../domain/repositories/search_repository.dart';

/// A revision change requires a new first page, rather than combining Scripture
/// from different source snapshots or different search-engine semantics.
final class SearchRevisionChangedException extends NetworkException {
  const SearchRevisionChangedException()
    : super(
        'The Bible or search engine changed. Restart this search to see consistent results.',
      );
}

/// Owns one interactive search independently from reader navigation. Online is
/// the default; installed execution requires an explicit source choice. Results
/// preserve repository ordering; only duplicate verse identities are skipped.
final class OnlineSearchController extends ChangeNotifier {
  OnlineSearchController({
    required this.repository,
    this.installedRepository,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final SearchRepository repository;
  final SearchRepository? installedRepository;
  SearchExecutionMode _mode = SearchExecutionMode.online;
  SearchExecutionMode get mode => _mode;
  bool get supportsInstalledSearch => installedRepository != null;
  final DateTime Function() _now;
  final RequestOwner _owner = RequestOwner();
  final List<OnlineSearchHit> _results = <OnlineSearchHit>[];
  final Set<String> _identities = <String>{};
  OnlineSearchRequest? _request;
  OnlineSearchPage? _firstPage;
  Object? _error;
  DateTime? _retryAt;
  DateTime? _servicePauseUntil;
  HttpStatusException? _servicePauseError;
  int _nextOffset = 0;
  bool _hasMore = false;
  bool _loading = false;
  bool _loadingMore = false;
  bool _disposed = false;

  List<OnlineSearchHit> get results =>
      List<OnlineSearchHit>.unmodifiable(_results);
  OnlineSearchRequest? get request => _request;
  SearchResultKind? get kind => _firstPage?.kind;
  int get total => _firstPage?.total ?? 0;
  Object? get error => _error;
  bool get isLoading => _loading;
  bool get isLoadingMore => _loadingMore;
  bool get requiresRestart => _error is SearchRevisionChangedException;
  bool get offsetLimitReached => _hasMore && _nextOffset > 10000;
  bool get canLoadMore => _hasMore && !offsetLimitReached && !requiresRestart;
  bool get canRetry =>
      _request != null &&
      !_loading &&
      !_loadingMore &&
      (_retryAt == null || !_now().isBefore(_retryAt!));
  DateTime? get retryAt => _retryAt;
  Duration? get retryDelay {
    final DateTime? retryAt = _retryAt;
    if (retryAt == null) return null;
    final Duration delay = retryAt.difference(_now());
    return delay.isNegative ? Duration.zero : delay;
  }

  int get nextOffset => _nextOffset;

  Future<void> search(
    String translation,
    String text, {
    OnlineSearchCriteria? criteria,
    int pageSize = 25,
    String direction = 'LTR',
    SearchExecutionMode mode = SearchExecutionMode.online,
  }) async {
    if (_disposed) return;
    // Even repeated effective inputs replace the previous interaction's token.
    clear();
    _mode = mode;
    try {
      _request = OnlineSearchRequest(
        translation: translation,
        text: text,
        criteria:
            criteria ??
            OnlineSearchCriteria(
              diacritics: mode == SearchExecutionMode.installed
                  ? SearchDiacritics.exact
                  : SearchDiacritics.fold,
            ),
        limit: pageSize,
        direction: direction,
      );
    } on FormatException catch (error) {
      _error = error;
      notifyListeners();
      return;
    }
    await _load(first: true);
  }

  Future<void> loadMore() async {
    if (!canLoadMore || _loading || _loadingMore || _error != null) return;
    await _load(first: false);
  }

  Future<void> retry() async {
    if (!canRetry) return;
    if (requiresRestart || _firstPage == null) {
      final OnlineSearchRequest request = _request!;
      await search(
        request.translation,
        request.text,
        criteria: request.criteria,
        pageSize: request.limit,
        direction: request.direction,
        mode: _mode,
      );
    } else {
      await _load(first: false);
    }
  }

  Future<void> _load({required bool first}) async {
    final OnlineSearchRequest? original = _request;
    if (original == null || _disposed) return;
    if (_mode == SearchExecutionMode.online &&
        _servicePauseUntil != null &&
        _now().isBefore(_servicePauseUntil!)) {
      // Retry-After applies to the service, not just the Retry button. Editing
      // filters, clearing the surface or submitting again cannot bypass it.
      _error = _servicePauseError;
      _retryAt = _servicePauseUntil;
      _loading = false;
      _loadingMore = false;
      notifyListeners();
      return;
    }
    if (_mode == SearchExecutionMode.online) {
      _servicePauseUntil = null;
      _servicePauseError = null;
    }
    final RequestCancellation token = _owner.begin();
    final OnlineSearchRequest pageRequest = first
        ? original
        : original.atOffset(_nextOffset);
    _error = null;
    _retryAt = null;
    _loading = first;
    _loadingMore = !first;
    notifyListeners();
    try {
      final selectedRepository = _mode == SearchExecutionMode.online
          ? repository
          : installedRepository;
      if (selectedRepository == null) {
        throw const FormatException(
          'Installed search is not available in this application.',
        );
      }
      final OnlineSearchPage page = await selectedRepository.search(
        pageRequest,
        cancellation: token,
      );
      if (!_owner.owns(token) || _disposed) return;
      final OnlineSearchPage? baseline = _firstPage;
      if (baseline != null &&
          (baseline.kind != page.kind ||
              baseline.engineVersion != page.engineVersion ||
              baseline.sourceSha != page.sourceSha ||
              baseline.total != page.total)) {
        throw const SearchRevisionChangedException();
      }
      _firstPage ??= page;
      for (final OnlineSearchHit hit in page.hits) {
        if (_identities.add(hit.identity)) _results.add(hit);
      }
      _nextOffset = page.nextOffset;
      _hasMore =
          page.kind == SearchResultKind.search &&
          page.hasMore &&
          page.returned > 0;
    } catch (error) {
      if (!_owner.owns(token) || _disposed) return;
      _error = error;
      if (error is HttpStatusException && error.retryAfter != null) {
        _retryAt = _now().add(error.retryAfter!);
        _servicePauseUntil = _retryAt;
        _servicePauseError = error;
      }
    } finally {
      if (_owner.owns(token) && !_disposed) {
        _loading = false;
        _loadingMore = false;
        notifyListeners();
      }
    }
  }

  /// Invalidates pending work on input changes or surface dismissal. Completed
  /// results remain available when the caller merely closes the surface.
  /// Widget lifecycle cleanup uses [notify] false while the tree is locked.
  void cancel({bool notify = true}) {
    _owner.cancel();
    _loading = false;
    _loadingMore = false;
    if (notify && !_disposed) notifyListeners();
  }

  /// Clears the query and invalidates pending results. Lifecycle-driven context
  /// replacement can opt out of notifications during an existing widget build.
  void clear({bool notify = true}) {
    _owner.cancel();
    _request = null;
    _firstPage = null;
    _results.clear();
    _identities.clear();
    _error = null;
    _retryAt = null;
    // Keep a server-requested pause independently from the current query.
    _nextOffset = 0;
    _hasMore = false;
    _loading = false;
    _loadingMore = false;
    if (notify && !_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _owner.cancel();
    super.dispose();
  }
}
