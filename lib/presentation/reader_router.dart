import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../application/app_state.dart';
import '../domain/models/passage.dart';
import 'reader_screen.dart';

/// One persistent reader page owns native dialogs and drafts. URL changes load
/// through the same guarded application operation as Search and references.
final class ReaderRouter {
  ReaderRouter(this.state, {Uri? initialUri, bool initialize = false}) {
    final initial =
        initialUri?.toString() ??
        (state.current == null
            ? null
            : canonicalPassagePath(state.passage, state.current!.bookName));
    router = GoRouter(
      initialLocation: initial,
      overridePlatformDefaultLocation:
          initialUri != null || state.current != null,
      routes: [
        for (final path in [
          '/',
          '/:translation/:book/:chapter',
          '/:translation/:book/:chapter/:verse',
        ])
          GoRoute(path: path, pageBuilder: (_, route) => _page()),
      ],
      errorPageBuilder: (_, route) => _page(),
    );
    _observed = state.passage;
    router.routeInformationProvider.addListener(_routeChanged);
    state.addListener(_stateChanged);
    ready = _start(initialize);
  }
  final AppState state;
  late final GoRouter router;
  late final Future<void> ready;
  late Passage _observed;
  bool _ready = false;
  bool _internal = false;
  bool _disposed = false;
  int _routeRequest = 0;
  bool _handling = false;
  Uri? _lastLocation;

  static Page<void> _page() => const NoTransitionPage<void>(
    key: ValueKey('reader'),
    child: ReaderScreen(),
  );

  Future<void> _start(bool initialize) async {
    // Allow MaterialApp to install the router before any notification rebuilds.
    await Future<void>.delayed(Duration.zero);
    if (_disposed) return;
    final location = router.routeInformationProvider.value.uri;
    _lastLocation = location;
    _handling = true;
    if (initialize) {
      await state.initialize(initialUri: location);
    } else if (location.path != '/' && !_matchesCurrent(location)) {
      await state.openPassageLink(location);
    }
    _handling = false;
    if (_disposed) return;
    _ready = true;
    _observed = state.passage;
    final latest = router.routeInformationProvider.value.uri;
    if (latest != location) {
      await _navigate(latest);
    } else if (state.error == null) {
      _publish(replace: true);
    }
  }

  bool _matchesCurrent(Uri uri) =>
      state.current != null &&
      canonicalPassagePath(state.passage, state.current!.bookName) ==
          uri.toString();

  void openNative(Uri uri) {
    final location =
        readerLinkLocation(uri) ?? Uri(path: '/invalid-native-link');
    router.go(location.toString());
  }

  void _routeChanged() {
    if (_internal || !_ready || _disposed) return;
    final uri = router.routeInformationProvider.value.uri;
    if (_lastLocation == uri) return;
    _lastLocation = uri;
    unawaited(_navigate(uri));
  }

  Future<void> _navigate(Uri uri) async {
    final request = ++_routeRequest;
    final supersedesRoute = _handling;
    _handling = true;
    try {
      if (uri.path != '/' || uri.hasQuery) {
        if (!_matchesCurrent(uri) ||
            state.error != null ||
            state.loading ||
            supersedesRoute) {
          await state.openPassageLink(uri);
        }
      } else if (state.loading || supersedesRoute) {
        // Back to the root/current reader must supersede an older route load.
        // Otherwise its late result can replace Scripture beneath this URL.
        if (state.current != null) {
          await state.openPassageLink(
            Uri.parse(
              canonicalPassagePath(state.passage, state.current!.bookName),
            ),
          );
        } else {
          await state.openDailyScripture();
        }
      }
    } finally {
      if (!_disposed && request == _routeRequest) {
        // Only the latest route owns suppression. A slow, superseded request
        // must not stop later reader actions from updating browser history.
        _handling = false;
        _observed = state.passage;
        // Refused navigation must also restore the visible URL: the draft and
        // address bar must never describe different passages.
        if (state.error == null || state.readerNavigationBlocked) {
          _publish(replace: true);
        }
      }
    }
  }

  void _stateChanged() {
    if (!_ready ||
        _disposed ||
        _handling ||
        state.loading ||
        state.current == null ||
        state.error != null) {
      return;
    }
    if (_observed == state.passage) return;
    _observed = state.passage;
    _publish();
  }

  void _publish({bool replace = false}) {
    if (state.current == null) return;
    final path = canonicalPassagePath(state.passage, state.current!.bookName);
    if (router.routeInformationProvider.value.uri.toString() == path) return;
    _lastLocation = Uri.parse(path);
    _internal = true;
    // replace preserves the page key and avoids an extra browser history entry
    // when normalizing an inbound spelling or restoring a blocked URL.
    if (replace) {
      router.replace<void>(path);
    } else {
      router.go(path);
    }
    _internal = false;
  }

  void dispose() {
    _disposed = true;
    state.removeListener(_stateChanged);
    router.routeInformationProvider.removeListener(_routeChanged);
    router.dispose();
  }
}
