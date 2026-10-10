import '../domain/models/annotations.dart';
import '../domain/models/bible.dart';
import '../domain/models/passage.dart';

/// An end-exclusive range in the original Dart string's UTF-16 code units.
///
/// Source word and token indexes are never accepted as character offsets.
final class ScriptureTextRange {
  const ScriptureTextRange(this.start, this.end);

  final int start;
  final int end;

  bool contains(int offset) => start <= offset && offset < end;
  bool covers(ScriptureTextRange other) =>
      start <= other.start && end >= other.end;
  bool overlaps(ScriptureTextRange other) =>
      start < other.end && end > other.start;

  @override
  bool operator ==(Object other) =>
      other is ScriptureTextRange && start == other.start && end == other.end;

  @override
  int get hashCode => Object.hash(start, end);
}

/// Maps published whitespace-word coordinates without normalizing Scripture.
///
/// Whitespace includes Unicode spaces used by source modules and the control
/// separators recognized by the builder. Punctuation remains part of its word;
/// continuous scripts without whitespace are one word, not guessed segments.
final class ScriptureTextMap {
  ScriptureTextMap(this.text)
    : words = List<ScriptureTextRange>.unmodifiable(
        _wordPattern
            .allMatches(text)
            .map(
              (RegExpMatch match) => ScriptureTextRange(match.start, match.end),
            ),
      );

  static final RegExp _wordPattern = RegExp(
    r'[^\u0009-\u000d\u001c-\u0020\u0085\u00a0\u1680\u2000-\u200a\u2028\u2029\u202f\u205f\u3000]+',
    unicode: true,
  );

  final String text;
  final List<ScriptureTextRange> words;

  /// Returns null for the explicit unlocated coordinate 0 or invalid metadata.
  ScriptureTextRange? wordRange(int start, int end) {
    if (start < 1 || end < start || end > words.length) return null;
    return ScriptureTextRange(words[start - 1].start, words[end - 1].end);
  }

  ScriptureTextRange? tokenRange(ScriptureToken token) =>
      wordRange(token.wordStart, token.wordEnd);

  /// Resolves the source's exact span inside its published word range.
  ///
  /// A span may omit adjacent punctuation in the same whitespace word. A unique
  /// exact occurrence narrows that known range. A missing or ambiguous surface
  /// never relocates an annotation into unrelated verse text.
  ScriptureTextRange? spanRange(ScriptureSpan span) {
    final ScriptureTextRange? located = wordRange(span.wordStart, span.wordEnd);
    if (located == null || span.span.isEmpty) return null;
    final String candidate = text.substring(located.start, located.end);
    if (candidate == span.span) return located;
    final int first = candidate.indexOf(span.span);
    if (first < 0 || candidate.indexOf(span.span, first + 1) >= 0) return null;
    final ScriptureTextRange range = ScriptureTextRange(
      located.start + first,
      located.start + first + span.span.length,
    );
    return isValidRange(range) ? range : null;
  }

  /// A token-array range is useful for lexical context, never a text range.
  List<ScriptureToken> tokensForSpan(
    ScriptureSpan span,
    List<ScriptureToken> tokens,
  ) {
    if (span.tokenStart < 0 ||
        span.tokenEnd < span.tokenStart ||
        span.tokenEnd >= tokens.length) {
      return const <ScriptureToken>[];
    }
    return List<ScriptureToken>.unmodifiable(
      tokens.sublist(span.tokenStart, span.tokenEnd + 1),
    );
  }

  List<ScriptureToken> tokensAt(int utf16Offset, List<ScriptureToken> tokens) =>
      List<ScriptureToken>.unmodifiable(
        tokens.where(
          (ScriptureToken token) =>
              tokenRange(token)?.contains(utf16Offset) ?? false,
        ),
      );

  bool isValidRange(ScriptureTextRange range) =>
      range.start >= 0 &&
      range.end > range.start &&
      range.end <= text.length &&
      _isCodePointBoundary(range.start) &&
      _isCodePointBoundary(range.end);

  bool matchesQuote(ScriptureTextRange range, String quote) =>
      isValidRange(range) && text.substring(range.start, range.end) == quote;

  bool _isCodePointBoundary(int offset) {
    if (offset <= 0 || offset >= text.length) return true;
    final int previous = text.codeUnitAt(offset - 1);
    final int current = text.codeUnitAt(offset);
    return !(previous >= 0xd800 &&
        previous <= 0xdbff &&
        current >= 0xdc00 &&
        current <= 0xdfff);
  }
}

