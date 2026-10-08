import 'package:flutter/material.dart';

import '../../domain/models/annotations.dart';
import '../../domain/models/bible.dart';
import '../../domain/models/passage.dart';
import '../../services/scripture_text.dart';

/// The verse's original text remains Flutter's native selectable document.
///
/// Reader-specific marking/menu actions can be supplied without recreating the
/// default native Copy and selection controls. Source styles never add characters
/// or replace the source string with transformed/normalized text.
class ScriptureVerseText extends StatelessWidget {
  const ScriptureVerseText({
    super.key,
    required this.verse,
    required this.style,
    this.passage,
    this.markings = const <Marking>[],
    this.groups = const <MarkingGroup>[],
    this.emphasis = const <ScriptureTextEmphasis>[],
    this.showSourceStyles = true,
    this.includeWholeVerse = true,
    this.textDirection,
    this.contextMenuBuilder,
    this.onSelectionChanged,
    this.focusNode,
  });

  final Verse verse;
  final TextStyle style;
  final Passage? passage;
  final List<Marking> markings;
  final List<MarkingGroup> groups;
  final List<ScriptureTextEmphasis> emphasis;
  final bool showSourceStyles;
  final bool includeWholeVerse;
  final TextDirection? textDirection;
  final EditableTextContextMenuBuilder? contextMenuBuilder;
  final SelectionChangedCallback? onSelectionChanged;
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) {
    final TextSpan span = scriptureVerseSpan(
      context: context,
      verse: verse,
      style: style,
      passage: passage,
      markings: markings,
      groups: groups,
      emphasis: emphasis,
      showSourceStyles: showSourceStyles,
      includeWholeVerse: includeWholeVerse,
    );
    if (contextMenuBuilder == null) {
      return SelectableText.rich(
        span,
        textDirection: textDirection,
        onSelectionChanged: onSelectionChanged,
        focusNode: focusNode,
      );
    }
    return SelectableText.rich(
      span,
      textDirection: textDirection,
      contextMenuBuilder: contextMenuBuilder,
      onSelectionChanged: onSelectionChanged,
      focusNode: focusNode,
    );
  }
}

/// Also usable by a chapter's native paragraph document.
TextSpan scriptureVerseSpan({
  required BuildContext context,
  required Verse verse,
  required TextStyle style,
  Passage? passage,
  List<Marking> markings = const <Marking>[],
  List<MarkingGroup> groups = const <MarkingGroup>[],
  List<ScriptureTextEmphasis> emphasis = const <ScriptureTextEmphasis>[],
  bool showSourceStyles = true,
  bool includeWholeVerse = true,
}) {
  final ColorScheme colors = Theme.of(context).colorScheme;
  final List<ScriptureTextSegment> segments = const ScriptureTextComposer()
      .compose(
        verse: verse,
        passage: passage,
        markings: markings,
        groups: groups,
        emphasis: emphasis,
        showSourceStyles: showSourceStyles,
        includeWholeVerse: includeWholeVerse,
      );
  return TextSpan(
    style: style,
    children: <InlineSpan>[
      for (final ScriptureTextSegment segment in segments)
        TextSpan(
          text: segment.text,
          style: TextStyle(
            fontStyle: segment.sourceStyle.italic ? FontStyle.italic : null,
            fontWeight:
                segment.sourceStyle.bold ||
                    segment.sourceStyle.divineName ||
                    segment.sourceStyle.jesusWords
                ? FontWeight.w600
                : null,
            backgroundColor: segment.markingGroup == null
                ? null
                : _groupColor(segment.markingGroup!.color).withAlpha(95),
            // A separate visual channel keeps personal colors visible during
            // temporary result emphasis. No source/private layer is discarded.
            decoration: segment.emphasized ? TextDecoration.underline : null,
            decorationColor: segment.emphasized ? colors.primary : null,
            decorationThickness: segment.emphasized ? 2 : null,
          ),
        ),
    ],
  );
}

Color _groupColor(String hex) =>
    Color(int.parse(hex.substring(1), radix: 16) | 0xff000000);
