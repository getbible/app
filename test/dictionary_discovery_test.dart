import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:getbible_live/application/dictionary_discovery.dart';
import 'package:getbible_live/core/errors.dart';
import 'package:getbible_live/core/request_cancellation.dart';
import 'package:getbible_live/domain/models/dictionary.dart';
import 'package:getbible_live/domain/models/service_envelopes.dart';
import 'package:getbible_live/domain/repositories/dictionary_repository.dart';

void main() {
  test(
    'choices require exact nonempty definitions; duplicates and partial failures survive',
    () async {
      final repository = _Repository();
      final modules = [
        _module('greek', count: 2),
        _module('surface'),
        _module('empty'),
        _module('unavailable'),
        _module('deleted'),
        _module('unrelated'),
      ];
      repository.entries['greek'] = [
        _entry('greek', 'published-a', 'First definition'),
        _entry('greek', 'published-b', 'Second definition'),
      ];
      repository.entries['surface'] = [
        _entry('surface', 'original', 'Surface definition'),
      ];
      repository.entries['empty'] = [_entry('empty', 'original', '  \n')];
      repository.entries['deleted'] = [_entry('deleted', 'original', 'unused')];
      repository.entries['unrelated'] = [
        _entry('unrelated', 'other', 'Wrong word', key: 'another'),
      ];
      repository.errors['unavailable'] = const NetworkException(
        'temporarily unavailable',
      );
      repository.entryErrors['deleted'] = HttpStatusException(
        statusCode: 404,
        uri: Uri.parse('https://example.test/deleted'),
        message: 'not found',
      );
      final result = await DictionaryDiscovery(repository).lookup(
        modules: modules,
        candidates: ['G3056', 'λόγος'],
        query: 'λόγος',
        cancellation: RequestCancellation(),
      );
      expect(result.matches.map((match) => match.module.id), [
        'greek',
        'surface',
      ]);
      expect(result.matches.first.definitions.map((entry) => entry.id), [
        'published-a',
        'published-b',
      ]);
      expect(result.unavailable, ['unavailable']);
      expect(result.complete, isTrue);
      expect(result.suggestions, isEmpty);
      expect(
        repository.entryReads.every((id) => !id.endsWith('/G3056')),
        isTrue,
        reason: 'Lexical candidates cannot fabricate entry IDs.',
      );
    },
  );

  test(
    'four workers bound lookup; cancellation stops queued resources and late progress',
    () async {
      final repository = _Repository()..holdIndexes = true;
      final modules = List.generate(9, (index) => _module('m$index'));
      final cancellation = RequestCancellation();
      final progress = <DictionaryDiscoveryResult>[];
      final lookup = DictionaryDiscovery(repository).lookup(
        modules: modules,
        candidates: ['λόγος'],
        query: 'λόγος',
        cancellation: cancellation,
        onProgress: progress.add,
      );
      final cancelled = expectLater(
        lookup,
        throwsA(isA<RequestCancelledException>()),
      );
      await Future<void>.delayed(Duration.zero);
      expect(repository.indexReads, ['m0', 'm1', 'm2', 'm3']);
      cancellation.cancel();
      await cancelled;
      for (final pending in repository.pending.values) {
        pending.complete(_index('unused', const []));
      }
      await Future<void>.delayed(Duration.zero);
      expect(repository.indexReads.length, 4);
      expect(repository.entryReads, isEmpty);
      expect(progress, isEmpty);
    },
  );

  test(
    'confirmed resources publish before a slower index completes and cache is revision scoped',
    () async {
      final repository = _Repository();
      repository.entries['fast'] = [_entry('fast', 'original', 'A definition')];
      repository.entries['slow'] = [
        _entry('slow', 'original', 'Another definition'),
      ];
      repository.pending['slow'] = Completer<DictionaryIndex>();
      final discovery = DictionaryDiscovery(repository);
      final modules = [_module('fast'), _module('slow')];
      final progress = <DictionaryDiscoveryResult>[];
      final task = discovery.lookup(
        modules: modules,
        publication: 'revision-1',
        candidates: ['λόγος'],
        query: 'λόγος',
        cancellation: RequestCancellation(),
        onProgress: progress.add,
      );
      await Future<void>.delayed(Duration.zero);
      expect(
        progress.any(
          (result) => result.matches.any((match) => match.module.id == 'fast'),
        ),
        isTrue,
      );
      expect(progress.every((result) => !result.complete), isTrue);
      repository.pending
          .remove('slow')!
          .complete(_index('slow', repository.entries['slow']!));
      expect((await task).matches.length, 2);
      await discovery.lookup(
        modules: modules,
        publication: 'revision-1',
        candidates: ['λόγος'],
        query: 'λόγος',
        cancellation: RequestCancellation(),
      );
      expect(repository.indexReads.length, 2);
      await discovery.lookup(
        modules: modules,
        publication: 'revision-2',
        candidates: ['λόγος'],
        query: 'λόγος',
        cancellation: RequestCancellation(),
      );
      expect(repository.indexReads.length, 4);
    },
  );

  test(
    'index admission budget remains bounded and suggests explicit browsing',
    () async {
      final repository = _Repository();
      final result = await DictionaryDiscovery(repository).lookup(
        modules: [
          _module('oversized', count: DictionaryDiscovery.maxIndexEntries + 1),
        ],
        candidates: ['word'],
        query: 'word',
        cancellation: RequestCancellation(),
      );
      expect(result.limitReached, isTrue);
      expect(result.unavailable, ['oversized']);
      expect(repository.indexReads, isEmpty);
    },
  );

  test(
    'prefix suggestions are bounded and never appear as confirmed resources',
    () async {
      final repository = _Repository();
      repository.entries['prefix'] = List.generate(
        30,
        (number) => _entry(
          'prefix',
          'id$number',
          'Definition $number',
          key: 'word$number',
        ),
      );
      final result = await DictionaryDiscovery(repository).lookup(
        modules: [_module('prefix', count: 30)],
        candidates: ['word'],
        query: 'word',
        cancellation: RequestCancellation(),
      );
      expect(result.matches, isEmpty);
      expect(result.suggestions.length, DictionaryDiscovery.maxSuggestions);
      expect(repository.entryReads, isEmpty);
    },
  );
}