/// Source flags are combined, rather than making one annotation erase another.
final class ScriptureSourceStyle {
  const ScriptureSourceStyle({
    this.italic = false,
    this.bold = false,
    this.divineName = false,
    this.jesusWords = false,
  });

  factory ScriptureSourceStyle.forSpan(ScriptureSpan span) {
    final Object? typeAttribute = span.attrs['type'];
    final Object? speakerAttribute = span.attrs['who'];
    final String type = typeAttribute is String
        ? typeAttribute.toLowerCase()
        : '';
    final String speaker = speakerAttribute is String
        ? speakerAttribute.trim().toLowerCase()
        : '';
    return ScriptureSourceStyle(
      italic:
          (span.tag == 'transChange' && type == 'added') ||
          (span.tag == 'hi' && type == 'italic'),
      bold: span.tag == 'hi' && type == 'bold',
      divineName: span.tag == 'divineName',
      jesusWords:
          span.tag == 'q' && (speaker == 'jesus' || speaker == '#jesus'),
    );
  }

  final bool italic;
  final bool bold;
  final bool divineName;
  final bool jesusWords;

  ScriptureSourceStyle combine(ScriptureSourceStyle other) =>
      ScriptureSourceStyle(
        italic: italic || other.italic,
        bold: bold || other.bold,
        divineName: divineName || other.divineName,
        jesusWords: jesusWords || other.jesusWords,
      );
}

/// Temporary emphasis uses original-text coordinates and an exact saved quote.
/// API search match records must first be mapped through [ScriptureTextMap].
final class ScriptureTextEmphasis {
  const ScriptureTextEmphasis({required this.range, required this.quote});

  final ScriptureTextRange range;
  final String quote;
}

final class ScriptureTextSegment {
  const ScriptureTextSegment({
    required this.range,
    required this.text,
    required this.sourceStyle,
    required this.markingGroup,
    required this.emphasized,
  });

  final ScriptureTextRange range;
  final String text;
  final ScriptureSourceStyle sourceStyle;
  final MarkingGroup? markingGroup;
  final bool emphasized;
}

/// Composes source, personal and temporary layers deterministically.
///
/// Source styles combine. Newer ranged private markings win over older ranges;
/// equal timestamps resolve by stable ID. A whole-verse color is the base layer.
/// Temporary emphasis is independent, so neither layer erases the other.
/// Invalid/mismatched records remain stored but are deliberately not colored.
final class ScriptureTextComposer {
  const ScriptureTextComposer();

  List<ScriptureTextSegment> compose({
    required Verse verse,
    Passage? passage,
    List<Marking> markings = const <Marking>[],
    List<MarkingGroup> groups = const <MarkingGroup>[],
    List<ScriptureTextEmphasis> emphasis = const <ScriptureTextEmphasis>[],
    bool showSourceStyles = true,
    bool includeWholeVerse = true,
  }) {
    if (verse.text.isEmpty) return const <ScriptureTextSegment>[];
    final ScriptureTextMap map = ScriptureTextMap(verse.text);
    final Map<String, MarkingGroup> byId = <String, MarkingGroup>{
      for (final MarkingGroup group in groups) group.id: group,
    };
    final List<Marking> applicable =
        markings
            .where(
              (Marking marking) =>
                  marking.verse == verse.verse &&
                  (passage == null || marking.matchesPassage(passage)) &&
                  byId.containsKey(marking.groupId),
            )
            .toList()
          ..sort(_compareMarkingAge);
    final List<Marking> ranged = applicable
        .where(
          (Marking marking) =>
              !marking.isWholeVerse &&
              map.matchesQuote(
                ScriptureTextRange(marking.start!, marking.end!),
                marking.quote,
              ),
        )
        .toList(growable: false);
    final Marking? whole = includeWholeVerse
        ? preferredWholeVerseMarking(applicable)
        : null;
    final List<(ScriptureTextRange, ScriptureSourceStyle)> source =
        <(ScriptureTextRange, ScriptureSourceStyle)>[];
    if (showSourceStyles) {
      for (final ScriptureSpan span in verse.spans) {
        final ScriptureTextRange? range = map.spanRange(span);
        if (range != null) {
          source.add((range, ScriptureSourceStyle.forSpan(span)));
        }
      }
    }
    final List<ScriptureTextEmphasis> validEmphasis = emphasis
        .where(
          (ScriptureTextEmphasis item) =>
              map.matchesQuote(item.range, item.quote),
        )
        .toList(growable: false);
    final Set<int> boundaries = <int>{0, verse.text.length};
    for (final Marking item in ranged) {
      boundaries.addAll(<int>[item.start!, item.end!]);
    }
    for (final (ScriptureTextRange range, _) in source) {
      boundaries.addAll(<int>[range.start, range.end]);
    }
    for (final ScriptureTextEmphasis item in validEmphasis) {
      boundaries.addAll(<int>[item.range.start, item.range.end]);
    }
    final List<int> sorted = boundaries.toList()..sort();
    return List<ScriptureTextSegment>.unmodifiable(
      List<ScriptureTextSegment>.generate(sorted.length - 1, (int index) {
        final ScriptureTextRange range = ScriptureTextRange(
          sorted[index],
          sorted[index + 1],
        );
        ScriptureSourceStyle style = const ScriptureSourceStyle();
        for (final (ScriptureTextRange location, ScriptureSourceStyle value)
            in source) {
          if (location.covers(range)) style = style.combine(value);
        }
        final Marking? personal = ranged
            .where(
              (Marking item) =>
                  item.start! <= range.start && item.end! >= range.end,
            )
            .lastOrNull;
        return ScriptureTextSegment(
          range: range,
          text: verse.text.substring(range.start, range.end),
          sourceStyle: style,
          markingGroup: byId[(personal ?? whole)?.groupId],
          emphasized: validEmphasis.any(
            (ScriptureTextEmphasis item) => item.range.covers(range),
          ),
        );
      }),
    );
  }

