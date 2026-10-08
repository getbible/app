import '../domain/models/bible.dart';

String chapterMarkdown(BibleChapter chapter, Translation translation) {
  return scriptureMarkdown(chapter, translation, 0, chapter.verses.length - 1);
}

String scriptureMarkdown(
  BibleChapter chapter,
  Translation translation,
  int firstIndex,
  int lastIndex,
) {
  if (firstIndex < 0 ||
      lastIndex < firstIndex ||
      lastIndex >= chapter.verses.length) {
    throw RangeError.range(lastIndex, firstIndex, chapter.verses.length - 1);
  }
  final List<Verse> verses = chapter.verses.sublist(firstIndex, lastIndex + 1);
  final String reference = verses.length == chapter.verses.length
      ? '${chapter.bookName} ${chapter.chapter}'
      : verses.length == 1
      ? '${chapter.bookName} ${chapter.chapter}:${verses.first.verse}'
      : '${chapter.bookName} ${chapter.chapter}:${verses.first.verse}\u2013${verses.last.verse}';
  final String body = verses
      .map((Verse verse) => '${verse.verse}. ${verse.text.trim()}')
      .join('\n');
  final List<String> footer = <String>[
    if (translation.translation.trim().isNotEmpty)
      '**${translation.translation.trim()}**',
    if (translation.distributionLicense.trim().isNotEmpty)
      translation.distributionLicense
          .trim()
          .split(RegExp(r'\r?\n'))
          .map((String line) => '> $line')
          .join('\n'),
  ];
  return '# $reference\n\n$body${footer.isEmpty ? '' : '\n\n---\n${footer.join('\n\n')}'}';
}

String chapterMarkdownFilename(BibleChapter chapter) {
  final String book = chapter.bookName
      .trim()
      .replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');
  return '$book-${chapter.chapter}.md';
}
