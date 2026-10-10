import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:getbible/application/commentary_controller.dart';
import 'package:getbible/application/dictionary_controller.dart';
import 'package:getbible/core/request_cancellation.dart';
import 'package:getbible/data/database/local_database.dart';
import 'package:getbible/data/repositories/api_commentary_repository.dart';
import 'package:getbible/data/repositories/installed_study_repositories.dart';
import 'package:getbible/domain/models/commentary.dart';
import 'package:getbible/domain/models/dictionary.dart';
import 'package:getbible/domain/models/offline_resource.dart';
import 'package:getbible/domain/models/passage.dart';
import 'package:getbible/domain/models/reference.dart';
import 'package:getbible/domain/models/service_envelopes.dart';
import 'package:getbible/domain/models/study_context.dart';
import 'package:getbible/domain/repositories/commentary_repository.dart';
import 'package:getbible/domain/repositories/dictionary_repository.dart';
import 'package:getbible/domain/repositories/installed_study_resource.dart';

import 'support/dictionary_fixture.dart';
import 'support/study_installation_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final initiallyInstalled in [true, false]) {
    test(
      'dictionary navigation adopts a new generation from ${initiallyInstalled ? 'installed' : 'online'} content',
      () async {
        final db = await LocalDatabase.memory();
        addTearDown(db.close);
        final fixture = StudyInstallationFixture(
          OfflineResourceKind.dictionary,
        );
        final online = DictionaryFixture();
        addTearDown(online.close);
        if (initiallyInstalled) await fixture.install(db);
        final repository = _PausedDictionary(
          InstalledDictionaryRepository(
            store: SqlOfflineResourceStore(db),
            sourceUri: fixture.source,
            online: online.repository,
          ),
        );
        final controller = DictionaryController(
          repository: repository,
          preferences: MemoryStudyPreferences(),
        );
        addTearDown(controller.dispose);
        await controller.open(dictionaryContext(strongs: ['G3056']));
        expect(controller.error, isNull);
        final visible = controller.entry;
        _replaceEntry(fixture, 'G4487', 'Updated entry from generation B.');
        await fixture.install(db);
        await controller.refreshInstallationStatus();
        expect(controller.entry, same(visible));
        final requestedBefore = online.requests.length;
        final pause = Completer<void>();
        repository.pauseMetadata = pause.future;
        repository.metadataStarted = Completer<void>();
        final navigation = controller.openEntry('G4487');
        await repository.metadataStarted!.future;
        expect(controller.entry, same(visible));
        expect(controller.isLoading, isTrue);
        pause.complete();
        await navigation;
        expect(controller.error, isNull);
        expect(controller.entry!.text, 'Updated entry from generation B.');
        expect(controller.entry!.id, 'G4487');
        expect(
          online.requests.length,
          requestedBefore,
          reason: 'A completed installation answers locally.',
        );
      },
    );
  }

  test(
    'removed entry in replacement generation is unavailable without substitution',
    () async {
      final db = await LocalDatabase.memory();
      addTearDown(db.close);
      final fixture = StudyInstallationFixture(OfflineResourceKind.dictionary);
      final online = DictionaryFixture();
      addTearDown(online.close);
      await fixture.install(db);
      final repository = InstalledDictionaryRepository(
        store: SqlOfflineResourceStore(db),
        sourceUri: fixture.source,
        online: online.repository,
      );
      final controller = DictionaryController(
        repository: repository,
        preferences: MemoryStudyPreferences(),
      );
      addTearDown(controller.dispose);
      await controller.open(dictionaryContext(strongs: ['G3056']));
      final visible = controller.entry;
      _removeEntry(fixture, 'G4487');
      await fixture.install(db);
      await controller.openEntry('G4487');
      expect(controller.entry, same(visible));
      expect(controller.error, isA<ReferenceLookupException>());
      expect(
        controller.error.toString(),
        contains('not in the dictionary index'),
      );
    },
  );

  test(
    'a second activation during recovery stops after one restart and can retry',
    () async {
      final db = await LocalDatabase.memory();
      addTearDown(db.close);
      final fixture = StudyInstallationFixture(OfflineResourceKind.dictionary);
      final online = DictionaryFixture();
      addTearDown(online.close);
      await fixture.install(db);
      final repository = _PausedDictionary(
        InstalledDictionaryRepository(
          store: SqlOfflineResourceStore(db),
          sourceUri: fixture.source,
          online: online.repository,
        ),
      );
      final controller = DictionaryController(
        repository: repository,
        preferences: MemoryStudyPreferences(),
      );
      addTearDown(controller.dispose);
      await controller.open(dictionaryContext(strongs: ['G3056']));
      final visible = controller.entry;
      _replaceEntry(fixture, 'G4487', 'Revision B');
      await fixture.install(db);
      final before = repository.metadataReads;
      repository.beforeIndex = () async {
        repository.beforeIndex = null;
        _replaceEntry(fixture, 'G4487', 'Revision C');
        await fixture.install(db);
      };
      await controller.openEntry('G4487');
      expect(controller.error, isA<InstalledStudyGenerationChanged>());
      expect(controller.entry, same(visible));
      expect(repository.metadataReads, before + 1);
      await controller.retry();
      expect(controller.error, isNull);
      expect(controller.entry!.text, 'Revision C');
    },
  );
  test(
    'commentary restarts metadata and coverage together across an activation',
    () async {
      final db = await LocalDatabase.memory();
      addTearDown(db.close);
      final fixture = StudyInstallationFixture(OfflineResourceKind.commentary);
      await fixture.install(db);
      final repository = _RacingCommentary(
        InstalledCommentaryRepository(
          store: SqlOfflineResourceStore(db),
          sourceUri: fixture.source,
          online: ApiCommentaryRepository(fixture.transport),
        ),
      );
      final controller = CommentaryController(
        repository: repository,
        preferences: MemoryStudyPreferences(),
      );
      addTearDown(controller.dispose);
      await controller.open(
        const StudyContext(
          passage: Passage(translation: 'kjv', book: 1, chapter: 1, verse: 5),
          bookName: 'Genesis',
          language: 'en',
          translationName: 'KJV',
        ),
      );
      expect(controller.error, isNull);
      final reads = repository.metadataReads;
      repository.updated = Completer<void>();
      repository.afterMetadata = () async {
        repository.afterMetadata = null;
        final bulk =
            jsonDecode(utf8.decode(fixture.documents[fixture.bulkPath]!))
                as Map;
        final chapter =
            (((bulk['books'] as List).first as Map)['chapters'] as List)
                .cast<Map<String, dynamic>>()
                .singleWhere((chapter) => chapter['chapter'] == 1);
        ((chapter['entries'] as List)[1] as Map)['text'] =
            'Updated commentary from generation B.';
        fixture.documents[fixture.bulkPath] = utf8.encode(jsonEncode(bulk));
        fixture.updateSizesAndManifest();
        await fixture.install(db);
        repository.updated!.complete();
      };
      await controller.selectModule(fixture.module);
      expect(controller.error, isNull);
      expect(repository.metadataReads, reads + 2);
      expect(
        controller.chapter!.entries[1].text,
        'Updated commentary from generation B.',
      );
    },
  );
}

