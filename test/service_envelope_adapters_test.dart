import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:getbible_live/core/errors.dart';
import 'package:getbible_live/core/json.dart';
import 'package:getbible_live/data/api/api_transport.dart';
import 'package:getbible_live/data/api/service_envelope_adapters.dart';
import 'package:getbible_live/domain/models/service_envelopes.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  late JsonMap fixtures;
  setUp(() {
    fixtures = requireJsonMap(
      jsonDecode(
        File('test/fixtures/service_envelopes.json').readAsStringSync(),
      ),
      'native service fixture',
    );
  });

  test(
    'catalogue native wrappers retain capability/attribution fields and zeros',
    () {
      final DictionaryCatalogue dictionaries =
          ServiceEnvelopeAdapters.dictionaries(fixtures['dictionaries']);
      expect(dictionaries.modules.single.entryCount, 0);
      expect(dictionaries.modules.single.bytes, 0);
      expect(dictionaries.modules.single.strongPrefix, isNull);
      expect(dictionaries.modules.single.license, 'Public Domain');
      expect(
        dictionaries.source['entry_url_template'],
        '{dictionary}/{entry}.json',
      );
      final CommentaryCatalogue commentaries =
          ServiceEnvelopeAdapters.commentaries(fixtures['commentaries']);
      expect(commentaries.modules.single.bookCount, 0);
      expect(commentaries.modules.single.chapterCount, 0);
      expect(
        commentaries.source['chapter_url_template'],
        '{commentary}/{book}/{chapter}.json',
      );
      expect(
        jsonDecode(jsonEncode(dictionaries.source)),
        fixtures['dictionaries'],
      );
      expect(
        jsonDecode(jsonEncode(commentaries.source)),
        fixtures['commentaries'],
      );
    },
  );

  test(
    'public catalogue preserves explicit false and counts instead of coordinates',
    () {
      final PublicTopicCatalogue catalogue =
          ServiceEnvelopeAdapters.publicTopics(fixtures['bookmarks']);
      expect(catalogue.topics.single.isDefault, false);
      expect(catalogue.topics.single.verseCount, 0);
      expect(catalogue.topics.single.id, 'fixture-topic');
      expect(jsonDecode(jsonEncode(catalogue.source)), fixtures['bookmarks']);
      final JsonMap invalid = requireJsonMap(fixtures['bookmarks'], 'topics');
      final JsonMap topic = requireJsonMap(
        (invalid['topics'] as List).single,
        'topic',
      );
      topic['verses'] = <Object?>[
        <int>[1, 1, 1],
      ];
      invalid['topics'] = <Object?>[topic];
      expect(
        () => ServiceEnvelopeAdapters.publicTopics(invalid),
        throwsA(isA<ApiFormatException>()),
      );
    },
  );

  test('unknown additive source fields are retained deeply immutable', () {
    final JsonMap dictionary = requireJsonMap(
      fixtures['dictionaries'],
      'catalogue',
    );
    dictionary['future'] = <String, Object?>{
      'values': <Object?>[false, 0, ' text  \n'],
    };
    final DictionaryCatalogue result = ServiceEnvelopeAdapters.dictionaries(
      dictionary,
    );
    final Map<String, Object?> future =
        result.source['future'] as Map<String, Object?>;
    expect((future['values'] as List).last, ' text  \n');
    expect(() => future['values'] = null, throwsUnsupportedError);
    expect(
      () => (future['values'] as List).add('changed'),
      throwsUnsupportedError,
    );
  });

  test(
    'full-text envelope preserves match ranking, coordinates and source versions',
    () {
      final SearchEnvelope envelope = ServiceEnvelopeAdapters.search(
        fixtures['search'],
      );
      expect(envelope.kind, SearchResultKind.search);
      expect(envelope.translation, 'tst');
      expect(envelope.matches.map((SearchApiMatch match) => match.book), <int>[
        2,
        1,
      ]);
      expect(envelope.matches.first.score, 2.5);
      expect(envelope.matches.first.terms, <String>['faith', 'hope']);
      expect(
        envelope.chapters['tst_1_1']!.verses.single.text,
        'First  \nverse.',
      );
      expect(envelope.offset, 0);
      expect(envelope.hasMore, false);
      expect(envelope.sourceSha, isNull);
      expect(envelope.engineVersion, 5);
      expect(jsonDecode(jsonEncode(envelope.source)), fixtures['search']);
    },
  );

  test(
    'reference envelopes need no pagination or scoring; empty search succeeds',
    () {
      final SearchEnvelope reference = ServiceEnvelopeAdapters.search(
        fixtures['search_reference'],
      );
      expect(reference.kind, SearchResultKind.reference);
      expect(reference.offset, isNull);
      expect(reference.limit, isNull);
      expect(reference.hasMore, isNull);
      expect(reference.matches.single.score, isNull);
      final SearchEnvelope empty = ServiceEnvelopeAdapters.search(
        fixtures['search_empty'],
      );
      expect(empty.total, 0);
      expect(empty.returned, 0);
      expect(empty.chapters, isEmpty);
      expect(empty.matches, isEmpty);
      expect(empty.hasMore, false);
    },
  );

  test('minimal compact Search keeps optional metadata absent', () {
    final SearchEnvelope compact = ServiceEnvelopeAdapters.search(
      fixtures['search_compact'],
    );
    expect(compact.translation, isNull);
    expect(compact.chapters.values.single.bookName, isNull);
    expect(compact.chapters.values.single.name, isNull);
    expect(compact.chapters.values.single.bookNumber, 101);
    expect(compact.chapters.values.single.chapter, 1);
    expect(compact.chapters.values.single.verses.single.verse, 1);
    final SearchEnvelope contextual = ServiceEnvelopeAdapters.search(
      fixtures['search_compact'],
      selectedTranslation: 'tst',
    );
    expect(contextual.translation, 'tst');
    expect(
      jsonDecode(jsonEncode(contextual.source)),
      fixtures['search_compact'],
    );
  });

  test('documented optional search metadata can be omitted', () {
    final JsonMap fixture = requireJsonMap(fixtures['search'], 'search');
    final JsonMap query = requireJsonMap(fixture['query'], 'query');
    query.remove('offset');
    query.remove('limit');
    query.remove('has_more');
    fixture['query'] = query;
    fixture['matches'] = (fixture['matches'] as List).map((Object? value) {
      final JsonMap match = requireJsonMap(value, 'match');
      match.remove('score');
      match.remove('occurrences');
      match.remove('terms');
      return match;
    }).toList();
    final SearchEnvelope result = ServiceEnvelopeAdapters.search(fixture);
    expect(result.offset, isNull);
    expect(result.limit, isNull);
    expect(result.hasMore, isNull);
    expect(result.matches.first.score, isNull);
  });

  test(
    'missing matching verse and invalid catalogue schema are typed failures',
    () {
      final JsonMap search = requireJsonMap(fixtures['search'], 'search');
      search['results'] = <String, Object?>{};
      expect(
        () => ServiceEnvelopeAdapters.search(search),
        throwsA(isA<ApiFormatException>()),
      );
      final JsonMap dictionary = requireJsonMap(
        fixtures['dictionaries'],
        'catalogue',
      );
      dictionary['schema'] = 'unknown-format';
      expect(
        () => ServiceEnvelopeAdapters.dictionaries(dictionary),
        throwsA(isA<ApiFormatException>()),
      );
    },
  );

  test(
    'catalogue repository uses correct service routes without bulk requests',
    () async {
      final List<Uri> requests = <Uri>[];
      final ApiTransport transport = ApiTransport(
        client: MockClient((http.Request request) async {
          requests.add(request.url);
          final Object? fixture = switch (request.url.host) {
            'dictionaries.getbible.net' => fixtures['dictionaries'],
            'commentaries.getbible.net' => fixtures['commentaries'],
            'bookmarks.getbible.net' => fixtures['bookmarks'],
            _ => throw StateError('Unexpected service.'),
          };
          return http.Response(jsonEncode(fixture), 200);
        }),
      );
      final ApiStudyResourcesRepository repository =
          ApiStudyResourcesRepository(transport);
      await repository.getDictionaries();
      await repository.getCommentaries();
      await repository.getPublicTopics();
      expect(requests.map((Uri uri) => uri.path), <String>[
        '/v1/dictionaries.json',
        '/v1/commentaries.json',
        '/v1/topics.json',
      ]);
      expect(requests.length, 3);
    },
  );
}