DictionaryModule _module(String id, {int count = 1}) => DictionaryModule(
  id: id,
  name: id,
  language: 'en',
  license: 'Public domain',
  entryCount: count,
  uniqueKeyCount: count,
  strongPrefix: null,
  bytes: 100,
  source: {},
);
DictionaryEntry _entry(
  String module,
  String id,
  String text, {
  String key = 'λόγος',
}) => DictionaryEntry(
  dictionary: module,
  language: 'en',
  id: id,
  key: key,
  occurrence: 1,
  text: text,
  aliases: const ['G3056'],
);
DictionaryIndex _index(String module, List<DictionaryEntry> entries) =>
    DictionaryIndex(
      dictionary: module,
      language: 'en',
      name: module,
      uniqueKeyCount: entries.length,
      entries: entries.map(
        (entry) => DictionaryIndexEntry(
          id: entry.id,
          key: entry.key,
          search: entry.key,
          aliases: entry.key == 'λόγος' ? entry.aliases : const [],
        ),
      ),
    );

final class _Repository implements DictionaryRepository {
  final entries = <String, List<DictionaryEntry>>{};
  final errors = <String, Object>{};
  final entryErrors = <String, Object>{};
  final pending = <String, Completer<DictionaryIndex>>{};
  final indexReads = <String>[];
  final entryReads = <String>[];
  bool holdIndexes = false;
  @override
  Future<DictionaryIndex> index(
    String module, {
    RequestCancellation? cancellation,
  }) async {
    indexReads.add(module);
    if (errors[module] case final error?) throw error;
    if (holdIndexes) pending[module] = Completer<DictionaryIndex>();
    if (pending[module] case final value?) return value.future;
    return _index(module, entries[module] ?? const []);
  }

  @override
  Future<DictionaryEntry> entry(
    String module,
    String id, {
    RequestCancellation? cancellation,
  }) async {
    entryReads.add('$module/$id');
    if (entryErrors[module] case final error?) throw error;
    return entries[module]!.firstWhere((entry) => entry.id == id);
  }

  @override
  Future<DictionaryCatalogue> catalogue({RequestCancellation? cancellation}) =>
      throw UnimplementedError();
  @override
  Future<DictionaryMetadata> metadata(
    String module, {
    RequestCancellation? cancellation,
  }) => throw UnimplementedError();
}
