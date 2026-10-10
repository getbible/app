import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:getbible/core/errors.dart';
import 'package:getbible/core/json.dart';
import 'package:getbible/data/api/commentary_adapter.dart';
import 'package:getbible/data/api/dictionary_adapters.dart';
import 'package:getbible/data/api/public_topic_adapter.dart';
import 'package:getbible/data/database/local_database.dart';
import 'package:getbible/data/repositories/api_commentary_repository.dart';
import 'package:getbible/data/repositories/api_dictionary_repository.dart';
import 'package:getbible/data/repositories/api_public_topics_repository.dart';
import 'package:getbible/data/repositories/installed_study_repositories.dart';
import 'package:getbible/data/repositories/sql_public_topic_copy_repository.dart';
import 'package:getbible/domain/models/annotations.dart';
import 'package:getbible/domain/models/offline_resource.dart';
import 'package:getbible/domain/models/passage.dart';
import 'package:getbible/domain/repositories/installed_study_resource.dart';

import 'support/study_installation_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'complete dictionary retains repeated IDs, aliases, citations and independent source after restart',
    () async {
      final fixture = StudyInstallationFixture(OfflineResourceKind.dictionary);
      final directory = await Directory.systemTemp.createTemp(
        'installed-study-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/private.sqlite');
      var database = await LocalDatabase.fromExecutor(NativeDatabase(file));
      await fixture.install(database);
      final installed = await SqlOfflineResourceStore(database).listInstalled();
      expect(
        installed.single.resource.estimatedBytes,
        fixture.documents['strongsgreek.json']!.length,
      );
      expect(fixture.paths.where((path) => path.contains('G3056')), isEmpty);
      await database.close();
      database = await LocalDatabase.fromExecutor(NativeDatabase(file));
      addTearDown(database.close);
      fixture.offline = true;
      final repository = InstalledDictionaryRepository(
        store: SqlOfflineResourceStore(database),
        sourceUri: fixture.source,
        online: ApiDictionaryRepository(fixture.transport),
      );
      final requestCount = fixture.paths.length;
      expect((await repository.catalogue()).modules, hasLength(5));
      final metadata = await repository.metadata('strongsgreek');
      final index = await repository.index('strongsgreek');
      final entry = await repository.entry('strongsgreek', 'G3056--2');
      final onlineEntry = DictionaryAdapters.entry(
        _json('dictionaries_v1/strongsgreek/G3056--2.json'),
        'strongsgreek',
        'G3056--2',
      );
      expect(
        index.entries.where((entry) => entry.key == 'λόγος'),
        hasLength(2),
      );
      expect(entry.text, onlineEntry.text);
      expect(entry.aliases, onlineEntry.aliases);
      expect(entry.occurrence, 2);
      expect(metadata.referenceApi, 'getbible-v2');
      expect(
        (await repository.entry(
          'strongsgreek',
          'G3056',
        )).references.single.osis,
        'John.1.1',
      );
      expect(
        fixture.paths.length,
        requestCount,
        reason: 'Cold installed lookup must not wait for network discovery.',
      );
      await expectLater(
        repository.entry('strongsgreek', 'missing'),
        throwsA(isA<StorageException>()),
      );
      expect(
        fixture.paths.length,
        requestCount,
        reason: 'A missing installed entry cannot mix online revisions.',
      );
    },
  );

  test(
    'large installed indexes normalize in worker batches and retain exact aliases',
    () async {
      final fixture = StudyInstallationFixture(OfflineResourceKind.dictionary);
      final database = await LocalDatabase.memory();
      addTearDown(database.close);
      final store = SqlOfflineResourceStore(database);
      final descriptor = OfflineResourceDescriptor(
        kind: OfflineResourceKind.dictionary,
        id: 'large',
        title: 'Large dictionary',
        sourceUri: fixture.source,
        revision: 'fixture',
      );
      final index = <String, Object?>{
        'schema': 'getbible-dictionary-index-v1',
        'dictionary': 'large',
        'language': 'en',
        'name': 'Large dictionary',
        'entry_url_template': '{entry}.json',
        'entry_count': 5000,
        'unique_key_count': 5000,
        'entries': [
          for (var i = 0; i < 5000; i++)
            {
              'id': 'entry-$i',
              'key': 'Élan $i',
              'search': 'elan $i',
              'aliases': ['Alternative $i'],
            },
        ],
      };
      final raw = jsonEncode(index);
      expect(raw.length, greaterThan(256 * 1024));
      await store.begin(
        descriptor,
        'large-generation',
        quotaBytes: 4 * 1024 * 1024,
      );
      await store.writeDocument(
        'large-generation',
        'index.json',
        raw,
        quotaBytes: 4 * 1024 * 1024,
      );
      await store.activate('large-generation');
      fixture.offline = true;
      final repository = InstalledDictionaryRepository(
        store: store,
        sourceUri: fixture.source,
        online: ApiDictionaryRepository(fixture.transport),
      );
      final parsed = await repository.index('large');
      expect(parsed.entries, hasLength(5000));
      expect(parsed.entryById('entry-4999')!.aliases, ['Alternative 4999']);
      expect(
        parsed.lookupKeysAt(4999),
        DictionaryAdapters.index(index, 'large').lookupKeysAt(4999),
      );
      expect(fixture.paths, isEmpty);
    },
  );

  test(
    'whole commentary preserves sparse coverage, introductions, ranges and exact source entries',
    () async {
      final fixture = StudyInstallationFixture(OfflineResourceKind.commentary);
      final database = await LocalDatabase.memory();
      addTearDown(database.close);
      await fixture.install(database);
      fixture.offline = true;
      final repository = InstalledCommentaryRepository(
        store: SqlOfflineResourceStore(database),
        sourceUri: fixture.source,
        online: ApiCommentaryRepository(fixture.transport),
      );
      expect((await repository.catalogue()).modules.single.id, 'fixture');
      expect(
        (await repository.metadata('fixture')).references.api,
        'getbible-v2',
      );
      final coverage = await repository.coverage('fixture');
      expect(coverage.covers(1, 0), isTrue);
      expect(coverage.covers(43, 1), isFalse);
      final chapter = await repository.chapter('fixture', 1, 1);
      final source = _json('commentary_v1.json');
      final online = CommentaryAdapter.chapter(
        source['chapter'],
        'fixture',
        1,
        1,
      );
      expect(chapter.source, online.source);
      expect(chapter.entriesForVerse(5), hasLength(2));
      expect(
        (await repository.chapter(
          'fixture',
          1,
          0,
        )).entries.single.isIntroduction,
        isTrue,
      );
      await expectLater(
        repository.chapter('fixture', 43, 1),
        throwsA(isA<StorageException>()),
      );
      expect(
        fixture.paths.where(
          (path) => RegExp(r'/\d+/\d+\.json$').hasMatch(path),
        ),
        isEmpty,
      );
    },
  );

  test(
    'complete topics derive localized names, all associations and empty canonical chapters',
    () async {
      final fixture = StudyInstallationFixture(OfflineResourceKind.bookmarks);
      final database = await LocalDatabase.memory();
      addTearDown(database.close);
      await fixture.install(database);
      fixture.offline = true;
      final repository = InstalledPublicTopicsRepository(
        store: SqlOfflineResourceStore(database),
        sourceUri: fixture.source,
        online: ApiPublicTopicsRepository(fixture.transport),
      );
      expect((await repository.discovery()).associationCount, 4);
      expect(
        (await repository.catalogue()).topics.map((topic) => topic.verseCount),
        [3, 1],
      );
      expect(
        (await repository.locales())
            .singleWhere((locale) => locale.code == 'af')
            .topicCount,
        1,
      );
      expect((await repository.names('af')).names, {
        'authority-of-the-bible': 'Gesag van die Bybel',
      });
      final faith = await repository.topic('faith');
      expect(faith.localizedName('af'), 'Faith');
      final expected = PublicTopicAdapter.topic(
        _json('public_topic_single.json'),
        expectedId: 'authority-of-the-bible',
      );
      final topic = await repository.topic(expected.id);
      expect(topic.names, expected.names);
      expect(
        topic.coordinates.map((value) => value.key),
        expected.coordinates.map((value) => value.key),
      );
      expect((await repository.chapter(43, 3)).forVerse(16), {
        'authority-of-the-bible',
        'faith',
      });
      expect((await repository.chapter(1, 2)).verses, isEmpty);
      await expectLater(repository.chapter(65, 2), throwsFormatException);
      await expectLater(
        repository.names('de'),
        throwsA(isA<StorageException>()),
      );
      expect(
        fixture.paths.where(
          (path) => path.contains('/topics/') || path.contains('/verses/'),
        ),
        isEmpty,
      );
    },
  );

  test(
    'wrong exact-byte digest and a rotating manifest cannot replace a working installation',
    () async {
      final fixture = StudyInstallationFixture(OfflineResourceKind.dictionary);
      final database = await LocalDatabase.memory();
      addTearDown(database.close);
      await fixture.install(database);
      final store = SqlOfflineResourceStore(database);
      final first = (await store.listInstalled()).single;
      fixture.corruptBody = true;
      final controller = await fixture.install(database, expectSuccess: false);
      expect(controller.error, contains('SHA-256'));
      expect((await store.listInstalled()).single.generation, first.generation);
      fixture.corruptBody = false;
      fixture.rotateManifest = true;
      fixture.manifestReads = 0;
      final rotation = await fixture.install(database, expectSuccess: false);
      expect(rotation.error, contains('changed during installation'));
      expect((await store.listInstalled()).single.generation, first.generation);
    },
  );

  test(
    'valid checksums cannot activate incomplete dictionary, commentary or topic indexes',
    () async {
      for (final kind in [
        OfflineResourceKind.dictionary,
        OfflineResourceKind.commentary,
        OfflineResourceKind.bookmarks,
      ]) {
        final fixture = StudyInstallationFixture(kind);
        final database = await LocalDatabase.memory();
        addTearDown(database.close);
        await fixture.install(database);
        final store = SqlOfflineResourceStore(database);
        final original = (await store.listInstalled()).single;
        final bulk = requireJsonMap(
          jsonDecode(utf8.decode(fixture.documents[fixture.bulkPath]!)),
          'bulk',
        );
        if (kind == OfflineResourceKind.dictionary) {
          (bulk['entries']! as List).removeLast();
        }
        if (kind == OfflineResourceKind.commentary) {
          (bulk['books']! as List).removeLast();
        }
        if (kind == OfflineResourceKind.bookmarks) {
          (bulk['topics']! as List).removeLast();
        }
        fixture.documents[fixture.bulkPath] = utf8.encode(jsonEncode(bulk));
        fixture.updateSizesAndManifest();
        final failed = await fixture.install(database, expectSuccess: false);
        expect(failed.error, isNotNull);
        expect(
          (await store.listInstalled()).single.generation,
          original.generation,
        );
      }
    },
  );

  test(
    'removing an installed public dataset preserves independent private copied groups and notes',
    () async {
      final fixture = StudyInstallationFixture(OfflineResourceKind.bookmarks);
      final database = await LocalDatabase.memory();
      addTearDown(database.close);
      await fixture.install(database);
      final topic = PublicTopicAdapter.topic(
        _json('public_topic_single.json'),
        expectedId: 'authority-of-the-bible',
      );
      final copies = SqlPublicTopicCopyRepository(database);
      final preview = await copies.preview(
        topic: topic,
        sourceScope: 'bookmarks:v1:${fixture.source}',
        translation: 'kjv',
      );
      final copied = await copies.copy(preview);
      await database.saveNote(
        VerseNote(
          id: 'keep-note',
          passage: const Passage(translation: 'kjv', book: 1, chapter: 1),
          verse: 1,
          reference: 'Genesis 1:1',
          text: 'My independent private note',
          createdAt: DateTime.utc(2026),
          updatedAt: DateTime.utc(2026),
        ),
      );
      final beforeGroups = (await database.getGroups())
          .map((item) => item.toJson())
          .toList();
      final beforeMarkings = (await database.getMarkings())
          .map((item) => item.toJson())
          .toList();
      final store = SqlOfflineResourceStore(database);
      final resource = (await store.listInstalled()).single;
      await store.remove(resource.resource.key);
      expect(await store.listInstalled(), isEmpty);
      expect(
        (await database.getGroups()).map((item) => item.toJson()),
        beforeGroups,
      );
      expect(
        (await database.getMarkings()).map((item) => item.toJson()),
        beforeMarkings,
      );
      expect((await database.getNotes()).single.text, contains('independent'));
      final repeated = await copies.copy(preview);
      expect(repeated.groupId, copied.groupId);
      expect(repeated.added, 0);
    },
  );

  test(
    'a replaced generation never produces false empty topic associations',
    () async {
      final fixture = StudyInstallationFixture(OfflineResourceKind.bookmarks);
      final database = await LocalDatabase.memory();
      addTearDown(database.close);
      await fixture.install(database);
      final store = SqlOfflineResourceStore(database);
      final repository = InstalledPublicTopicsRepository(
        store: store,
        sourceUri: fixture.source,
        online: ApiPublicTopicsRepository(fixture.transport),
      );
      await repository.discovery();
      await fixture.install(database);
      await expectLater(
        repository.chapter(1, 2),
        throwsA(isA<InstalledStudyGenerationChanged>()),
      );
      await repository.discovery();
      expect((await repository.chapter(1, 2)).verses, isEmpty);
    },
  );
}

JsonMap _json(String path) => requireJsonMap(
  jsonDecode(File('test/fixtures/$path').readAsStringSync()),
  path,
);
