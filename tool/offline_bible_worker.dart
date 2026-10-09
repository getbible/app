import 'dart:js_interop';

import 'package:getbible_live/data/offline/offline_index_processor.dart';

@JS('self.onmessage')
external set onMessage(JSFunction callback);
@JS('self.postMessage')
external void postMessage(JSAny? message);

@JS()
extension type _Event._(JSObject _) implements JSObject {
  external JSAny? get data;
}

void main() {
  Iterator<Map<String, Object?>>? batches;
  onMessage = ((_Event event) {
    try {
      final input = Map<String, Object?>.from(event.data.dartify()! as Map);
      batches ??= indexOfflineSource(input).iterator;
      postMessage(
        (batches!.moveNext() ? batches!.current : {'done': true}).jsify(),
      );
    } catch (error) {
      postMessage({'error': error.toString()}.jsify());
    }
  }).toJS;
}
