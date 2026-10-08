import 'package:flutter/foundation.dart';

import '../core/request_cancellation.dart';
import '../domain/models/reference.dart';
import 'grouped_reference_lookup.dart';

/// Owns preview requests and a bounded citation history, independently from the
/// reader's persisted position. Closing the surface invalidates late responses.
final class ReferencePreviewController extends ChangeNotifier {
  ReferencePreviewController({required this.lookup, this.historyLimit = 8}) {
    if (historyLimit < 1 || historyLimit > 32) {
      throw ArgumentError.value(
        historyLimit,
        'historyLimit',
        'Use 1 to 32 entries.',
      );
    }
  }

  final GroupedReferenceLookup lookup;
  final int historyLimit;
  final RequestOwner _owner = RequestOwner();
  final List<_PreviewSnapshot> _history = <_PreviewSnapshot>[];
  ReferenceRequest? _request;
  ReferenceResult? _result;
  Object? _error;
  bool _loading = false;
  bool _visible = false;

  ReferenceRequest? get request => _request;
  ReferenceResult? get result => _result;
  Object? get error => _error;
  bool get isLoading => _loading;
  bool get isVisible => _visible;
  bool get canGoBack => _history.isNotEmpty;
  int get historyLength => _history.length;

  Future<void> open(ReferenceRequest request) async {
    if (_request != null && _visible) {
      _history.add(_PreviewSnapshot(_request!, _result, _error));
      if (_history.length > historyLimit) _history.removeAt(0);
    }
    await _load(request);
  }

  Future<void> retry() async {
    final ReferenceRequest? request = _request;
    if (request != null) await _load(request);
  }

  Future<void> goBack() async {
    if (_history.isEmpty) return;
    _owner.cancel();
    final _PreviewSnapshot previous = _history.removeLast();
    if (previous.result == null && previous.error == null) {
      await _load(previous.request);
      return;
    }
    _request = previous.request;
    _result = previous.result;
    _error = previous.error;
    _loading = false;
    _visible = true;
    notifyListeners();
  }

  Future<void> _load(ReferenceRequest request) async {
    final RequestCancellation token = _owner.begin();
    _request = request;
    _result = null;
    _error = null;
    _loading = true;
    _visible = true;
    notifyListeners();
    try {
      final ReferenceResult result = await lookup.lookup(
        request,
        cancellation: token,
      );
      if (!_owner.owns(token)) return;
      _result = result;
    } catch (error) {
      if (!_owner.owns(token)) return;
      _error = error;
    } finally {
      if (_owner.owns(token)) {
        _loading = false;
        notifyListeners();
      }
    }
  }

  void close() {
    _owner.cancel();
    _history.clear();
    _request = null;
    _result = null;
    _error = null;
    _loading = false;
    _visible = false;
    notifyListeners();
  }

  @override
  void dispose() {
    _owner.cancel();
    super.dispose();
  }
}

final class _PreviewSnapshot {
  const _PreviewSnapshot(this.request, this.result, this.error);
  final ReferenceRequest request;
  final ReferenceResult? result;
  final Object? error;
}
