import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:getbible/application/app_state.dart';
import 'package:getbible/data/database/local_database.dart';
import 'package:getbible/domain/models/offline_resource.dart';
import 'package:getbible/domain/models/online_search.dart';
import 'package:getbible/domain/models/passage.dart';
import 'package:getbible/domain/models/preferences.dart';
import 'package:http/http.dart' as http;

import 'support/reader_api_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'startup reads immediately while its selected Bible downloads once',
    () async {
      final body = jsonEncode({
        'abbreviation': 'tst',
        'translation': 'Fixture Bible',
        'language': 'English',
        'lang': 'en',
        'direction': 'LTR',
        'books': [
          {
            'nr': 1,
            'name': 'Genesis',
            'chapters': [
              {
                'chapter': 1,
                'name': 'Genesis 1',
                'verses': [
                  {'verse': 1, 'text': ' First verse. ', 'name': 'Genesis 1:1'},
                  {
                    'verse': 3,
                    'text': 'Verse 3 original.',
                    'name': 'Genesis 1:3',
                  },
                ],
              },
            ],
          },
        ],
      });
      final bulkStarted = Completer<void>();
      final bulkResponse = Completer<http.Response>();
      final fixture = ReaderApiFixture(
        beforeResponse: (request) async {
          if (request.url.path == '/v3/tst.sha') {
            return http.Response(
              sha1.convert(utf8.encode(body)).toString(),
              200,
            );
          }
          if (request.url.path == '/v3/tst.json') {
            bulkStarted.complete();
            return bulkResponse.future;
          }
          return null;
        },
      );
      final state = AppState.fromDatabase(
        await LocalDatabase.memory(),
        api: fixture.api,
      );
      addTearDown(state.close);
      const passage = Passage(
        translation: 'tst',
        book: 1,
        chapter: 1,
        verse: 3,
      );
      await state.settings.saveLastReadingPosition(
        LastReadingPosition(
          passage: passage,
          verse: 3,
          updatedAt: DateTime.now().toUtc(),
        ),
      );
      await state.initialize().timeout(const Duration(seconds: 5));
      expect(state.error, isNull);
      expect(state.loading, isFalse);
      expect(state.passage, passage);
      expect(state.current!.verses.last.text, 'Verse 3 original.');
      await bulkStarted.future.timeout(const Duration(seconds: 5));
      expect(bulkResponse.isCompleted, isFalse);
      final download = state.offline.ensureAvailable(
        OfflineResourceKind.bible,
        'tst',
      );
      // Navigating within the same translation joins the same background job.
      await state.loadPassage(passage.copyWith(verse: 1));
      bulkResponse.complete(http.Response(body, 200));
      await download;
      expect(
        await state.bibles.installed!.contains('tst'),
        isTrue,
        reason: state.offline.failures.toString(),
      );
      expect(
        fixture.paths.where((path) => path == '/v3/tst.json'),
        hasLength(1),
      );
      expect(
        state.onlineSearch.defaultModeFor('tst'),
        SearchExecutionMode.installed,
      );
      expect(
        state.offline.installed.any(
          (item) => item.resource.kind == OfflineResourceKind.bookmarks,
        ),
        isFalse,
      );
      expect(fixture.paths, isNot(contains('/v1/all.json')));
    },
  );

  test(
    'an invalid passage does not select a Bible for background acquisition',
    () async {
      final fixture = ReaderApiFixture();
      final state = AppState.fromDatabase(
        await LocalDatabase.memory(),
        api: fixture.api,
      );
      addTearDown(state.close);
      await state.loadPassage(
        const Passage(translation: 'tst', book: 1, chapter: 1, verse: 2),
      );
      expect(state.error, contains('verse is not available'));
      expect(state.current, isNull);
      expect(fixture.paths, isNot(contains('/v3/tst.sha')));
      expect(fixture.paths, isNot(contains('/v3/tst.json')));
      expect(state.offline.installed, isEmpty);
    },
  );

  test(
    'a passage begun before clearing downloads cannot restart acquisition',
    () async {
      final started = Completer<void>();
      final release = Completer<void>();
      var hold = true;
      final fixture = ReaderApiFixture(
        beforeResponse: (request) async {
          if (request.url.path == '/v3/tst/books.json' && hold) {
            started.complete();
            await release.future;
          }
          return null;
        },
      );
      final state = AppState.fromDatabase(
        await LocalDatabase.memory(),
        api: fixture.api,
      );
      addTearDown(state.close);
      const passage = Passage(translation: 'tst', book: 1, chapter: 1);
      final navigation = state.loadPassage(passage);
      await started.future;
      await state.offline.clearDownloads();
      hold = false;
      release.complete();
      await navigation;
      expect(state.error, isNull);
      expect(state.current, isNotNull);
      expect(fixture.paths, isNot(contains('/v3/tst.sha')));
      expect(fixture.paths, isNot(contains('/v3/tst.json')));
      // A genuinely new reader action after Clear can prepare this Bible again.
      await state.loadPassage(passage.copyWith(verse: 3));
      await state.offline.ensureAvailable(OfflineResourceKind.bible, 'tst');
      expect(fixture.paths, contains('/v3/tst.sha'));
    },
  );
}