void _replaceEntry(StudyInstallationFixture fixture, String id, String text) {
  final bulk =
      jsonDecode(utf8.decode(fixture.documents[fixture.bulkPath]!)) as Map;
  ((bulk['entries'] as List).cast<Map<String, dynamic>>().singleWhere(
    (entry) => entry['id'] == id,
  ))['text'] = text;
  fixture.documents[fixture.bulkPath] = utf8.encode(jsonEncode(bulk));
  fixture.updateSizesAndManifest();
}

void _removeEntry(StudyInstallationFixture fixture, String id) {
  final bulk =
      jsonDecode(utf8.decode(fixture.documents[fixture.bulkPath]!)) as Map;
  (bulk['entries'] as List).removeWhere((entry) => (entry as Map)['id'] == id);
  for (final entry in (bulk['entries'] as List).cast<Map<String, dynamic>>()) {
    for (final field in ['see_also', 'backlinks']) {
      (entry[field] as List?)?.removeWhere((link) => (link as Map)['id'] == id);
    }
  }
  fixture.documents[fixture.bulkPath] = utf8.encode(jsonEncode(bulk));
  final indexPath = '${fixture.module}/index.json';
  final index = jsonDecode(utf8.decode(fixture.documents[indexPath]!)) as Map;
  (index['entries'] as List).removeWhere((entry) => (entry as Map)['id'] == id);
  index['entry_count'] = 2;
  index['unique_key_count'] = 1;
  fixture.documents[indexPath] = utf8.encode(jsonEncode(index));
  final metadataPath = '${fixture.module}/metadata.json';
  final metadata =
      jsonDecode(utf8.decode(fixture.documents[metadataPath]!)) as Map;
  metadata['entry_count'] = 2;
  metadata['unique_key_count'] = 1;
  fixture.documents[metadataPath] = utf8.encode(jsonEncode(metadata));
  final catalogue =
      jsonDecode(utf8.decode(fixture.documents['dictionaries.json']!)) as Map;
  final module = (catalogue['dictionaries'] as List)
      .cast<Map<String, dynamic>>()
      .singleWhere((item) => item['id'] == fixture.module);
  module['entry_count'] = 2;
  module['unique_key_count'] = 1;
  fixture.documents['dictionaries.json'] = utf8.encode(jsonEncode(catalogue));
  fixture.updateSizesAndManifest();
}

