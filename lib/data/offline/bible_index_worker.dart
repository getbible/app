import '../../core/request_cancellation.dart';
import 'bible_index_worker_native.dart'
    if (dart.library.js_interop) 'bible_index_worker_web.dart'
    as platform;

/// The same validating processor runs in a native isolate or a real Web Worker.
/// Cancelling terminates that worker even during JSON decoding or validation.
Future<void> indexBibleInWorker(
  List<int> bytes,
  String abbreviation,
  String expectedSha,
  Future<void> Function(Map<String, Object?>) receive,
  RequestCancellation cancellation,
) => platform.indexOfflineInWorker(
  {
    'operation': 'bible',
    'bytes': bytes,
    'abbreviation': abbreviation,
    'sha': expectedSha,
  },
  receive,
  cancellation,
);

Future<void> indexStudyInWorker(
  Map<String, Object?> input,
  Future<void> Function(Map<String, Object?>) receive,
  RequestCancellation cancellation,
) => platform.indexOfflineInWorker(
  {...input, 'operation': 'study'},
  receive,
  cancellation,
);
