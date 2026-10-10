import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../../core/json.dart';
import '../../domain/models/public_topic.dart';
import '../api/commentary_adapter.dart';
import '../api/dictionary_adapters.dart';
import '../api/public_topic_adapter.dart';

/// Runs entirely in the installation worker. Exact downloaded bytes are hashed
/// before parsing; indexed documents are derived only from that verified body.
/// The worker waits for each bounded batch to reach staging before continuing.
Iterable<Map<String, Object?>> indexStudySource(
  Map<String, Object?> input,
) sync* {
  final bytes = (input['bytes']! as List).cast<int>();
  final digest = sha256.convert(bytes).toString();
  final kind = requireString(input, 'kind');
  if (kind != 'manifest' &&
      kind != 'dictionary-index' &&
      digest != input['sha256']) {
    throw const FormatException(
      'The Study download does not match its SHA-256 manifest.',
    );
  }
  final bulk = requireJsonMap(
    jsonDecode(utf8.decode(bytes, allowMalformed: false)),
    'complete Study resource',
  );
  if (kind == 'manifest') {
    final bookmarks = input['bookmarks'] == true;
    if (bookmarks
        ? requireInt(bulk, 'schema_version') != 1
        : requireString(bulk, 'schema') != 'getbible-hashes-v1' ||
              requireString(bulk, 'algorithm') != 'sha256') {
      throw const FormatException('Unsupported resource integrity manifest.');
    }
    final files = requireJsonMap(bulk['files'], 'manifest files');
    final selected = <String, String>{};
    for (final path in (input['paths']! as List).cast<String>()) {
      final hash = requireString(files, path);
      if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(hash)) {
        throw const FormatException('Invalid manifest SHA-256.');
      }
      selected[path] = hash;
    }
    // Cache only module-level fingerprints needed by this discovery batch.
    // An unrelated absent/malformed module cannot fail the requested resource.
    final optional = (input['optionalPaths'] as List? ?? const [])
        .cast<String>();
    if (optional.length > 4001) {
      throw const FormatException('Too many optional manifest paths.');
    }
    for (final path in optional) {
      final hash = files[path];
      if (hash is String && RegExp(r'^[a-f0-9]{64}$').hasMatch(hash)) {
        selected[path] = hash;
      }
    }
    yield {'manifest': selected, 'digest': digest};
    return;
  }
  if (kind == 'dictionary-index') {
    final index = DictionaryAdapters.index(
      bulk,
      requireString(input, 'module'),
    );
    yield {
      'header': {
        'dictionary': index.dictionary,
        'language': index.language,
        'name': index.name,
        'unique_key_count': index.uniqueKeyCount,
      },
    };
    final raw = requireJsonList(bulk['entries'], 'dictionary index entries');
    for (var start = 0; start < raw.length; start += 128) {
      final end = (start + 128).clamp(0, raw.length);
      yield {
        'entries': raw.sublist(start, end),
        'normalized': [for (var i = start; i < end; i++) index.lookupKeysAt(i)],
      };
    }
    return;
  }
  if (input['indexBytes'] != null) {
    final indexBytes = (input['indexBytes']! as List).cast<int>();
    if (sha256.convert(indexBytes).toString() != input['indexSha256']) {
      throw const FormatException(
        'The Study index does not match its integrity manifest.',
      );
    }
    input = {
      ...input,
      'index': jsonDecode(utf8.decode(indexBytes, allowMalformed: false)),
    };
  }
  final Iterable<MapEntry<String, Object?>> documents = switch (kind) {
    'dictionary' => _dictionary(input, bulk, bytes.length),
    'commentary' => _commentary(input, bulk, bytes.length),
    'bookmarks' => _topics(input, bulk),
    _ => throw const FormatException('Unknown Study installation type.'),
  };
  var batch = <String, String>{};
  var batchBytes = 0;
  for (final document in documents) {
    final encoded = jsonEncode(document.value);
    if (batch.isNotEmpty &&
        (batch.length >= 32 || batchBytes + encoded.length > 256 * 1024)) {
      yield {'documents': batch};
      batch = <String, String>{};
      batchBytes = 0;
    }
    if (batch.containsKey(document.key)) {
      throw const FormatException('Duplicate offline document.');
    }
    batch[document.key] = encoded;
    batchBytes += encoded.length;
  }
  if (batch.isNotEmpty) yield {'documents': batch};
}

