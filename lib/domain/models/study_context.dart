import 'bible.dart';
import 'passage.dart';

/// An immutable snapshot of the Scripture that opened Study.
///
/// Resource switching never follows a subsequently changed reader implicitly.
/// Selection coordinates use the original verse's UTF-16 code units; generated
/// verse numbers and paragraph separators never enter this context.
final class StudyContext {
  const StudyContext({
    required this.passage,
    required this.bookName,
    required this.language,
    this.translationName,
    this.direction = 'LTR',
    this.verse,
    this.selectionStart,
    this.selectionEnd,
  });

  final Passage passage;
  final String bookName;
  final String language;
  final String? translationName;
  final String direction;
  final Verse? verse;
  final int? selectionStart;
  final int? selectionEnd;

  String get translation => passage.translation;
  int get book => passage.book;
  int get chapter => passage.chapter;
  int? get verseNumber => verse?.verse ?? passage.verse;

  String? get selectedText {
    final String? text = verse?.text;
    final int? start = selectionStart;
    final int? end = selectionEnd;
    if (text == null ||
        start == null ||
        end == null ||
        start < 0 ||
        end <= start ||
        end > text.length) {
      return null;
    }
    if (_splitsSurrogate(text, start) || _splitsSurrogate(text, end)) {
      return null;
    }
    return text.substring(start, end);
  }

  String get label => chapter == 0
      ? '$bookName introduction'
      : '$bookName $chapter${verseNumber == null ? '' : ':$verseNumber'}';

  static bool _splitsSurrogate(String text, int offset) =>
      offset > 0 &&
      offset < text.length &&
      text.codeUnitAt(offset - 1) >= 0xd800 &&
      text.codeUnitAt(offset - 1) <= 0xdbff &&
      text.codeUnitAt(offset) >= 0xdc00 &&
      text.codeUnitAt(offset) <= 0xdfff;
}
