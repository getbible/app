import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:getbible_live/application/app_state.dart';
import 'package:getbible_live/application/commentary_controller.dart';
import 'package:getbible_live/data/api/api_transport.dart';
import 'package:getbible_live/data/api/getbible_api_client.dart';
import 'package:getbible_live/data/database/local_database.dart';
import 'package:getbible_live/domain/models/bible.dart';
import 'package:getbible_live/domain/models/notebook.dart';
import 'package:getbible_live/domain/models/offline_resource.dart';
import 'package:getbible_live/domain/models/online_search.dart';
import 'package:getbible_live/domain/models/passage.dart';
import 'package:getbible_live/domain/models/preferences.dart';
import 'package:getbible_live/domain/models/reference.dart';
import 'package:getbible_live/domain/models/study_context.dart';
import 'package:getbible_live/main.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';

import 'study_installation_fixture.dart';

const _origin = Passage(
  translation: 'fx',
  book: 900000123,
  chapter: 3,
  verse: 7,
);

/// One production AppState composition, exercised by widget CI and the native
/// runner. Only the public HTTP boundary is replaced; installation workers,
/// private backup parsing, SQLite transactions and restart are real.
void offlinePortabilityJourney() {
  testWidgets(
    'installed resources and imported private work survive restart with no HTTP',
    (tester) async {
      tester.view.physicalSize = const Size(1250, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final restoredApp = (await tester.runAsync(() async {
        final fixture = _OfflineAppFixture();
        final directory = await Directory.systemTemp.createTemp(
          'getbible-offline-portability-',
        );
        addTearDown(() => directory.delete(recursive: true));
        final file = File('${directory.path}/restored.sqlite');

        // An export must include the latest open editor without requiring the
        // user to wait for its autosave timer or close the notebook first.
        final source = AppState.fromDatabase(
          await LocalDatabase.memory(),
          api: fixture.api(),
        );
        addTearDown(source.close);
        source.passage = _origin;
        await source.settings.saveLastReadingPosition(
          LastReadingPosition(
            passage: _origin,
            verse: 7,
            updatedAt: DateTime.now().toUtc(),
          ),
        );
        await source.saveMarkingGroup(name: 'Private study', color: '#336699');
        final group = source.groups.singleWhere(
          (item) => item.name == 'Private study',
        );
        final verse = fixture.firstVerse;
        await source.markWholeVerse(verse, 'Extended Book 3:7', group.id);
        await source.saveVerseNote(7, 'Extended Book 3:7', 'My private note');
        await source.study.notebooks.createNotebook(title: 'Travel notebook');
        final notebookId = source.study.notebooks.notebook!.id;
        source.study.notebooks.updateBlockText(
          source.study.notebooks.notebook!.blocks.first.id,
          'Latest unsaved reflection 😀',
        );
        source.study.notebooks.addReference(
          NotebookReference(
            passage: _origin,
            label: 'Extended Book 3:7',
            quotation: verse.text,
          ),
        );
        final backup = await source.portability.exportComplete();
        expect(source.portability.error, isNull);
        expect(backup, isNotNull);
        expect(source.study.notebooks.hasUnsavedDrafts, isFalse);
        expect(fixture.requests, isEmpty, reason: 'Private work stays local.');
        await source.close();

        var restored = AppState.fromDatabase(
          await LocalDatabase.fromExecutor(NativeDatabase(file)),
          api: fixture.api(),
        );
        // Capture each instance, because reassignment follows a real close.
        final beforeRestart = restored;
        addTearDown(beforeRestart.close);
        await restored.study.notebooks.createNotebook(title: 'Already here');
        final existingId = restored.study.notebooks.notebook!.id;
        await restored.offline.discover();
        expect(restored.offline.error, isNull);
        for (final identity in const {
          OfflineResourceKind.bible: 'fx',
          OfflineResourceKind.dictionary: 'strongsgreek',
          OfflineResourceKind.commentary: 'fixture',
          OfflineResourceKind.bookmarks: 'all',
        }.entries) {
          final resource = restored.offline.catalog.singleWhere(
            (item) => item.kind == identity.key && item.id == identity.value,
          );
          await restored.offline.install(resource);
          expect(restored.offline.error, isNull, reason: identity.key.name);
        }
        expect(restored.offline.installed, hasLength(4));
        final generations = {
          for (final item in restored.offline.installed)
            item.resource.key: item.generation,
        };

        await restored.portability.prepareImport(backup!);
        expect(restored.portability.error, isNull);
        expect(restored.portability.preparedImport!.notebooks, hasLength(1));
        expect(await restored.database.getNotebook(notebookId), isNull);
        expect(await restored.database.getNotes(), isEmpty);
        await restored.portability.confirmImport();
        expect(restored.portability.error, isNull);
        expect(restored.portability.importResult, isNotNull);
        expect(await restored.database.getNotebook(existingId), isNotNull);
        expect(
          (await restored.database.getNotebook(notebookId))!.blocks.first.text,
          'Latest unsaved reflection 😀',
        );

        // A real exact-byte integrity failure must retain the activated
        // generation; a later restart cannot accidentally promote its staging.
        fixture.corruptDictionary = true;
        await restored.offline.install(
          restored.offline.catalog.singleWhere(
            (item) =>
                item.kind == OfflineResourceKind.dictionary &&
                item.id == 'strongsgreek',
          ),
        );
        expect(restored.offline.error, isNotNull);
        expect(
          restored.offline.attempts.last.state,
          OfflineAttemptState.failed,
        );
        expect({
          for (final item in restored.offline.installed)
            item.resource.key: item.generation,
        }, generations);

        // Removing opportunistic cache data demonstrates that subsequent
        // results come from complete installations, not earlier online reads.
        await restored.database.clearScriptureCache();
        await restored.close();
        fixture.offline = true;
        final requestCount = fixture.requests.length;
        restored = AppState.fromDatabase(
          await LocalDatabase.fromExecutor(NativeDatabase(file)),
          api: fixture.api(),
        );
        final afterRestart = restored;
        addTearDown(afterRestart.close);
        await restored.initialize();
        expect(restored.error, isNull);
        expect(restored.passage, _origin);
        expect(restored.current!.verses.first.toJson(), verse.toJson());
        expect(restored.chapters.map((item) => item.chapter), [0, 1, 3]);
        expect(restored.notes.single.text, 'My private note');
        expect(restored.markings.single.groupId, group.id);
        expect({
          for (final item in restored.offline.installed)
            item.resource.key: item.generation,
        }, generations);

        await restored.study.notebooks.load();
        await restored.study.notebooks.selectNotebook(notebookId);
        final notebook = restored.study.notebooks.notebook!;
        expect(notebook.blocks.first.text, 'Latest unsaved reflection 😀');
        expect(notebook.blocks.last.reference!.quotation, verse.text);
        expect(
          restored.study.notebooks.notebooks.map((item) => item.id),
          containsAll([existingId, notebookId]),
        );
        final preview = await restored.referenceLookup.lookup(
          notebook.blocks.last.reference!.previewRequest,
        );
        expect(preview.chapters.single.verses.single.toJson(), verse.toJson());
        final grouped = await restored.referenceLookup.lookup(
          const TextReferenceRequest(
            translation: 'fx',
            reference: 'Extended Book 3:7,9',
          ),
        );
        expect(grouped.chapters.single.verses.map((item) => item.verse), [
          7,
          9,
        ]);

        await restored.onlineSearch.search(
          'fx',
          'supplied name',
          criteria: OnlineSearchCriteria(diacritics: SearchDiacritics.exact),
          mode: SearchExecutionMode.installed,
        );
        expect(restored.onlineSearch.error, isNull);
        expect(restored.onlineSearch.results, hasLength(1));
        expect(
          restored.onlineSearch.results.single.verse.toJson(),
          verse.toJson(),
        );

        final context = StudyContext(
          passage: _origin,
          bookName: 'Extended Book',
          language: 'fx',
          verse: restored.current!.verses.first,
          availableBooks: restored.books,
        );
        await restored.study.dictionary.open(context);
        await restored.study.dictionary.selectModule('strongsgreek');
        await restored.study.dictionary.openEntry('G3056--2');
        expect(restored.study.dictionary.error, isNull);
        expect(restored.study.dictionary.isInstalled, isTrue);
        expect(restored.study.dictionary.entry!.occurrence, 2);

        await restored.study.commentary.open(context);
        await restored.study.commentary.selectModule('fixture');
        expect(restored.study.commentary.error, isNull);
        expect(restored.study.commentary.isInstalled, isTrue);
        expect(
          restored.study.commentary.availability,
          CommentaryAvailability.unavailableChapter,
          reason: 'Commentary coverage must not fabricate this extended book.',
        );
        final commentary = await restored.study.commentary.repository.chapter(
          'fixture',
          1,
          1,
        );
        expect(commentary.entriesForVerse(5), hasLength(2));

        await restored.study.topics.initialize(context);
        await restored.study.topics.selectLocale('af');
        await restored.study.topics.selectTopic('faith');
        expect(restored.study.topics.error, isNull);
        expect(restored.study.topics.topicError, isNull);
        expect(restored.study.topics.isInstalled, isTrue);
        expect(restored.study.topics.selectedTopic!.name, 'Faith');
        expect(restored.passage, _origin);
        expect(
          fixture.requests.length,
          requestCount,
          reason: 'Installed operations must issue no HTTP, even failed HTTP.',
        );
        return (state: restored, fixture: fixture, requestCount: requestCount);
      }))!;

      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: restoredApp.state,
          child: const GetBibleApp(),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('supplied'), findsWidgets);
      expect(tester.takeException(), isNull);
      expect(
        restoredApp.fixture.requests.length,
        restoredApp.requestCount,
        reason: 'Rendering the reopened reader must also remain offline.',
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}

/// Serves only published full-resource contract fixtures. There are deliberately
/// no granular Scripture, Query, Search or Study routes to mask missing installs.
final class _OfflineAppFixture {
  _OfflineAppFixture()
    : bible = File(
        'test/fixtures/bible_v3/rich_translation.json',
      ).readAsBytesSync(),
      studies = [
        StudyInstallationFixture(OfflineResourceKind.dictionary),
        StudyInstallationFixture(OfflineResourceKind.commentary),
        StudyInstallationFixture(OfflineResourceKind.bookmarks),
      ];

  final List<int> bible;
  final List<StudyInstallationFixture> studies;
  final List<Uri> requests = [];
  bool offline = false;
  bool corruptDictionary = false;

  Verse get firstVerse {
    final source = jsonDecode(utf8.decode(bible)) as Map;
    final book = (source['books'] as List).first as Map;
    final chapter = (book['chapters'] as List).last as Map;
    return Verse.fromJson(
      (chapter['verses'] as List).first,
      fallbackChapter: 3,
    );
  }

  GetBibleApiClient api() => GetBibleApiClient(
    transport: ApiTransport(
      retryPolicy: const ApiRetryPolicy(maxRetries: 0),
      client: MockClient((request) async {
        requests.add(request.url);
        if (offline) {
          throw const SocketException('HTTP forbidden after restart');
        }
        if (request.url.host == 'api.getbible.net') {
          final hash = sha1.convert(bible).toString();
          if (request.url.path == '/v3/translations.json') {
            final metadata = Map<String, Object?>.from(
              jsonDecode(utf8.decode(bible)) as Map,
            )..remove('books');
            return http.Response(
              jsonEncode({
                'fx': {...metadata, 'sha': hash},
              }),
              200,
            );
          }
          if (request.url.path == '/v3/fx.sha') return http.Response(hash, 200);
          if (request.url.path == '/v3/fx.json') {
            return http.Response.bytes(bible, 200);
          }
        }
        for (final fixture in studies) {
          if (request.url.host != fixture.source.host ||
              !request.url.path.startsWith('/v1/')) {
            continue;
          }
          final path = request.url.path.substring('/v1/'.length);
          final bytes = fixture.documents[path];
          if (bytes == null) break;
          return http.Response.bytes(
            corruptDictionary &&
                    fixture.kind == OfflineResourceKind.dictionary &&
                    path == fixture.bulkPath
                ? [bytes.first ^ 1, ...bytes.skip(1)]
                : bytes,
            200,
          );
        }
        return http.Response('No fixture for ${request.url}', 404);
      }),
    ),
  );
}