Iterable<MapEntry<String, Object?>> _dictionary(
  JsonMap input,
  JsonMap bulk,
  int bytes,
) sync* {
  final module = requireString(input, 'module');
  _identity(bulk, 'getbible-dictionary-v1', 'dictionary', module);
  final metadata = DictionaryAdapters.metadata(input['metadata'], module);
  final index = DictionaryAdapters.index(input['index'], module);
  final rawEntries = requireJsonList(
    bulk['entries'],
    'complete dictionary entries',
  );
  if (metadata.bytes != bytes ||
      rawEntries.length != metadata.entryCount ||
      rawEntries.length != index.entries.length ||
      metadata.uniqueKeyCount != index.uniqueKeyCount ||
      metadata.language != index.language ||
      metadata.language != requireString(bulk, 'language') ||
      metadata.name != index.name ||
      metadata.name != requireString(bulk, 'name')) {
    throw const FormatException(
      'The complete dictionary disagrees with its metadata or index.',
    );
  }
  final uniqueKeys = <String>{};
  final ids = index.entries.map((entry) => entry.id).toSet();
  for (var i = 0; i < rawEntries.length; i++) {
    final indexed = index.entries[i];
    final entry = DictionaryAdapters.entry(rawEntries[i], module, indexed.id);
    if (entry.key != indexed.key ||
        entry.occurrence != indexed.occurrence ||
        entry.language != metadata.language ||
        indexed.aliases.any((alias) => !entry.aliases.contains(alias))) {
      throw const FormatException(
        'A dictionary entry disagrees with its published index.',
      );
    }
    for (final link in [...entry.seeAlso, ...entry.backlinks]) {
      if (!ids.contains(link.id)) {
        throw const FormatException('A dictionary link has no indexed entry.');
      }
    }
    uniqueKeys.add(entry.key);
    yield MapEntry(
      'entries/${Uri.encodeComponent(entry.id)}.json',
      rawEntries[i],
    );
  }
  if (uniqueKeys.length != metadata.uniqueKeyCount) {
    throw const FormatException(
      'Dictionary unique-key count does not match the complete module.',
    );
  }
  yield MapEntry('index.json', input['index']);
  yield MapEntry('metadata.json', input['metadata']);
}

Iterable<MapEntry<String, Object?>> _commentary(
  JsonMap input,
  JsonMap bulk,
  int bytes,
) sync* {
  final module = requireString(input, 'module');
  _identity(bulk, 'getbible-commentary-v1', 'commentary', module);
  final metadata = CommentaryAdapter.metadata(input['metadata'], module);
  final coverage = CommentaryAdapter.coverage(input['index'], module);
  final metadataJson = metadata.source;
  final books = requireJsonList(bulk['books'], 'complete commentary books');
  if (requireInt(metadataJson, 'bytes') != bytes ||
      books.length != coverage.books.length ||
      books.length != requireInt(metadataJson, 'book_count') ||
      metadata.language != coverage.language ||
      metadata.language != requireString(bulk, 'language') ||
      metadata.name != coverage.name ||
      metadata.name != requireString(bulk, 'name')) {
    throw const FormatException(
      'The complete commentary disagrees with its metadata or coverage.',
    );
  }
  final seenBooks = <int>{};
  var entryCount = 0;
  var chapterCount = 0;
  for (final rawBook in books) {
    final book = requireJsonMap(rawBook, 'complete commentary book');
    _identity(book, 'getbible-commentary-book-v1', 'commentary', module);
    final number = requireInt(book, 'book');
    final expected = coverage.books
        .where((value) => value.book == number)
        .firstOrNull;
    if (expected == null ||
        !seenBooks.add(number) ||
        requireString(book, 'language') != metadata.language ||
        requireString(book, 'name') != expected.name) {
      throw const FormatException(
        'A commentary book disagrees with its coverage.',
      );
    }
    final chapters = requireJsonList(book['chapters'], 'commentary chapters');
    final seenChapters = <int>{};
    var bookEntryCount = 0;
    for (final rawChapter in chapters) {
      final chapterJson = requireJsonMap(rawChapter, 'commentary chapter');
      final numberOfChapter = requireInt(chapterJson, 'chapter');
      final chapter = CommentaryAdapter.chapter(
        chapterJson,
        module,
        number,
        numberOfChapter,
      );
      if (!seenChapters.add(numberOfChapter) ||
          !expected.chapters.contains(numberOfChapter) ||
          chapter.language != metadata.language ||
          chapter.name != expected.name) {
        throw const FormatException(
          'A commentary chapter disagrees with its coverage.',
        );
      }
      // All introductions, overlapping ranges, repeated anchors, text and source
      // provenance remain in the chapter document; no verse-key deduplication.
      bookEntryCount += chapter.entries.length;
      chapterCount++;
      yield MapEntry('chapters/$number/$numberOfChapter.json', chapterJson);
    }
    if (seenChapters.length != expected.chapters.length ||
        bookEntryCount != expected.entryCount) {
      throw const FormatException(
        'The complete commentary has missing chapters or entries.',
      );
    }
    entryCount += bookEntryCount;
  }
  if (entryCount != requireInt(metadataJson, 'entry_count') ||
      chapterCount != requireInt(metadataJson, 'chapter_count')) {
    throw const FormatException(
      'Commentary totals disagree with its metadata.',
    );
  }
  yield MapEntry('books.json', input['index']);
  yield MapEntry('metadata.json', input['metadata']);
}

