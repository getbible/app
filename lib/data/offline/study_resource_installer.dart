import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../../core/errors.dart';
import '../../core/json.dart';
import '../../core/request_cancellation.dart';
import '../../domain/models/offline_resource.dart';
import '../../domain/repositories/offline_resource_repository.dart';
import '../api/api_configuration.dart';
import '../api/api_transport.dart';
import '../api/public_topic_adapter.dart';
import '../api/service_envelope_adapters.dart';
import 'bible_index_worker.dart';

/// Downloads complete published modules when scheduled by the offline manager.
/// No per-entry/chapter HTTP crawl is used. The small companion documents and
/// complete body must match one stable manifest snapshot before activation.
final class StudyResourceInstaller
    implements OfflineResourceInstaller, OfflineRevisionCache {
  StudyResourceInstaller(
    this.transport,
    this.kind, {
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;
  final ApiTransport transport;
  final OfflineResourceKind kind;
  final DateTime Function() _clock;
  final Set<String> _knownManifestPaths = {};
  _Manifest? _manifestCache;
  DateTime? _manifestCheckedAt;
  Uri? _manifestSource;

  @override
  void clearRevisionCache() {
    _manifestCache = null;
    _manifestCheckedAt = null;
    _manifestSource = null;
  }

  @override
  Set<OfflineResourceKind> get supportedKinds => {kind};
  ApiService get _service => switch (kind) {
    OfflineResourceKind.dictionary => ApiService.dictionaries,
    OfflineResourceKind.commentary => ApiService.commentaries,
    OfflineResourceKind.bookmarks => ApiService.bookmarks,
    OfflineResourceKind.bible => throw ArgumentError(
      'Use the Bible installer.',
    ),
  };
  @override
  Uri get sourceUri => transport.configuration.endpoint(_service).baseUri;

  @override
  Future<OfflineResourceDescriptor> resolve(
    OfflineResourceKind kind,
    String id,
    RequestCancellation cancellation,
  ) async {
    _validate(kind, id, sourceUri);
    final descriptor = (await discover(
      cancellation,
    )).where((resource) => resource.id == id).firstOrNull;
    if (descriptor == null) {
      throw const FormatException(
        'This resource is not in the published catalogue.',
      );
    }
    return checkRevision(descriptor, cancellation);
  }

  @override
  Future<OfflineResourceDescriptor> checkRevision(
    OfflineResourceDescriptor resource,
    RequestCancellation cancellation,
  ) async {
    _validate(resource.kind, resource.id, resource.sourceUri);
    final manifest = await _manifest(_revisionPaths(resource.id), cancellation);
    return OfflineResourceDescriptor(
      kind: kind,
      id: resource.id,
      title: resource.title,
      sourceUri: sourceUri,
      revision: _revision(resource.id, manifest),
      estimatedBytes: resource.estimatedBytes,
      attribution: resource.attribution,
    );
  }

  void _validate(OfflineResourceKind kind, String id, Uri source) {
    if (kind != this.kind ||
        source != sourceUri ||
        id.isEmpty ||
        id == '.' ||
        id == '..' ||
        id.contains('/') ||
        id.contains('\\') ||
        (kind == OfflineResourceKind.bookmarks && id != 'all')) {
      throw const FormatException(
        'The installation belongs to another resource or service.',
      );
    }
  }

  List<String> _revisionPaths(String id) =>
      kind == OfflineResourceKind.bookmarks
      ? ['index.json', 'all.json']
      : [
          '$id.json',
          '$id/metadata.json',
          '$id/${kind == OfflineResourceKind.dictionary ? 'index' : 'books'}.json',
        ];

  /// Global catalogue/build timestamps can change without changing this module.
  /// Fingerprint only its complete body and metadata/index companions; both
  /// installation and later checks use this exact ordered tuple.
  String _revision(String id, _Manifest manifest) =>
      'sha256:${sha256.convert(utf8.encode(jsonEncode([
        for (final path in _revisionPaths(id)) [path, manifest.hashes[path]],
      ])))}';

  @override
  Future<List<OfflineResourceDescriptor>> discover(
    RequestCancellation cancellation,
  ) async {
    final response = await _get(
      _cataloguePath,
      cancellation,
      limit: ApiResponseLimits.metadata,
    );
    if (kind == OfflineResourceKind.bookmarks) {
      final discovery = PublicTopicAdapter.discovery(response.json);
      return [
        OfflineResourceDescriptor(
          kind: kind,
          id: 'all',
          title: 'Public topics',
          sourceUri: sourceUri,
          revision: discovery.checksum,
          attribution:
              'getBible public topics; source verse coordinates and translated names',
        ),
      ];
    }
    if (kind == OfflineResourceKind.dictionary) {
      final catalogue = ServiceEnvelopeAdapters.dictionaries(response.json);
      _rememberModulePaths(catalogue.modules.map((module) => module.id));
      return [
        for (final module in catalogue.modules)
          OfflineResourceDescriptor(
            kind: kind,
            id: module.id,
            title: '${module.name} · ${module.language}',
            sourceUri: sourceUri,
            revision: requireString(catalogue.source, 'generated_at'),
            estimatedBytes: module.bytes,
            attribution: module.license,
          ),
      ];
    }
    final catalogue = ServiceEnvelopeAdapters.commentaries(response.json);
    _rememberModulePaths(catalogue.modules.map((module) => module.id));
    return [
      for (final module in catalogue.modules)
        OfflineResourceDescriptor(
          kind: kind,
          id: module.id,
          title: '${module.name} · ${module.language}',
          sourceUri: sourceUri,
          revision: requireString(catalogue.source, 'generated_at'),
          estimatedBytes: module.bytes,
          attribution: module.license,
        ),
    ];
  }

  void _rememberModulePaths(Iterable<String> ids) {
    _knownManifestPaths.clear();
    _knownManifestPaths.add(_cataloguePath);
    // Discovery may be large or supplied by another configured source. Keep
    // only a bounded set of small fingerprints, never the complete manifest.
    for (final id in ids.take(1000)) {
      _knownManifestPaths.addAll(_revisionPaths(id));
    }
  }

  String get _cataloguePath => switch (kind) {
    OfflineResourceKind.dictionary => 'dictionaries.json',
    OfflineResourceKind.commentary => 'commentaries.json',
    OfflineResourceKind.bookmarks => 'index.json',
    OfflineResourceKind.bible => throw ArgumentError(
      'Use the Bible installer.',
    ),
  };

  @override
  Future<void> install(
    OfflineResourceDescriptor resource,
    OfflineInstallSink sink,
    RequestCancellation cancellation,
  ) async {
    _validate(resource.kind, resource.id, resource.sourceUri);
    final bookmarks = kind == OfflineResourceKind.bookmarks;
    if (bookmarks && resource.id != 'all') {
      throw const FormatException(
        'Install the complete public-topic catalogue.',
      );
    }
    final module = resource.id;
    final paths = bookmarks
        ? <String>['index.json', 'all.json']
        : <String>[
            _cataloguePath,
            '$module/metadata.json',
            '$module/${kind == OfflineResourceKind.dictionary ? 'index' : 'books'}.json',
            '$module.json',
          ];
    sink.progress(0, null, 'Checking published integrity manifest');
    final before = await _manifest(paths, cancellation);
    final docs = <String, ApiResponse>{};
    for (var i = 0; i < paths.length; i++) {
      final path = paths[i];
      final response = await _get(
        _encodedPath(path),
        cancellation,
        limit: path == paths.last
            ? ApiResponseLimits.bulk
            : ApiResponseLimits.chapter,
      );
      // The complete-body digest is verified inside the worker; small metadata
      // verification here never hashes a whole resource on the UI isolate.
      if (path != paths.last &&
          (bookmarks || path != paths[2]) &&
          sha256.convert(response.bytes).toString() != before.hashes[path]) {
        throw const FormatException(
          'The downloaded Study metadata does not match its manifest. Refresh and retry.',
        );
      }
      docs[path] = response;
      sink.progress(i + 1, paths.length, 'Downloading ${resource.title}');
    }
    final catalogue = docs[_cataloguePath]!.json;
    final verifiedRevision = _revision(resource.id, before);
    var verifiedTitle = resource.title;
    var verifiedAttribution = resource.attribution;
    if (!bookmarks) {
      final available = kind == OfflineResourceKind.dictionary
          ? ServiceEnvelopeAdapters.dictionaries(
              catalogue,
            ).modules.map((m) => (m.id, m.bytes))
          : ServiceEnvelopeAdapters.commentaries(
              catalogue,
            ).modules.map((m) => (m.id, m.bytes));
      final found = available.where((m) => m.$1 == module).firstOrNull;
      if (found == null || found.$2 != docs[paths.last]!.bytes.length) {
        throw const FormatException(
          'The Study catalogue changed. Refresh the resource list and retry.',
        );
      }
    }
    if (!bookmarks) {
      final metadata = docs['$module/metadata.json']!.json;
      final field = kind == OfflineResourceKind.dictionary
          ? 'dictionaries'
          : 'commentaries';
      final advertised = requireJsonList(catalogue[field], field)
          .map((value) => requireJsonMap(value, 'catalogue module'))
          .singleWhere((value) => value['id'] == module);
      for (final key in [
        'name',
        'language',
        'license',
        'entry_count',
        'bytes',
        if (kind == OfflineResourceKind.dictionary) ...[
          'unique_key_count',
          'strong_prefix',
        ] else ...[
          'book_count',
          'chapter_count',
        ],
      ]) {
        if (advertised[key] != metadata[key]) {
          throw const FormatException(
            'Study catalogue and module metadata disagree. Refresh and retry.',
          );
        }
      }
      verifiedTitle =
          '${requireString(metadata, 'name')} · ${requireString(metadata, 'language')}';
      verifiedAttribution = requireString(metadata, 'license');
    }
    var processed = 0;
    final input = <String, Object?>{
      'kind': kind.name,
      'module': module,
      'bytes': docs[paths.last]!.bytes,
      'sha256': before.hashes[paths.last],
      if (bookmarks) 'discovery': catalogue,
      if (!bookmarks) 'metadata': docs['$module/metadata.json']!.json,
      if (!bookmarks) 'indexBytes': docs[paths[2]]!.bytes,
      if (!bookmarks) 'indexSha256': before.hashes[paths[2]],
    };
    await indexStudyInWorker(input, (batch) async {
      final records = requireJsonMap(batch['documents'], 'indexed documents');
      cancellation.throwIfCancelled();
      await sink.writeDocuments(
        records.map((path, value) => MapEntry(path, value! as String)),
      );
      processed += records.length;
      sink.progress(processed, null, 'Indexing ${resource.title}');
    }, cancellation);
    if (!bookmarks) {
      await sink.writeDocument('catalogue.json', jsonEncode(catalogue));
    }
    final after = await _manifest(paths, cancellation, force: true);
    for (final path in paths) {
      if (before.hashes[path] != after.hashes[path]) {
        throw const FormatException(
          'The Study source changed during installation. The previous installation is unchanged; refresh and retry.',
        );
      }
    }
    await sink.writeDocument(
      'integrity.json',
      jsonEncode({
        'schema': 'getbible-installed-study-integrity-v1',
        'algorithm': 'sha256',
        'source': sourceUri.toString(),
        'files': before.hashes,
        'manifest_before_sha256': before.digest,
        'manifest_after_sha256': after.digest,
      }),
    );
    cancellation.throwIfCancelled();
    await sink.setVerifiedDescriptor(
      OfflineResourceDescriptor(
        kind: kind,
        id: resource.id,
        title: verifiedTitle,
        sourceUri: sourceUri,
        revision: verifiedRevision,
        estimatedBytes: docs[paths.last]!.bytes.length,
        attribution: verifiedAttribution,
      ),
    );
    sink.progress(processed, processed, 'Verified ${resource.title}');
  }

  Future<_Manifest> _manifest(
    List<String> paths,
    RequestCancellation cancellation, {
    bool force = false,
  }) async {
    cancellation.throwIfCancelled();
    final previous = _manifestCache;
    final checkedAt = _manifestCheckedAt;
    final age = checkedAt == null ? null : _clock().difference(checkedAt);
    if (!force &&
        previous != null &&
        _manifestSource == sourceUri &&
        age != null &&
        !age.isNegative &&
        age < const Duration(minutes: 1) &&
        paths.every(previous.hashes.containsKey)) {
      return previous;
    }
    final response = await _get(
      kind == OfflineResourceKind.bookmarks ? 'checksums.json' : 'hashes.json',
      cancellation,
      limit: ApiResponseLimits.bulk,
    );
    _Manifest? result;
    await indexStudyInWorker(
      {
        'kind': 'manifest',
        'bytes': response.bytes,
        'paths': paths,
        'optionalPaths': _knownManifestPaths.toList(),
        'bookmarks': kind == OfflineResourceKind.bookmarks,
      },
      (batch) async {
        final hashes = requireJsonMap(
          batch['manifest'],
          'verified manifest paths',
        );
        result = _Manifest(
          hashes.map((key, value) => MapEntry(key, value! as String)),
          requireString(batch, 'digest'),
        );
      },
      cancellation,
    );
    if (result == null) {
      throw const FormatException('The resource manifest could not be read.');
    }
    cancellation.throwIfCancelled();
    _manifestCache = result;
    _manifestCheckedAt = _clock();
    _manifestSource = sourceUri;
    return result!;
  }

  Future<ApiResponse> _get(
    String path,
    RequestCancellation cancellation, {
    required int limit,
  }) async {
    final response = await transport.get(
      _service,
      path,
      maxBytes: limit,
      cancellation: cancellation,
      forceRefresh: true,
    );
    transport.discardResponse(
      response,
    ); // Explicit installations own their store, not the opportunistic HTTP cache.
    if (response.cachePolicy.noStore) {
      throw const StorageException(
        'This public source does not permit storing the downloaded resource.',
      );
    }
    return response;
  }
}

String _encodedPath(String path) =>
    path.split('/').map(Uri.encodeComponent).join('/');

final class _Manifest {
  const _Manifest(this.hashes, this.digest);
  final Map<String, String> hashes;
  final String digest;
}
