import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import '../../services/text_file_service.dart';

@JS('navigator')
external JSObject get _navigator;

Future<TextShareResult> shareBrowserText(String text, String subject) async {
  final JSAny? share = _navigator.getProperty<JSAny?>('share'.toJS);
  if (share == null || !share.typeofEquals('function')) {
    return TextShareResult.unsupported;
  }
  try {
    final JSAny? result = (share as JSFunction).callAsFunction(
      _navigator,
      <String, String>{'title': subject, 'text': text}.jsify(),
    );
    await (result as JSPromise<JSAny?>).toDart;
    return TextShareResult.completed;
  } catch (error) {
    // Browser cancellation is a normal outcome, not a successful share.
    if (_isCancellation(error)) {
      return TextShareResult.cancelled;
    }
    throw const TextFileException(
      'Sharing could not be completed. Save or copy the text instead.',
    );
  }
}

bool _isCancellation(Object error) {
  try {
    return (error as JSObject).getProperty<JSAny?>('name'.toJS)?.dartify() ==
        'AbortError';
  } catch (_) {
    return false;
  }
}