Iterable<MapEntry<String, Object?>> _topics(JsonMap input, JsonMap bulk) sync* {
  if (requireInt(bulk, 'schema_version') != 1) {
    throw const FormatException('Unsupported complete public-topic format.');
  }
  final discovery = PublicTopicAdapter.discovery(input['discovery']);
  if (discovery.checksum != input['sha256']) {
    throw const FormatException(
      'Public-topic discovery and manifest disagree.',
    );
  }
  final rawTopics = requireJsonList(bulk['topics'], 'complete topics');
  final locales = requireJsonMap(bulk['locales'], 'complete topic locales');
  if (rawTopics.length != discovery.topicCount ||
      locales.length != discovery.localeCount ||
      !locales.keys.toSet().containsAll(discovery.locales)) {
    throw const FormatException(
      'Public-topic catalogue counts disagree with discovery.',
    );
  }
  final names = <String, PublicTopicNames>{};
  final localeSummaries = <JsonMap>[];
  for (final locale in locales.entries) {
    PublicTopicAdapter.validateLocale(locale.key);
    final parsed = PublicTopicAdapter.names(locale.value, locale: locale.key);
    names[locale.key] = parsed;
    final document = requireJsonMap(locale.value, 'topic locale');
    localeSummaries.add({
      'code': locale.key,
      'name': document['name'],
      'topics': parsed.names.length,
    });
    yield MapEntry('locales/${locale.key}.json', locale.value);
  }
  if (!names.containsKey('en')) {
    throw const FormatException('Public-topic English names are missing.');
  }
  final summaries = <JsonMap>[];
  final seen = <String>{};
  final reverse = <String, Map<String, List<String>>>{};
  var associations = 0;
  for (final raw in rawTopics) {
    final record = requireJsonMap(raw, 'complete topic');
    final id = requireString(record, 'id');
    if (!seen.add(id)) {
      throw const FormatException('Duplicate public-topic id.');
    }
    if (names['en']!.names[id] != requireString(record, 'name')) {
      throw const FormatException(
        'Public-topic English name does not match its catalogue.',
      );
    }
    final JsonMap document = {
      ...record,
      'schema_version': 1,
      'names': {
        for (final locale in names.entries)
          if (locale.value.names.containsKey(id))
            locale.key: locale.value.names[id],
      },
    };
    final topic = PublicTopicAdapter.topic(document, expectedId: id);
    associations += topic.coordinates.length;
    summaries.add({...record, 'verses': topic.coordinates.length});
    for (final coordinate in topic.coordinates) {
      final chapter = '${coordinate.book}/${coordinate.chapter}';
      reverse
          .putIfAbsent(chapter, () => {})
          .putIfAbsent('${coordinate.verse}', () => [])
          .add(id);
    }
    yield MapEntry('topics/$id.json', document);
  }
  if (associations != discovery.associationCount ||
      names.values.any((locale) => !seen.containsAll(locale.names.keys))) {
    throw const FormatException(
      'Public-topic names or association totals disagree with discovery.',
    );
  }
  for (final entry in reverse.entries) {
    final coordinates = entry.key.split('/').map(int.parse).toList();
    for (final ids in entry.value.values) {
      ids.sort();
    }
    yield MapEntry('verses/${entry.key}.json', {
      'schema_version': 1,
      'book': coordinates[0],
      'chapter': coordinates[1],
      'verses': entry.value,
    });
  }
  yield MapEntry('topics.json', {'schema_version': 1, 'topics': summaries});
  yield MapEntry('locales.json', {
    'schema_version': 1,
    'locales': localeSummaries,
  });
  yield MapEntry('index.json', input['discovery']);
}

void _identity(JsonMap json, String schema, String field, String id) {
  if (requireString(json, 'schema') != schema ||
      requireString(json, field) != id) {
    throw const FormatException('Complete Study resource identity mismatch.');
  }
}
