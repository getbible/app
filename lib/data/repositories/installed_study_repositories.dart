import 'dart:convert';

import '../../core/errors.dart';
import '../../core/json.dart';
import '../../core/request_cancellation.dart';
import '../../domain/models/commentary.dart';
import '../../domain/models/dictionary.dart';
import '../../domain/models/offline_resource.dart';
import '../../domain/models/public_topic.dart';
import '../../domain/models/service_envelopes.dart';
import '../../domain/repositories/commentary_repository.dart';
import '../../domain/repositories/dictionary_repository.dart';
import '../../domain/repositories/installed_study_resource.dart';
import '../../domain/repositories/offline_resource_repository.dart';
import '../../domain/repositories/public_topics_repository.dart';
import '../api/commentary_adapter.dart';
import '../api/dictionary_adapters.dart';
import '../api/public_topic_adapter.dart';
import '../api/service_envelope_adapters.dart';
import '../offline/bible_index_worker.dart';

/// Installed modules always answer locally, including after application restart.
/// A missing installed entry is never replaced with a different online revision.
final class InstalledDictionaryRepository
    implements DictionaryRepository, InstalledStudyResource {
  InstalledDictionaryRepository({
    required OfflineResourceStore store,
    required Uri sourceUri,
    required this.online,
  }) : _reader = _InstalledReader(
         store,
         sourceUri,
         OfflineResourceKind.dictionary,
       );
  final DictionaryRepository online;
  final _InstalledReader _reader;

  @override
  Future<bool> isInstalled(String id) async => await _reader.find(id) != null;

  @override
  Future<DictionaryCatalogue> catalogue({
    RequestCancellation? cancellation,
  }) async {
    final local = await _reader.catalogue(cancellation);
    if (local == null) return online.catalogue(cancellation: cancellation);
    // Saved discovery includes online-only choices as well as installed modules.
    // Opening an installed resource therefore does not wait for HTTP timeouts.
    final modules = <String, DictionaryModule>{};
    JsonMap source = const {};
    for (final document in local) {
      final catalogue = ServiceEnvelopeAdapters.dictionaries(document);
      source = catalogue.source;
      for (final module in catalogue.modules) {
        modules[module.id] = module;
      }
    }
    final installed = await _reader.installedIds();
    return DictionaryCatalogue(
      modules: List.unmodifiable([
        ...modules.values.where((module) => installed.contains(module.id)),
        ...modules.values.where((module) => !installed.contains(module.id)),
      ]),
      source: source,
    );
  }

  @override
  Future<DictionaryMetadata> metadata(
    String module, {
    RequestCancellation? cancellation,
  }) async {
    final local = await _reader.read(
      module,
      'metadata.json',
      cancellation,
      beginSnapshot: true,
    );
    return local == null
        ? online.metadata(module, cancellation: cancellation)
        : DictionaryAdapters.metadata(local, module);
  }

  @override
  Future<DictionaryIndex> index(
    String module, {
    RequestCancellation? cancellation,
  }) async {
    final raw = await _reader.readRaw(module, 'index.json', cancellation);
    if (raw == null) return online.index(module, cancellation: cancellation);
    if (raw.length < 256 * 1024) {
      return DictionaryAdapters.index(jsonDecode(raw), module);
    }
    JsonMap? header;
    final entries = <DictionaryIndexEntry>[];
    final normalized = <List<String>>[];
    await indexStudyInWorker(
      {'kind': 'dictionary-index', 'module': module, 'bytes': utf8.encode(raw)},
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
      throw const StorageException(
        'The installed dictionary index is incomplete. Reinstall it.',
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

  @override
  Future<DictionaryEntry> entry(
    String module,
    String id, {
    RequestCancellation? cancellation,
  }) async {
    final local = await _reader.read(
      module,
      'entries/${Uri.encodeComponent(id)}.json',
      cancellation,
    );
    return local == null
        ? online.entry(module, id, cancellation: cancellation)
        : DictionaryAdapters.entry(local, module, id);
  }
}

final class InstalledCommentaryRepository
    implements CommentaryRepository, InstalledStudyResource {
  InstalledCommentaryRepository({
    required OfflineResourceStore store,
    required Uri sourceUri,
    required this.online,
  }) : _reader = _InstalledReader(
         store,
         sourceUri,
         OfflineResourceKind.commentary,
       );
  final CommentaryRepository online;
  final _InstalledReader _reader;
  @override
  Future<bool> isInstalled(String id) async => await _reader.find(id) != null;
  @override
  Future<CommentaryCatalogue> catalogue({
    RequestCancellation? cancellation,
  }) async {
    final local = await _reader.catalogue(cancellation);
    if (local == null) return online.catalogue(cancellation: cancellation);
    final modules = <String, CommentaryModule>{};
    JsonMap source = const {};
    for (final document in local) {
      final catalogue = ServiceEnvelopeAdapters.commentaries(document);
      source = catalogue.source;
      for (final module in catalogue.modules) {
        modules[module.id] = module;
      }
    }
    final installed = await _reader.installedIds();
    return CommentaryCatalogue(
      modules: List.unmodifiable([
        ...modules.values.where((module) => installed.contains(module.id)),
        ...modules.values.where((module) => !installed.contains(module.id)),
      ]),
      source: source,
    );
  }

  @override
  Future<CommentaryMetadata> metadata(
    String module, {
    RequestCancellation? cancellation,
  }) async {
    final local = await _reader.read(
      module,
      'metadata.json',
      cancellation,
      beginSnapshot: true,
    );
    return local == null
        ? online.metadata(module, cancellation: cancellation)
        : CommentaryAdapter.metadata(local, module);
  }

  @override
  Future<CommentaryCoverage> coverage(
    String module, {
    RequestCancellation? cancellation,
  }) async {
    final local = await _reader.read(module, 'books.json', cancellation);
    return local == null
        ? online.coverage(module, cancellation: cancellation)
        : CommentaryAdapter.coverage(local, module);
  }

  @override
  Future<CommentaryChapter> chapter(
    String module,
    int book,
    int chapter, {
    RequestCancellation? cancellation,
  }) async {
    final local = await _reader.read(
      module,
      'chapters/$book/$chapter.json',
      cancellation,
    );
    return local == null
        ? online.chapter(module, book, chapter, cancellation: cancellation)
        : CommentaryAdapter.chapter(local, module, book, chapter);
  }
}

final class InstalledPublicTopicsRepository
    implements PublicTopicsRepository, InstalledStudyResource {
  InstalledPublicTopicsRepository({
    required OfflineResourceStore store,
    required Uri sourceUri,
    required this.online,
  }) : _reader = _InstalledReader(
         store,
         sourceUri,
         OfflineResourceKind.bookmarks,
       );
  final PublicTopicsRepository online;
  final _InstalledReader _reader;
  @override
  String get sourceScope => online.sourceScope;
  @override
  Future<bool> isInstalled(String id) async =>
      await _reader.find('all') != null;
  @override
  Future<PublicTopicDiscovery> discovery({
    RequestCancellation? cancellation,
  }) async {
    final local = await _reader.read(
      'all',
      'index.json',
      cancellation,
      beginSnapshot: true,
    );
    return local == null
        ? online.discovery(cancellation: cancellation)
        : PublicTopicAdapter.discovery(local);
  }

  @override
  Future<PublicTopicCatalogue> catalogue({
    RequestCancellation? cancellation,
  }) async {
    final local = await _reader.read('all', 'topics.json', cancellation);
    return local == null
        ? online.catalogue(cancellation: cancellation)
        : PublicTopicAdapter.catalogue(local);
  }

  @override
  Future<List<PublicTopicLocale>> locales({
    RequestCancellation? cancellation,
  }) async {
    final local = await _reader.read('all', 'locales.json', cancellation);
    return local == null
        ? online.locales(cancellation: cancellation)
        : PublicTopicAdapter.locales(local);
  }

  @override
  Future<PublicTopicNames> names(
    String locale, {
    RequestCancellation? cancellation,
  }) async {
    PublicTopicAdapter.validateLocale(locale);
    final local = await _reader.read(
      'all',
      'locales/$locale.json',
      cancellation,
    );
    return local == null
        ? online.names(locale, cancellation: cancellation)
        : PublicTopicAdapter.names(local, locale: locale);
  }

  @override
  Future<PublicTopic> topic(
    String id, {
    RequestCancellation? cancellation,
  }) async {
    PublicTopicAdapter.validateId(id);
    final local = await _reader.read('all', 'topics/$id.json', cancellation);
    return local == null
        ? online.topic(id, cancellation: cancellation)
        : PublicTopicAdapter.topic(local, expectedId: id);
  }

  @override
  Future<PublicTopicAssociations> chapter(
    int book,
    int chapter, {
    RequestCancellation? cancellation,
  }) async {
    if (book < 1 ||
        book > 66 ||
        chapter < 1 ||
        chapter > _canonicalChapters[book - 1]) {
      throw const FormatException(
        'The public-topic dataset has no such canonical chapter.',
      );
    }
    final snapshot = await _reader.snapshot('all');
    if (snapshot == null) {
      return online.chapter(book, chapter, cancellation: cancellation);
    }
    final local = await _reader.readSnapshot(
      snapshot,
      'verses/$book/$chapter.json',
      cancellation,
      allowMissing: true,
    );
    // A complete, verified catalogue creates indexes only for linked chapters.
    // Missing local index means genuinely empty associations, never a partial
    // download: staging cannot activate until every topic is indexed.
    return local == null
        ? PublicTopicAssociations(
            book: book,
            chapter: chapter,
            verses: const {},
          )
        : PublicTopicAdapter.chapter(local, book: book, chapter: chapter);
  }
}

const _canonicalChapters = <int>[
  50,
  40,
  27,
  36,
  34,
  24,
  21,
  4,
  31,
  24,
  22,
  25,
  29,
  36,
  10,
  13,
  10,
  42,
  150,
  31,
  12,
  8,
  66,
  52,
  5,
  48,
  12,
  14,
  3,
  9,
  1,
  4,
  7,
  3,
  3,
  3,
  2,
  14,
  4,
  28,
  16,
  24,
  21,
  28,
  16,
  16,
  13,
  6,
  6,
  4,
  4,
  5,
  3,
  6,
  4,
  3,
  1,
  13,
  5,
  5,
  3,
  5,
  1,
  1,
  1,
  22,
];

final class _InstalledReader {
  _InstalledReader(this.store, this.sourceUri, this.kind);
  final OfflineResourceStore store;
  final Uri sourceUri;
  final OfflineResourceKind kind;
  final _snapshots = <String, Future<OfflineInstalledResource?>>{};
  Future<OfflineInstalledResource?> find(String id) =>
      store.find(kind, id, sourceUri);
  Future<OfflineInstalledResource?> snapshot(String id) =>
      _snapshots.putIfAbsent(id, () => find(id));

  Future<Set<String>> installedIds() async => {
    for (final item in await store.listInstalled())
      if (item.resource.kind == kind && item.resource.sourceUri == sourceUri)
        item.resource.id,
  };

  Future<List<JsonMap>?> catalogue(RequestCancellation? cancellation) async {
    final snapshots =
        (await store.listInstalled())
            .where(
              (item) =>
                  item.resource.kind == kind &&
                  item.resource.sourceUri.toString().replaceFirst(
                        RegExp(r'/+$'),
                        '',
                      ) ==
                      sourceUri.toString().replaceFirst(RegExp(r'/+$'), ''),
            )
            .toList()
          ..sort((a, b) => a.installedAt.compareTo(b.installedAt));
    if (snapshots.isEmpty) return null;
    final documents = <JsonMap>[];
    final ownModules = <JsonMap>[];
    for (final snapshot in snapshots) {
      final raw = await readSnapshot(snapshot, 'catalogue.json', cancellation);
      final document = requireJsonMap(raw, 'installed Study catalogue');
      documents.add(document);
      final field = kind == OfflineResourceKind.dictionary
          ? 'dictionaries'
          : 'commentaries';
      final own = requireJsonList(document[field], field)
          .where(
            (item) =>
                requireJsonMap(item, 'module')['id'] == snapshot.resource.id,
          )
          .toList();
      if (own.length != 1) {
        throw const StorageException(
          'The installed resource has inconsistent discovery metadata. Reinstall it.',
        );
      }
      ownModules.add({...document, field: own, 'module_count': 1});
    }
    return [...documents, ...ownModules];
  }

  Future<String?> readRaw(
    String id,
    String path,
    RequestCancellation? cancellation,
  ) async {
    cancellation?.throwIfCancelled();
    final current = await snapshot(id);
    if (current == null) return null;
    final raw = await store.readDocument(
      current.resource.key,
      path,
      generation: current.generation,
    );
    cancellation?.throwIfCancelled();
    if (raw == null) {
      throw const StorageException(
        'The installed Study resource changed or is incomplete. Reopen it or reinstall it from Set up offline use.',
      );
    }
    return raw;
  }

  Future<Object?> read(
    String id,
    String path,
    RequestCancellation? cancellation, {
    bool beginSnapshot = false,
  }) async {
    cancellation?.throwIfCancelled();
    if (beginSnapshot) _snapshots[id] = find(id);
    final snapshot = await this.snapshot(id);
    if (snapshot == null) return null;
    return readSnapshot(snapshot, path, cancellation);
  }

  Future<Object?> readSnapshot(
    OfflineInstalledResource snapshot,
    String path,
    RequestCancellation? cancellation, {
    bool allowMissing = false,
  }) async {
    cancellation?.throwIfCancelled();
    final raw = await store.readDocument(
      snapshot.resource.key,
      path,
      generation: snapshot.generation,
    );
    cancellation?.throwIfCancelled();
    if (raw == null) {
      if (allowMissing) {
        final current = await find(snapshot.resource.id);
        if (current?.generation == snapshot.generation) return null;
      }
      throw const StorageException(
        'This document is unavailable in the installed resource. Reinstall it from Set up offline use.',
      );
    }
    try {
      return jsonDecode(raw);
    } on FormatException catch (error) {
      throw StorageException(
        'The installed resource is damaged. Reinstall it from Set up offline use.',
        error,
      );
    }
  }
}
