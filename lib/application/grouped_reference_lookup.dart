import '../core/request_cancellation.dart';
import '../domain/models/bible.dart';
import '../domain/models/reference.dart';
import '../domain/repositories/bible_repository.dart';
import '../domain/repositories/query_repository.dart';

/// Resolves one user interaction atomically. Structured citations use book names
/// discovered in the chosen Bible, while retaining the source-language label.
final class GroupedReferenceLookup {
  GroupedReferenceLookup({
    required this.queryRepository,
    required this.bibleRepository,
    this.maxReferencesPerRequest = 8,
    this.maxVersesPerRequest = 200,
    this.maxReferenceCharacters = 512,
    this.maxPreviewVerses = 2000,
  }) {
    if (maxReferencesPerRequest < 1 ||
        maxReferencesPerRequest > 8 ||
        maxVersesPerRequest < 1 ||
        maxVersesPerRequest > 200 ||
        maxReferenceCharacters < 1 ||
        maxReferenceCharacters > 512 ||
        maxPreviewVerses < 1 ||
        maxPreviewVerses > 10000) {
      throw ArgumentError(
        'Reference limits must fit the published Query bounds.',
      );
    }
  }

  final QueryRepository queryRepository;
  final BibleRepository bibleRepository;
  final int maxReferencesPerRequest;
  final int maxVersesPerRequest;
  final int maxReferenceCharacters;
  final int maxPreviewVerses;

  Future<ReferenceResult> lookup(
    ReferenceRequest request, {
    RequestCancellation? cancellation,
  }) async {
    final String translation = request.translation.toLowerCase();
    if (!RegExp(r'^[a-z0-9_-]+$').hasMatch(translation)) {
      throw const FormatException('Select a valid Bible translation.');
    }
    cancellation?.throwIfCancelled();
    if (request is TextReferenceRequest) {
      final String reference = request.reference.trim();
      _validateText(reference);
      final ReferenceResult result = await queryRepository.query(
        translation,
        reference,
        cancellation: cancellation,
      );
      cancellation?.throwIfCancelled();
      _validateResult(result, translation);
      return result;
    }
    final StructuredReferenceRequest structured =
        request as StructuredReferenceRequest;
    if (structured.selections.isEmpty) {
      throw const FormatException('Select at least one verse to preview.');
    }
    final Set<String> expected = <String>{};
    for (final ReferenceSelection selection in structured.selections) {
      for (final int verse in selection.verses) {
        expected.add('${selection.book}/${selection.chapter}/$verse');
        if (expected.length > maxPreviewVerses) {
          throw ReferenceLookupException(
            'This preview is too large. Select up to $maxPreviewVerses verses.',
          );
        }
      }
    }
    final Future<List<BibleBook>> bookOperation = bibleRepository
        .getBooks(translation)
        .then((result) => result.data);
    final List<BibleBook> books = cancellation == null
        ? await bookOperation
        : await cancellation.bind(bookOperation);
    final Map<int, String> names = <int, String>{
      for (final BibleBook book in books) book.number: book.name,
    };
    final List<_ReferenceRange> ranges = _ranges(structured.selections, names);
    final List<String> batches = _batches(ranges);
    final List<ReferenceResult> results = <ReferenceResult>[];
    // Sequential batches bound concurrency and make cancellation effective
    // before the next request. Nothing is published until every batch succeeds.
    for (final String reference in batches) {
      cancellation?.throwIfCancelled();
      final ReferenceResult result = await queryRepository.query(
        translation,
        reference,
        cancellation: cancellation,
      );
      cancellation?.throwIfCancelled();
      _validateResult(result, translation);
      results.add(result);
    }
    final ReferenceResult result = _merge(results, translation, batches, names);
    final Set<String> actual = <String>{
      for (final ReferenceChapter chapter in result.chapters)
        for (final Verse verse in chapter.verses)
          '${chapter.bookNumber}/${chapter.chapter}/${verse.verse}',
    };
    if (actual.length != expected.length || !actual.containsAll(expected)) {
      throw const ReferenceLookupException(
        'Some selected verses are unavailable in this translation. '
        'The preview could not be completed.',
      );
    }
    return result;
  }

  void _validateText(String reference) {
    final List<String> parts = reference.split(';');
    if (reference.isEmpty ||
        reference.runes.length > maxReferenceCharacters ||
        parts.length > maxReferencesPerRequest ||
        parts.any((String part) => part.trim().isEmpty) ||
        RegExp(r'[\x00-\x1f\x7f]').hasMatch(reference)) {
      throw ReferenceLookupException(
        'Enter up to $maxReferencesPerRequest references using no more than '
        '$maxReferenceCharacters characters. Split larger text citations into smaller previews.',
      );
    }
  }

  void _validateResult(ReferenceResult result, String translation) {
    if (result.translation != translation ||
        result.chapters.isEmpty ||
        result.verseCount > maxVersesPerRequest) {
      throw const ReferenceLookupException(
        'The reference response does not match the selected translation or request limits.',
      );
    }
  }

