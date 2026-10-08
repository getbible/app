import 'dart:async';

import 'errors.dart';

/// A request's logical lifetime, independent of the lifetime of a shared client.
/// Cancelling a request never closes the HTTP client used by other requests.
final class RequestCancellation {
  final Completer<void> _cancelled = Completer<void>();

  bool get isCancelled => _cancelled.isCompleted;
  Future<void> get whenCancelled => _cancelled.future;

  void cancel() {
    if (!isCancelled) _cancelled.complete();
  }

  void throwIfCancelled() {
    if (isCancelled) throw const RequestCancelledException();
  }

  Future<T> bind<T>(Future<T> operation) {
    throwIfCancelled();
    return Future.any<T>(<Future<T>>[
      operation,
      whenCancelled.then<T>((_) => throw const RequestCancelledException()),
    ]);
  }
}

/// The most recent interaction owns the response. Begin again on input changes,
/// and cancel on dismissal/disposal so a late response cannot update visible UI.
final class RequestOwner {
  RequestCancellation? _current;

  RequestCancellation begin() {
    cancel();
    return _current = RequestCancellation();
  }

  bool owns(RequestCancellation request) =>
      identical(_current, request) && !request.isCancelled;

  void cancel() {
    _current?.cancel();
    _current = null;
  }
}
