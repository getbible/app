import 'dart:convert';

import '../../core/json.dart';
import '../../core/request_cancellation.dart';
import '../../domain/models/dictionary.dart';
import '../api/dictionary_adapters.dart';
import 'bible_index_worker.dart';

/// Large online and installed indexes share the same off-thread parser. Web
/// uses the bundled worker, rather than Flutter compute's synchronous fallback.
/// Only bounded batches cross back to the UI; cancellation terminates parsing.
Future<DictionaryIndex> readDictionaryIndex(
  List<int> bytes,
  String module, {
  RequestCancellation? cancellation,
}) async {
  cancellation?.throwIfCancelled();
  if (bytes.length < 256 * 1024) {
    return DictionaryAdapters.index(
      jsonDecode(utf8.decode(bytes, allowMalformed: false)),
      module,
    );
  }
  JsonMap? header;
  final entries = <DictionaryIndexEntry>[];
  final normalized = <List<String>>[];
  await indexStudyInWorker(
    {'kind': 'dictionary-index', 'module': module, 'bytes': bytes},
    (batch) async {
      if (batch['header'] != null) {
        header = requireJsonMap(batch['header'], 'dictionary index header');
        return;
      }
      for (final value in requireJsonList(
        batch['entries'],
        'dictionary index entries',
      )) {
        final record = requireJsonMap(value, 'index entry');
        entries.add(
          DictionaryIndexEntry(
            id: requireString(record, 'id'),
            key: requireString(record, 'key'),
            search: requireString(record, 'search'),
            occurrence: record['occurrence'] as int? ?? 1,
            aliases: (record['aliases'] as List?)?.cast<String>() ?? const [],
          ),
        );
      }
      normalized.addAll(
        (batch['normalized']! as List).map(
          (value) => (value as List).cast<String>(),
        ),
      );
      await Future<void>.delayed(Duration.zero);
    },
    cancellation ?? RequestCancellation(),
  );
  if (header == null) {
    throw const FormatException(
      'The dictionary index worker returned incomplete data.',
    );
  }
  return DictionaryIndex(
    dictionary: requireString(header!, 'dictionary'),
    language: requireString(header!, 'language'),
    name: requireString(header!, 'name'),
    uniqueKeyCount: requireInt(header!, 'unique_key_count'),
    entries: entries,
    normalizedLookupKeys: normalized,
  );
}
