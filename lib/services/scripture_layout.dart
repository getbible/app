import '../domain/models/bible.dart';

sealed class ScriptureReadingBlock {
  const ScriptureReadingBlock();
}

final class ScriptureHeadingBlock extends ScriptureReadingBlock {
  const ScriptureHeadingBlock(this.heading);

  final EditorialHeading heading;
}

/// Verse IDs belong to the emitted source, rather than list indexes.
final class ScriptureParagraphBlock extends ScriptureReadingBlock {
  const ScriptureParagraphBlock(this.verses);

  final List<Verse> verses;
}

/// Produces source-ordered headings and paragraphs for either reader layout.
///
/// Heading anchors always precede their actual emitted verse, never a fabricated
/// coordinate. A heading within a paragraph splits the visible block there.
/// When explicit ranges are absent, per-verse paragraph markers are used. Plain
/// translations remain a continuous paragraph and can still use line rendering.
final class ScriptureChapterLayout {
  ScriptureChapterLayout(BibleChapter chapter) : blocks = _build(chapter);

  final List<ScriptureReadingBlock> blocks;

  static List<ScriptureReadingBlock> _build(BibleChapter chapter) {
    final List<EditorialHeading> headings =
        <EditorialHeading>[...?chapter.editorial?.headings]..sort(
          (EditorialHeading left, EditorialHeading right) =>
              left.order.compareTo(right.order),
        );
    final List<EditorialParagraph> paragraphs =
        <EditorialParagraph>[...?chapter.editorial?.paragraphs]..sort(
          (EditorialParagraph left, EditorialParagraph right) =>
              left.order.compareTo(right.order),
        );
    final List<ScriptureReadingBlock> result = <ScriptureReadingBlock>[];
    List<Verse> current = <Verse>[];
    EditorialParagraph? previousParagraph;
    void flush() {
      if (current.isNotEmpty) {
        result.add(ScriptureParagraphBlock(List<Verse>.unmodifiable(current)));
        current = <Verse>[];
      }
    }

    for (final Verse verse in chapter.verses) {
      final List<EditorialHeading> before = headings
          .where((EditorialHeading item) => item.anchorVerse == verse.verse)
          .toList();
      // Published v3 verses have no titles: editorial is their representation.
      // Legacy/additive records can retain verse-level titles. Render those in
      // source order only when the same heading is not already anchored here.
      for (final ScriptureTitle title in verse.titles) {
        if (before.any((EditorialHeading item) => item.text == title.text)) {
          continue;
        }
        before.add(
          EditorialHeading(<String, Object?>{
            ...title.toJson(),
            'order': before.length,
            'type': 'heading',
            'anchor': <String, Object?>{'verse': verse.verse, 'edge': 'before'},
            'heading_type': title.type.isEmpty ? 'unspecified' : title.type,
            'canonical': title.canonical ?? false,
          }),
        );
      }
      final EditorialParagraph? paragraph = paragraphs
          .where(
            (EditorialParagraph item) =>
                item.start <= verse.verse && item.end >= verse.verse,
          )
          .firstOrNull;
      if (before.isNotEmpty ||
          (paragraphs.isNotEmpty && paragraph != previousParagraph) ||
          (paragraphs.isEmpty && verse.paragraph == true)) {
        flush();
      }
      for (final EditorialHeading heading in before) {
        result.add(ScriptureHeadingBlock(heading));
      }
      current.add(verse);
      previousParagraph = paragraph;
    }
    flush();
    return List<ScriptureReadingBlock>.unmodifiable(result);
  }
}
