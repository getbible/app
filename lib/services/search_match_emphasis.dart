import '../domain/models/bible.dart';
import '../domain/models/search.dart';
import 'scripture_text.dart';

/// Conservative visual emphasis for terms returned by Search v3. This does not
/// decide which verses match: script/diacritic analysis remains server-owned.
/// Terms that cannot be located without altering source text are left plain.
/// Every emphasis stores an exact quote in original UTF-16 coordinates.
List<ScriptureTextEmphasis> searchMatchEmphasis(
  Verse verse,
  Iterable<String> terms, {
  bool caseSensitive = false,
  SearchMatchMode match = SearchMatchMode.partial,
}) {
  final ScriptureTextMap map = ScriptureTextMap(verse.text);
  final Set<ScriptureTextRange> ranges = <ScriptureTextRange>{};
  for (final String term in terms) {
    if (term.isEmpty || term.length > verse.text.length) continue;
    // RegExp's original-string match coordinates remain safe even when case
    // folding would otherwise expand a character into several code units.
    final RegExp expression = RegExp(
      RegExp.escape(term),
      caseSensitive: caseSensitive,
      unicode: true,
    );
    for (final RegExpMatch located in expression.allMatches(verse.text)) {
      final ScriptureTextRange range = ScriptureTextRange(
        located.start,
        located.end,
      );
      if (!map.isValidRange(range) ||
          _splitsCombiningSequence(verse.text, range)) {
        continue;
      }
      // Alphabetic exact terms exclude adjoining letters. Continuous-script
      // units retain the server's matching semantics instead of local slicing.
      if (match == SearchMatchMode.exact &&
          _alphabetic.hasMatch(term) &&
          (_adjoiningLetter(verse.text, range.start, before: true) ||
              _adjoiningLetter(verse.text, range.end, before: false))) {
        continue;
      }
      ranges.add(range);
    }
  }
  final List<ScriptureTextRange> ordered = ranges.toList()
    ..sort((ScriptureTextRange left, ScriptureTextRange right) {
      final int start = left.start.compareTo(right.start);
      return start == 0 ? left.end.compareTo(right.end) : start;
    });
  return List<ScriptureTextEmphasis>.unmodifiable(
    ordered.map(
      (ScriptureTextRange range) => ScriptureTextEmphasis(
        range: range,
        quote: verse.text.substring(range.start, range.end),
      ),
    ),
  );
}

final RegExp _mark = RegExp(r'^\p{M}', unicode: true);
final RegExp _alphabetic = RegExp(
  r'[A-Za-z\u00c0-\u024f\u0370-\u052f]',
  unicode: true,
);
final RegExp _letter = RegExp(r'[\p{L}\p{N}\p{M}]', unicode: true);

bool _splitsCombiningSequence(String text, ScriptureTextRange range) =>
    _mark.hasMatch(text.substring(range.start)) ||
    (range.end < text.length && _mark.hasMatch(text.substring(range.end)));

bool _adjoiningLetter(String text, int offset, {required bool before}) {
  if (before && offset == 0 || !before && offset == text.length) return false;
  final String adjacent = before
      ? String.fromCharCode(text.substring(0, offset).runes.last)
      : String.fromCharCode(text.substring(offset).runes.first);
  return _letter.hasMatch(adjacent);
}
