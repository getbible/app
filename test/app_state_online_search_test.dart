import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:getbible/application/app_state.dart';
import 'package:getbible/core/json.dart';
import 'package:getbible/data/database/local_database.dart';
import 'package:getbible/domain/models/passage.dart';
import 'package:getbible/domain/models/search.dart';
import 'package:http/http.dart' as http;

import 'support/reader_api_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'AppState online search reuses the injected reader transport without a corpus or annotation changes',
    () async {
      final List<Uri> searchRequests = <Uri>[];
      final JsonMap envelopes = requireJsonMap(
        jsonDecode(
          File('test/fixtures/service_envelopes.json').readAsStringSync(),
        ),
        'service fixture',
      );
      final ReaderApiFixture fixture = ReaderApiFixture(
        resourceResponse: (http.Request request) async {
          if (request.url.host != 'search.getbible.net') return null;
          searchRequests.add(request.url);
          return http.Response(jsonEncode(envelopes['search_reference']), 200);
        },
      );
      final LocalDatabase database = await LocalDatabase.memory();
      final AppState state = AppState.fromDatabase(database, api: fixture.api);
      addTearDown(state.close);
      const Passage original = Passage(
        translation: 'tst',
        book: 1,
        chapter: 1,
        verse: 3,
      );
      await state.loadPassage(original);
      final beforePosition = await state.settings.getLastReadingPosition();
      final beforeNotes = await state.annotations.getNotes();
      final beforeMarkings = await state.annotations.getMarkings();
      final beforeGroups = await state.annotations.getGroups();
      fixture.paths.clear();

      await state.search(
        '  Fixture Book 1:1  ',
        const SearchOptions(
          words: SearchWordMode.phrase,
          match: SearchMatchMode.exact,
          scope: SearchScope.book(ReaderApiFixture.extendedBook),
          locale: 'unsupported-online-locale',
        ),
      );

      expect(searchRequests.single.host, 'search.getbible.net');
      expect(searchRequests.single.path, '/v3/tst');
      expect(
        searchRequests.single.queryParameters['q'],
        '  Fixture Book 1:1  ',
      );
      expect(searchRequests.single.queryParameters['match'], 'whole_word');
      expect(
        searchRequests.single.queryParameters['book'],
        '${ReaderApiFixture.extendedBook}',
      );
      expect(
        searchRequests.single.queryParameters.containsKey('locale'),
        false,
      );
      expect(fixture.paths, <String>['/v3/tst']);
      expect(state.searchError, isNull);
      expect(state.searchLoading, false);
      expect(state.searchComplete, true);
      expect(state.searchResultCount, 1);
      expect(state.searchResults.single.verse, 1);
      expect(state.onlineSearch.results.single.verse.text, 'First verse.');
      await state.loadMoreSearchResults();
      expect(searchRequests, hasLength(1));
      expect(state.passage, original);
      final afterPosition = await state.settings.getLastReadingPosition();
      expect(afterPosition?.passage, beforePosition?.passage);
      expect(afterPosition?.updatedAt, beforePosition?.updatedAt);
      expect(
        (await state.annotations.getNotes()).map((item) => item.toJson()),
        beforeNotes.map((item) => item.toJson()),
      );
      expect(
        (await state.annotations.getMarkings()).map((item) => item.toJson()),
        beforeMarkings.map((item) => item.toJson()),
      );
      expect(
        (await state.annotations.getGroups()).map((item) => item.toJson()),
        beforeGroups.map((item) => item.toJson()),
      );
    },
  );

  test(
    'dismissing the composed search cannot activate late search hits',
    () async {
      final Completer<void> started = Completer<void>();
      final Completer<http.Response> delayed = Completer<http.Response>();
      final ReaderApiFixture fixture = ReaderApiFixture(
        resourceResponse: (http.Request request) async {
          if (request.url.host != 'search.getbible.net') return null;
          started.complete();
          return delayed.future;
        },
      );
      final LocalDatabase database = await LocalDatabase.memory();
      final AppState state = AppState.fromDatabase(database, api: fixture.api);
      addTearDown(state.close);
      await state.loadPassage(
        const Passage(translation: 'tst', book: 1, chapter: 1),
      );
      final Future<void> search = state.search('faith', const SearchOptions());
      await started.future;
      state.onlineSearch.clear();
      final JsonMap envelopes = requireJsonMap(
        jsonDecode(
          File('test/fixtures/service_envelopes.json').readAsStringSync(),
        ),
        'service fixture',
      );
      delayed.complete(http.Response(jsonEncode(envelopes['search']), 200));
      await search;
      expect(state.searchResults, isEmpty);
      expect(state.searchLoading, false);
      expect(state.passage.translation, 'tst');
    },
  );
}
