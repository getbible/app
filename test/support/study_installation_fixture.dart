import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:getbible_live/application/offline_controller.dart';
import 'package:getbible_live/core/json.dart';
import 'package:getbible_live/core/request_cancellation.dart';
import 'package:getbible_live/data/api/api_transport.dart';
import 'package:getbible_live/data/database/local_database.dart';
import 'package:getbible_live/data/offline/study_resource_installer.dart';
import 'package:getbible_live/domain/models/offline_resource.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

JsonMap _json(String path) => requireJsonMap(
  jsonDecode(File('test/fixtures/$path').readAsStringSync()),
  path,
);

final class StudyInstallationFixture {
  StudyInstallationFixture(this.kind) {
    late JsonMap catalogue;
    if (kind == OfflineResourceKind.dictionary) {
      module = 'strongsgreek';
      catalogue = _json('dictionaries_v1/dictionaries.json');
      _put('dictionaries.json', catalogue);
      _put(
        '$module/metadata.json',
        _json('dictionaries_v1/$module/metadata.json'),
      );
      _put('$module/index.json', _json('dictionaries_v1/$module/index.json'));
      documents['$module.json'] = File(
        'test/fixtures/offline_study_v1/dictionary.json',
      ).readAsBytesSync();
    } else if (kind == OfflineResourceKind.commentary) {
      module = 'fixture';
      final fixture = _json('commentary_v1.json');
      _put('commentaries.json', fixture['catalogue']);
      _put('$module/metadata.json', fixture['metadata']);
      _put('$module/books.json', fixture['coverage']);
      documents['$module.json'] = File(
        'test/fixtures/offline_study_v1/commentary.json',
      ).readAsBytesSync();
    } else {
      module = 'all';
      _put(
        'index.json',
        _json('public_topic_index.json')
          ..['counts'] = {'topics': 2, 'verses': 4, 'locales': 2},
      );
      documents['all.json'] = File(
        'test/fixtures/offline_study_v1/bookmarks.json',
      ).readAsBytesSync();
    }
    updateSizesAndManifest();
    transport = ApiTransport(
      client: MockClient((request) async {
        paths.add(request.url.path);
        if (offline) {
          throw const SocketException(
            'Offline for installed-resource regression',
          );
        }
        final path = request.url.path.substring('/v1/'.length);
        final bytes = documents[path];
        if (bytes == null) return http.Response('missing', 404);
        if (path == manifestPath) {
          manifestReads++;
          if (rotateManifest && manifestReads.isEven) {
            final changed = requireJsonMap(
              jsonDecode(utf8.decode(bytes)),
              'manifest',
            );
            (changed['files']! as Map)[bulkPath] = 'b' * 64;
            return http.Response(jsonEncode(changed), 200);
          }
        }
        return http.Response.bytes(
          corruptBody && path == bulkPath
              ? [bytes.first ^ 1, ...bytes.skip(1)]
              : bytes,
          200,
        );
      }),
      retryPolicy: const ApiRetryPolicy(maxRetries: 0),
    );
    addTearDown(transport.close);
  }
  final OfflineResourceKind kind;
  late final String module;
  late final ApiTransport transport;
  final documents = <String, List<int>>{};
  final paths = <String>[];
  bool offline = false, corruptBody = false, rotateManifest = false;
  int manifestReads = 0;
  String get bulkPath => '$module.json';
  String get manifestPath =>
      kind == OfflineResourceKind.bookmarks ? 'checksums.json' : 'hashes.json';
  Uri get source => Uri.parse(
    'https://${switch (kind) {
      OfflineResourceKind.dictionary => 'dictionaries',
      OfflineResourceKind.commentary => 'commentaries',
      _ => 'bookmarks',
    }}.getbible.net/v1',
  );
  void _put(String path, Object? json) {
    documents[path] = utf8.encode(jsonEncode(json));
  }

  void updateSizesAndManifest() {
    if (kind == OfflineResourceKind.bookmarks) {
      final index = requireJsonMap(
        jsonDecode(utf8.decode(documents['index.json']!)),
        'index',
      );
      index['checksum'] = sha256.convert(documents[bulkPath]!).toString();
      _put('index.json', index);
    } else {
      final metadataPath = '$module/metadata.json';
      final metadata = requireJsonMap(
        jsonDecode(utf8.decode(documents[metadataPath]!)),
        'metadata',
      );
      metadata['bytes'] = documents[bulkPath]!.length;
      _put(metadataPath, metadata);
      final field = kind == OfflineResourceKind.dictionary
          ? 'dictionaries'
          : 'commentaries';
      final catalogue = requireJsonMap(
        jsonDecode(utf8.decode(documents['$field.json']!)),
        'catalogue',
      );
      for (final item in catalogue[field]! as List) {
        if ((item as Map)['id'] == module) {
          item['bytes'] = documents[bulkPath]!.length;
        }
      }
      _put('$field.json', catalogue);
    }
    _put(manifestPath, {
      if (kind == OfflineResourceKind.bookmarks)
        'schema_version': 1
      else ...{
        'schema': 'getbible-hashes-v1',
        'algorithm': 'sha256',
      },
      'files': {
        for (final entry in documents.entries)
          if (entry.key != manifestPath)
            entry.key: sha256.convert(entry.value).toString(),
      },
    });
  }

  Future<OfflineController> install(
    LocalDatabase database, {
    bool expectSuccess = true,
  }) async {
    final installer = StudyResourceInstaller(transport, kind);
    final descriptor = (await installer.discover(
      RequestCancellation(),
    )).firstWhere((item) => item.id == module);
    final controller = OfflineController(
      store: SqlOfflineResourceStore(database),
      installers: [installer],
    );
    addTearDown(controller.dispose);
    await controller.install(descriptor);
    if (expectSuccess) expect(controller.error, isNull);
    return controller;
  }
}