final class _PausedDictionary
    implements
        DictionaryRepository,
        InstalledStudyResource,
        DictionaryLookupSession {
  _PausedDictionary(this.delegate);
  final InstalledDictionaryRepository delegate;
  Future<void>? pauseMetadata;
  Completer<void>? metadataStarted;
  Future<void> Function()? beforeIndex;
  int metadataReads = 0;
  @override
  void beginLookup() => delegate.beginLookup();
  @override
  Future<bool> isInstalled(String id) => delegate.isInstalled(id);
  @override
  Future<DictionaryCatalogue> catalogue({RequestCancellation? cancellation}) =>
      delegate.catalogue(cancellation: cancellation);
  @override
  Future<DictionaryMetadata> metadata(
    String module, {
    RequestCancellation? cancellation,
  }) async {
    metadataReads++;
    if (metadataStarted case final started? when !started.isCompleted) {
      started.complete();
    }
    await pauseMetadata;
    return delegate.metadata(module, cancellation: cancellation);
  }

  @override
  Future<DictionaryIndex> index(
    String module, {
    RequestCancellation? cancellation,
  }) async {
    await beforeIndex?.call();
    return delegate.index(module, cancellation: cancellation);
  }

  @override
  Future<DictionaryEntry> entry(
    String module,
    String id, {
    RequestCancellation? cancellation,
  }) => delegate.entry(module, id, cancellation: cancellation);
}

final class _RacingCommentary
    implements CommentaryRepository, InstalledStudyResource {
  _RacingCommentary(this.delegate);
  final InstalledCommentaryRepository delegate;
  Completer<void>? updated;
  Future<void> Function()? afterMetadata;
  int metadataReads = 0;
  @override
  Future<bool> isInstalled(String id) => delegate.isInstalled(id);
  @override
  Future<CommentaryCatalogue> catalogue({RequestCancellation? cancellation}) =>
      delegate.catalogue(cancellation: cancellation);
  @override
  Future<CommentaryMetadata> metadata(
    String module, {
    RequestCancellation? cancellation,
  }) async {
    metadataReads++;
    final metadata = await delegate.metadata(
      module,
      cancellation: cancellation,
    );
    await afterMetadata?.call();
    return metadata;
  }

  @override
  Future<CommentaryCoverage> coverage(
    String module, {
    RequestCancellation? cancellation,
  }) async {
    await updated?.future;
    return delegate.coverage(module, cancellation: cancellation);
  }

  @override
  Future<CommentaryChapter> chapter(
    String module,
    int book,
    int chapter, {
    RequestCancellation? cancellation,
  }) => delegate.chapter(module, book, chapter, cancellation: cancellation);
}
