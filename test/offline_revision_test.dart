import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:getbible/application/offline_controller.dart';
import 'package:getbible/core/request_cancellation.dart';
import 'package:getbible/data/api/api_transport.dart';
import 'package:getbible/data/database/local_database.dart';
import 'package:getbible/data/offline/bible_resource_installer.dart';
import 'package:getbible/data/offline/study_resource_installer.dart';
import 'package:getbible/domain/models/offline_resource.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'support/study_installation_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final kind in [
    OfflineResourceKind.dictionary,
    OfflineResourceKind.commentary,
  ]) {
    test(
      '${kind.name} fingerprints detect own companions, not unrelated builds',
      () async {
        final fixture = StudyInstallationFixture(kind);
        final installer = StudyResourceInstaller(fixture.transport, kind);
        final first = await installer.resolve(
          kind,
          fixture.module,
          RequestCancellation(),
        );
        expect(fixture.paths, isNot(contains('/v1/${fixture.bulkPath}')));
        final cataloguePath = kind == OfflineResourceKind.dictionary
            ? 'dictionaries.json'
            : 'commentaries.json';
        final catalogue =
            jsonDecode(utf8.decode(fixture.documents[cataloguePath]!)) as Map;
        catalogue['generated_at'] = '2030-01-01T00:00:00Z';
        fixture.documents[cataloguePath] = utf8.encode(jsonEncode(catalogue));
        fixture.updateSizesAndManifest();
        installer.clearRevisionCache();
        final unchanged = await installer.checkRevision(
          first,
          RequestCancellation(),
        );
        expect(unchanged.revision, first.revision);
        final metadataPath = '${fixture.module}/metadata.json';
        fixture.documents[metadataPath] = [
          ...fixture.documents[metadataPath]!,
          32,
        ];
        // Adjust just the metadata hash, without fixture normalization removing whitespace.
        final manifest =
            jsonDecode(utf8.decode(fixture.documents[fixture.manifestPath]!))
                as Map;
        (manifest['files'] as Map)[metadataPath] = sha256
            .convert(fixture.documents[metadataPath]!)
            .toString();
        fixture.documents[fixture.manifestPath] = utf8.encode(
          jsonEncode(manifest),
        );
        installer.clearRevisionCache();
        final changed = await installer.checkRevision(
          first,
          RequestCancellation(),
        );
        expect(changed.revision, isNot(first.revision));
        expect(fixture.paths, isNot(contains('/v1/${fixture.bulkPath}')));
        final foreign = OfflineResourceDescriptor(
          kind: kind,
          id: first.id,
          title: first.title,
          sourceUri: Uri.parse('https://another.example/v1'),
          revision: first.revision,
        );
        final count = fixture.paths.length;
        await expectLater(
          installer.checkRevision(foreign, RequestCancellation()),
          throwsFormatException,
        );
        expect(fixture.paths.length, count);
      },
    );
  }

  test(
    'Study manifest batch expires and forced post-install check remains fresh',
    () async {
      final fixture = StudyInstallationFixture(OfflineResourceKind.dictionary);
      var now = DateTime.utc(2026);
      final installer = StudyResourceInstaller(
        fixture.transport,
        fixture.kind,
        clock: () => now,
      );
      final descriptor = await installer.resolve(
        fixture.kind,
        fixture.module,
        RequestCancellation(),
      );
      expect(fixture.manifestReads, 1);
      await installer.checkRevision(descriptor, RequestCancellation());
      expect(fixture.manifestReads, 1);
      now = now.add(const Duration(minutes: 1));
      await installer.checkRevision(descriptor, RequestCancellation());
      expect(fixture.manifestReads, 2);
      final db = await LocalDatabase.memory();
      addTearDown(db.close);
      final controller = OfflineController(
        store: SqlOfflineResourceStore(db),
        installers: [installer],
      );
      addTearDown(controller.dispose);
      await controller.install(descriptor);
      expect(controller.error, isNull);
      expect(
        fixture.manifestReads,
        3,
        reason: 'Post-install verification bypasses the shared snapshot.',
      );
      final installed = (await SqlOfflineResourceStore(
        db,
      ).listInstalled()).single;
      expect(installed.resource.revision, descriptor.revision);
      installer.clearRevisionCache();
      expect(
        (await installer.checkRevision(
          installed.resource,
          RequestCancellation(),
        )).revision,
        descriptor.revision,
      );
      expect(fixture.manifestReads, 4);
    },
  );

  test(
    'Bible check requests only exact SHA and detects source changes',
    () async {
      final raw = File(
        'test/fixtures/bible_v3/rich_translation.json',
      ).readAsStringSync();
      final catalogue = Map<String, Object?>.from(jsonDecode(raw) as Map)
        ..remove('books');
      var hash = sha1.convert(utf8.encode(raw)).toString();
      catalogue['sha'] = hash;
      final paths = <String>[];
      final transport = ApiTransport(
        client: MockClient((request) async {
          paths.add(request.url.path);
          if (request.url.path.endsWith('/translations.json')) {
            return http.Response(jsonEncode({'fx': catalogue}), 200);
          }
          if (request.url.path.endsWith('/fx.sha')) {
            return http.Response('$hash\n', 200);
          }
          return http.Response('unexpected full download', 500);
        }),
        retryPolicy: const ApiRetryPolicy(maxRetries: 0),
      );
      addTearDown(transport.close);
      final installer = BibleResourceInstaller(transport);
      final descriptor = await installer.resolve(
        OfflineResourceKind.bible,
        'fx',
        RequestCancellation(),
      );
      paths.clear();
      expect(
        (await installer.checkRevision(
          descriptor,
          RequestCancellation(),
        )).revision,
        hash,
      );
      expect(paths, ['/v3/fx.sha']);
      hash = 'b' * 40;
      expect(
        (await installer.checkRevision(
          descriptor,
          RequestCancellation(),
        )).revision,
        hash,
      );
      hash = 'bad';
      await expectLater(
        installer.checkRevision(descriptor, RequestCancellation()),
        throwsFormatException,
      );
      final foreign = OfflineResourceDescriptor(
        kind: descriptor.kind,
        id: descriptor.id,
        title: descriptor.title,
        sourceUri: Uri.parse('https://another.example/v3'),
        revision: descriptor.revision,
      );
      final count = paths.length;
      await expectLater(
        installer.checkRevision(foreign, RequestCancellation()),
        throwsFormatException,
      );
      expect(paths.length, count);
    },
  );
}
