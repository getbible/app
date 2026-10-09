import 'dart:async';
import 'dart:isolate';

import '../../core/request_cancellation.dart';
import 'offline_index_processor.dart';

Future<void> indexOfflineInWorker(
  Map<String, Object?> input,
  Future<void> Function(Map<String, Object?>) receive,
  RequestCancellation cancellation,
) async {
  cancellation.throwIfCancelled();
  final events = ReceivePort();
  final Isolate isolate;
  try {
    isolate = await Isolate.spawn(
      _run,
      (events.sendPort, input),
      onError: events.sendPort,
      onExit: events.sendPort,
      errorsAreFatal: true,
    );
  } catch (_) {
    events.close();
    rethrow;
  }
  final iterator = StreamIterator<dynamic>(events);
  try {
    SendPort? control;
    while (await cancellation.bind(iterator.moveNext())) {
      final event = iterator.current;
      if (event == null) {
        throw StateError(
          'The resource worker stopped before installation completed.',
        );
      }
      if (event is List) {
        throw StateError('The resource worker failed: ${event.first}');
      }
      if (event is SendPort) {
        control = event;
        control.send(true);
      } else {
        final value = Map<String, Object?>.from(event as Map);
        if (value['error'] case final String error) {
          throw FormatException(error);
        }
        if (value['done'] == true) break;
        await cancellation.bind(receive(value));
        control!.send(true);
      }
    }
  } finally {
    isolate.kill(priority: Isolate.immediate);
    events.close();
    await iterator.cancel();
  }
}

void _run((SendPort, Map<String, Object?>) input) async {
  final commands = ReceivePort();
  input.$1.send(commands.sendPort);
  try {
    final batches = indexOfflineSource(input.$2).iterator;
    await for (final _ in commands) {
      if (!batches.moveNext()) {
        input.$1.send({'done': true});
        break;
      }
      input.$1.send(batches.current);
    }
  } catch (error) {
    input.$1.send({'error': error.toString()});
  } finally {
    commands.close();
  }
}