  List<_ReferenceRange> _ranges(
    List<ReferenceSelection> selections,
    Map<int, String> names,
  ) {
    final Map<String, Set<int>> grouped = <String, Set<int>>{};
    final Map<String, ReferenceSelection> identities =
        <String, ReferenceSelection>{};
    for (final ReferenceSelection selection in selections) {
      final String key = '${selection.book}/${selection.chapter}';
      grouped.putIfAbsent(key, () => <int>{}).addAll(selection.verses);
      identities[key] = selection;
    }
    final List<_ReferenceRange> result = <_ReferenceRange>[];
    for (final MapEntry<String, Set<int>> entry in grouped.entries) {
      final ReferenceSelection selection = identities[entry.key]!;
      final String? name = names[selection.book];
      if (name == null || name.trim().isEmpty || name.contains(';')) {
        throw const ReferenceLookupException(
          'The cited book is unavailable in the selected Bible translation.',
        );
      }
      final List<int> verses = entry.value.toList()..sort();
      int start = verses.first;
      int end = start;
      void addRange() {
        final String suffix = start == end ? '$start' : '$start-$end';
        final String text = '$name ${selection.chapter}:$suffix';
        if (text.runes.length > maxReferenceCharacters) {
          throw const ReferenceLookupException(
            'This Bible book name exceeds the reference service request limit.',
          );
        }
        result.add(_ReferenceRange(text, end - start + 1));
      }

      for (final int verse in verses.skip(1)) {
        if (verse == end + 1 && verse - start < maxVersesPerRequest) {
          end = verse;
        } else {
          addRange();
          start = end = verse;
        }
      }
      addRange();
    }
    return result;
  }

  List<String> _batches(List<_ReferenceRange> ranges) {
    final List<String> result = <String>[];
    final List<String> pending = <String>[];
    int verseCount = 0;
    for (final _ReferenceRange range in ranges) {
      final String combined = <String>[...pending, range.text].join(';');
      if (pending.isNotEmpty &&
          (pending.length >= maxReferencesPerRequest ||
              verseCount + range.verseCount > maxVersesPerRequest ||
              combined.runes.length > maxReferenceCharacters)) {
        result.add(pending.join(';'));
        pending.clear();
        verseCount = 0;
      }
      pending.add(range.text);
      verseCount += range.verseCount;
    }
    if (pending.isNotEmpty) result.add(pending.join(';'));
    return result;
  }

  ReferenceResult _merge(
    List<ReferenceResult> results,
    String translation,
    List<String> batches,
    Map<int, String> names,
  ) {
    final Map<String, ReferenceChapter> chapters = <String, ReferenceChapter>{};
    for (final ReferenceResult result in results) {
      for (final ReferenceChapter chapter in result.chapters) {
        final ReferenceChapter? previous = chapters[chapter.key];
        final Map<int, Verse> verses = <int, Verse>{
          if (previous != null)
            for (final Verse verse in previous.verses) verse.verse: verse,
        };
        for (final Verse verse in chapter.verses) {
          final Verse? existing = verses[verse.verse];
          if (existing != null &&
              !_sameJson(existing.toJson(), verse.toJson())) {
            throw const ReferenceLookupException(
              'Scripture changed while loading this preview. Please try again.',
            );
          }
          verses[verse.verse] = verse;
        }
        final List<Verse> ordered = verses.values.toList()
          ..sort(
            (Verse left, Verse right) => left.verse.compareTo(right.verse),
          );
        chapters[chapter.key] = ReferenceChapter(
          key: chapter.key,
          bookNumber: chapter.bookNumber,
          chapter: chapter.chapter,
          verses: ordered,
          references: <String>{...?previous?.references, ...chapter.references},
          bookName: chapter.bookName.isNotEmpty
              ? chapter.bookName
              : previous?.bookName.isNotEmpty == true
              ? previous!.bookName
              : names[chapter.bookNumber] ?? '',
          direction: chapter.metadata.containsKey('direction')
              ? chapter.direction
              : previous?.direction ?? chapter.direction,
          metadata: <String, Object?>{
            ...?previous?.metadata,
            ...chapter.metadata,
          },
        );
      }
    }
    return ReferenceResult(
      translation: translation,
      chapters: chapters.values,
      requestedReferences: batches,
    );
  }

  bool _sameJson(Object? left, Object? right) {
    if (left is Map && right is Map) {
      return left.length == right.length &&
          left.keys.every(
            (Object? key) =>
                right.containsKey(key) && _sameJson(left[key], right[key]),
          );
    }
    if (left is List && right is List) {
      return left.length == right.length &&
          List<bool>.generate(
            left.length,
            (int index) => _sameJson(left[index], right[index]),
          ).every((bool same) => same);
    }
    return left == right;
  }
}

final class _ReferenceRange {
  const _ReferenceRange(this.text, this.verseCount);
  final String text;
  final int verseCount;
}
