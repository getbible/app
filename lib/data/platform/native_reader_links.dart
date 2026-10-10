import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/foundation.dart';

/// Capture cold and warm native links before database initialization starts.
/// Browsers use Router's platform route information and history instead.
final class NativeReaderLinks extends ChangeNotifier {
  NativeReaderLinks() {
    if (!kIsWeb) {
      _links = AppLinks();
      _subscription = _links!.uriLinkStream.listen(
        _receive,
        onError: (Object error) {
          // Retain a visible routing error rather than silently opening a default.
          _receive(Uri(path: '/invalid-native-link'));
        },
      );
    }
  }
  AppLinks? _links;
  StreamSubscription<Uri>? _subscription;
  Uri? latest;
  bool _closed = false;

  Future<Uri?> initial() async {
    if (_links == null) return null;
    final uri = await _links!.getInitialLink();
    if (_closed) return null;
    latest ??= uri;
    return latest;
  }

  void _receive(Uri uri) {
    if (_closed) return;
    latest = uri;
    notifyListeners();
  }

  @override
  void dispose() {
    _closed = true;
    unawaited(_subscription?.cancel());
    super.dispose();
  }
}