  static int _compareMarkingAge(Marking left, Marking right) {
    final int time = left.createdAt.compareTo(right.createdAt);
    return time == 0 ? left.id.compareTo(right.id) : time;
  }
}

final class ScriptureVerseSelection {
  const ScriptureVerseSelection({required this.verse, required this.range});

  final Verse verse;
  final ScriptureTextRange range;

  String get quote => verse.text.substring(range.start, range.end);
}

/// Maps a native paragraph selection back to each unchanged verse string.
///
/// The prefix, suffix and separator match the rich document's plain-text form.
/// A WidgetSpan verse-number marker occupies one U+FFFC code unit; a plain
/// textual marker should pass its actual string. These presentation characters
/// and separators never become part of a saved verse range or quote.
final class ScriptureParagraphTextMap {
  factory ScriptureParagraphTextMap(
    List<Verse> verses, {
    String separator = ' ',
    String Function(Verse verse)? versePrefix,
    String Function(Verse verse)? verseSuffix,
  }) {
    final StringBuffer text = StringBuffer();
    final List<(Verse, ScriptureTextRange)> locations =
        <(Verse, ScriptureTextRange)>[];
    for (int index = 0; index < verses.length; index++) {
      final Verse verse = verses[index];
      if (index > 0) text.write(separator);
      text.write(versePrefix?.call(verse) ?? '');
      final int start = text.length;
      text.write(verse.text);
      locations.add((verse, ScriptureTextRange(start, text.length)));
      text.write(verseSuffix?.call(verse) ?? '');
    }
    return ScriptureParagraphTextMap._(
      text.toString(),
      List<(Verse, ScriptureTextRange)>.unmodifiable(locations),
    );
  }

  const ScriptureParagraphTextMap._(this.text, this.locations);

  final String text;
  final List<(Verse, ScriptureTextRange)> locations;

  List<ScriptureVerseSelection> selections(int start, int end) {
    if (start < 0 || end <= start || end > text.length) {
      return const <ScriptureVerseSelection>[];
    }
    final ScriptureTextRange selected = ScriptureTextRange(start, end);
    final List<ScriptureVerseSelection> result = <ScriptureVerseSelection>[];
    for (final (Verse verse, ScriptureTextRange location) in locations) {
      if (!location.overlaps(selected)) continue;
      final ScriptureTextRange range = ScriptureTextRange(
        (start > location.start ? start : location.start) - location.start,
        (end < location.end ? end : location.end) - location.start,
      );
      if (ScriptureTextMap(verse.text).isValidRange(range)) {
        result.add(ScriptureVerseSelection(verse: verse, range: range));
      }
    }
    return List<ScriptureVerseSelection>.unmodifiable(result);
  }
}
