import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import '../../core/request_cancellation.dart';

@JS('document.baseURI')
external String get _documentBaseUri;

@JS('Worker')
extension type _Worker._(JSObject _) implements JSObject {
  external factory _Worker(String url);
  external set onmessage(JSFunction callback);
  external set onerror(JSFunction callback);
  external void postMessage(JSAny? message);
  external void terminate();
}

@JS()
extension type _Event._(JSObject _) implements JSObject {
  external JSAny? get data;
}

Future<void> indexOfflineInWorker(
  Map<String, Object?> input,
  Future<void> Function(Map<String, Object?>) receive,
  RequestCancellation cancellation,
) async {
  cancellation.throwIfCancelled();
  final worker = _Worker(
    Uri.parse(
      _documentBaseUri,
    ).resolve('offline_bible_worker.dart.js').toString(),
  );
  final done = Completer<void>();
  worker.onerror = ((JSAny? _) {
    if (!done.isCompleted) {
      done.completeError(
        const FormatException(
          'The offline resource worker could not run. Check that its bundled script is available.',
        ),
      );
    }
  }).toJS;
  worker.onmessage = ((_Event event) {
    if (done.isCompleted || cancellation.isCancelled) return;
    final value = Map<String, Object?>.from(event.data.dartify()! as Map);
    if (value['error'] case final String error) {
      done.completeError(FormatException(error));
      return;
    }
    if (value['done'] == true) {
      done.complete();
      return;
    }
    receive(value).then(
      (_) {
        if (!done.isCompleted && !cancellation.isCancelled) {
          worker.postMessage({'next': true}.jsify());
        }
      },
      onError: (Object error, StackTrace stack) {
        if (!done.isCompleted) done.completeError(error, stack);
      },
    );
  }).toJS;
  try {
    worker.postMessage(
      {
        ...input,
        'bytes': Uint8List.fromList((input['bytes']! as List).cast<int>()),
        if (input['indexBytes'] != null)
          'indexBytes': Uint8List.fromList(
            (input['indexBytes']! as List).cast<int>(),
          ),
      }.jsify(),
    );
    await cancellation.bind(done.future);
  } finally {
    worker.terminate();
  }
}
