import 'package:flutter_test/flutter_test.dart';
import 'package:getbible/application/grouped_reference_lookup.dart';
import 'package:getbible/core/request_cancellation.dart';
import 'package:getbible/domain/models/bible.dart';
import 'package:getbible/domain/models/cache.dart';
import 'package:getbible/domain/models/passage.dart';
import 'package:getbible/domain/models/reference.dart';
import 'package:getbible/domain/repositories/bible_repository.dart';
import 'package:getbible/domain/repositories/query_repository.dart';

final class TopicVerseFixture implements QueryRepository {
  final List<Passage> requests = [];
  final Set<int> unavailable = {};
  Future<void> Function(Passage)? beforeResponse;
  int active = 0, peak = 0;

  GroupedReferenceLookup get lookup =>
      GroupedReferenceLookup(queryRepository: this, bibleRepository: _Books());

  List<Passage> passages(int count, {String translation = 'kjv'}) => [
    for (var verse = 1; verse <= count; verse++)
      Passage(translation: translation, book: 43, chapter: 8, verse: verse),
  ];

  @override
  Future<ReferenceResult> query(
    String translation,
    String reference, {
    RequestCancellation? cancellation,
  }) async {
    final verse = int.parse(reference.split(':').last);
    final passage = Passage(
      translation: translation,
      book: 43,
      chapter: 8,
      verse: verse,
    );
    requests.add(passage);
    active++;
    if (active > peak) peak = active;
    try {
      await beforeResponse?.call(passage);
      if (unavailable.contains(verse)) {
        throw const ReferenceLookupException('Unavailable');
      }
      return ReferenceResult.fromJson(
        {
          '${translation}_43_8': {
            'book_nr': 43,
            'book_name': 'John',
            'chapter': 8,
            'verses': [
              {
                'verse': verse,
                'name': 'John 8:$verse',
                'text':
                    '$translation full Scripture for verse $verse. Second sentence remains visible.',
              },
            ],
          },
        },
        translation: translation,
        reference: reference,
      );
    } finally {
      active--;
    }
  }
}

class _Books extends Fake implements BibleRepository {
  @override
  Future<RepositoryResult<List<BibleBook>>> getBooks(
    String translation, {
    bool forceRefresh = false,
  }) async => RepositoryResult(
    data: const [BibleBook(number: 43, name: 'John', sha: 'fixture')],
    freshness: CacheFreshness.fresh,
    checkedAt: DateTime.utc(2026),
  );
}
