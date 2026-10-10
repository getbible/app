import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:getbible/core/errors.dart';
import 'package:getbible/core/json.dart';
import 'package:getbible/data/api/api_transport.dart';
import 'package:getbible/data/api/dictionary_adapters.dart';
import 'package:getbible/data/repositories/api_dictionary_repository.dart';
import 'package:getbible/domain/models/dictionary.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'support/dictionary_fixture.dart';

void main() {
  test(
    'native catalogue, metadata, index and exact IDs use only on-demand files',
    () async {
      final DictionaryFixture fixture = DictionaryFixture();
      addTearDown(fixture.close);
      expect((await fixture.repository.catalogue()).modules.length, 5);
      final DictionaryMetadata metadata = await fixture.repository.metadata(
        'strongsgreek',
      );
      final DictionaryIndex index = await fixture.repository.index(
        'strongsgreek',
      );
      final DictionaryEntry entry = await fixture.repository.entry(
        'strongsgreek',
        'G3056',
      );
      expect(metadata.referenceApi, 'getbible-v2');
      expect(index.entries.length, 3);
      expect(entry.text, 'Word; speech.\n\nA second paragraph.');
      expect(entry.seeAlso.single.id, 'G4487');
      expect(entry.references.single.text, 'John 1:1');
      expect(fixture.requests.map((Uri uri) => uri.path), <String>[
        '/v1/dictionaries.json',
        '/v1/strongsgreek/metadata.json',
        '/v1/strongsgreek/index.json',
        '/v1/strongsgreek/G3056.json',
      ]);
      expect(fixture.requests.every((Uri uri) => uri.query.isEmpty), isTrue);
      expect(
        (await fixture.repository.entry('strongshebrew', 'H0430')).id,
        'H0430',
      );
    },
  );

  test(
    'wrong identities, missing text, repeated IDs and malformed references reject',
    () {
      final JsonMap wrong = dictionaryJson('strongsgreek/G3056.json')
        ..['id'] = 'G1';
      expect(
        () => DictionaryAdapters.entry(wrong, 'strongsgreek', 'G3056'),
        throwsFormatException,
      );
      final JsonMap missingText = dictionaryJson('strongsgreek/G3056.json')
        ..remove('text');
      expect(
        () => DictionaryAdapters.entry(missingText, 'strongsgreek', 'G3056'),
        throwsFormatException,
      );
      final JsonMap index = dictionaryJson('strongsgreek/index.json');
      final List<Object?> entries = requireJsonList(
        index['entries'],
        'entries',
      );
      entries[1] = entries[0];
      index['entries'] = entries;
      expect(
        () => DictionaryAdapters.index(index, 'strongsgreek'),
        throwsFormatException,
      );
      final JsonMap wrongReference = dictionaryJson('strongsgreek/G3056.json');
      wrongReference['references'] = <Object?>[
        <String, Object?>{
          'ref': 'John 1:1',
          'osis': 'John.1.1',
          'book': 43,
          'chapter': 1,
          'verse': 1,
          'verses': <int>[2, 3],
        },
      ];
      expect(
        () => DictionaryAdapters.entry(wrongReference, 'strongsgreek', 'G3056'),
        throwsFormatException,
      );
    },
  );

  test(
    'malformed fresh-cache body is discarded and Retry gets corrected content',
    () async {
      int calls = 0;
      final ApiTransport transport = ApiTransport(
        client: MockClient((http.Request request) async {
          calls++;
          final JsonMap entry = dictionaryJson('strongsgreek/G3056.json');
          if (calls == 1) entry['dictionary'] = 'wrong';
          return http.Response.bytes(
            utf8.encode(jsonEncode(entry)),
            200,
            headers: <String, String>{'cache-control': 'max-age=600'},
          );
        }),
      );
      addTearDown(transport.close);
      final ApiDictionaryRepository repository = ApiDictionaryRepository(
        transport,
      );
      await expectLater(
        repository.entry('strongsgreek', 'G3056'),
        throwsA(isA<ApiFormatException>()),
      );
      expect((await repository.entry('strongsgreek', 'G3056')).id, 'G3056');
      await repository.entry('strongsgreek', 'G3056');
      expect(calls, 2);
    },
  );

  test('missing entry is a typed 404, not an empty definition', () async {
    final DictionaryFixture fixture = DictionaryFixture();
    addTearDown(fixture.close);
    await expectLater(
      fixture.repository.entry('strongsgreek', 'missing'),
      throwsA(isA<ResourceUnavailableException>()),
    );
    expect(
      () => fixture.repository.entry('strongsgreek', '../G3056'),
      throwsFormatException,
    );
  });
}
