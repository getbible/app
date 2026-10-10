import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:getbible/application/dictionary_lookup.dart';
import 'package:getbible/core/errors.dart';
import 'package:getbible/core/request_cancellation.dart';
import 'package:getbible/data/offline/dictionary_index_reader.dart';

void main() {
  test(
    'large online/local index uses worker and preserves exact IDs, folded aliases and duplicate entries',
    () async {
      final source = <String, Object?>{
        'schema': 'getbible-dictionary-index-v1',
        'dictionary': 'fixture',
        'language': 'en',
        'name': 'Fixture',
        'entry_url_template': '{entry}.json',
        'entry_count': 5001,
        'unique_key_count': 5000,
        'entries': <Object?>[
          for (var number = 0; number < 5000; number++)
            {
              'id': 'published-$number',
              'key': 'Word $number',
              'search': 'word $number',
              'aliases': ['Wórd $number'],
            },
          {
            'id': 'second-source-id',
            'key': 'Word 42',
            'search': 'word 42',
            'aliases': ['Wórd 42'],
            'occurrence': 2,
          },
        ],
      };
      final bytes = utf8.encode(jsonEncode(source));
      expect(bytes.length, greaterThan(256 * 1024));
      final index = await readDictionaryIndex(bytes, 'fixture');
      expect(index.entries.length, 5001);
      final matches = DictionaryIndexLookup.exact(index, ['Wórd 42']);
      expect(matches.map((entry) => entry.id), [
        'published-42',
        'second-source-id',
      ]);
      expect(index.entryById('second-source-id')!.occurrence, 2);
      final cancelled = RequestCancellation()..cancel();
      await expectLater(
        readDictionaryIndex(bytes, 'fixture', cancellation: cancelled),
        throwsA(isA<RequestCancelledException>()),
      );
    },
  );
}
