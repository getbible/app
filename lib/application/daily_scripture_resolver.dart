import '../domain/models/bible.dart';
import '../domain/models/cache.dart';
import '../domain/models/passage.dart';
import '../domain/models/reference.dart';
import 'grouped_reference_lookup.dart';

/// Resolves source aliases through Query v3's typed boundary. Local matching
/// only accepts a discovered book name; no canonical book is ever guessed.
final class DailyScriptureResolver {
  const DailyScriptureResolver(this.lookup);

  final GroupedReferenceLookup lookup;

  Future<Passage> resolve(
    DailyScriptureCache daily,
    List<BibleBook> books,
  ) async {
    BibleBook? book = books
        .where((BibleBook item) => bookMatchesSlug(item.name, daily.bookName))
        .firstOrNull;
    if (book == null) {
      final ReferenceResult result = await lookup.lookup(
        TextReferenceRequest(
          translation: 'kjv',
          reference:
              '${daily.bookName} ${daily.chapter}:${_selection(daily.verses)}',
        ),
      );
      final ReferenceChapter? chapter = result.chapters.length == 1
          ? result.chapters.single
          : null;
      if (chapter != null &&
          chapter.chapter == daily.chapter &&
          chapter.verses.length == daily.verses.length &&
          daily.verses.every(
            (int verse) =>
                chapter.verses.any((Verse item) => item.verse == verse),
          )) {
        book = books
            .where((BibleBook item) => item.number == chapter.bookNumber)
            .firstOrNull;
      }
    }
    if (book == null) {
      throw ReferenceLookupException(
        'The daily Scripture reference “${daily.bookName} ${daily.chapter}” '
        'is unavailable in KJV. Your reading position has been kept.',
      );
    }
    return Passage(
      translation: 'kjv',
      book: book.number,
      chapter: daily.chapter,
      verse: daily.verse,
    ).validated();
  }

  String _selection(List<int> verses) {
    final List<String> ranges = <String>[];
    for (int index = 0; index < verses.length; index++) {
      final int first = verses[index];
      while (index + 1 < verses.length &&
          verses[index + 1] == verses[index] + 1) {
        index++;
      }
      final int last = verses[index];
      ranges.add(first == last ? '$first' : '$first-$last');
    }
    return ranges.join(',');
  }
}
