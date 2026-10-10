import 'package:flutter/material.dart';

import '../../domain/models/bible.dart';
import '../../services/scripture_text.dart';

/// Reader actions are supplied by the owning route, never by a resource widget.
class ScriptureStudyActions extends InheritedWidget {
  const ScriptureStudyActions({
    super.key,
    required super.child,
    required this.onWord,
    required this.onSearch,
    required this.onNote,
    this.emphasisFor,
    this.onReference,
    this.onBookmarks,
  });

  final void Function(Verse, ScriptureTextRange) onWord;
  final ValueChanged<String> onSearch;
  final ValueChanged<Verse> onNote;
  final List<ScriptureTextEmphasis> Function(Verse)? emphasisFor;
  final ValueChanged<String>? onReference;
  final void Function(String?, int?)? onBookmarks;

  static ScriptureStudyActions? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ScriptureStudyActions>();

  @override
  bool updateShouldNotify(ScriptureStudyActions oldWidget) =>
      onWord != oldWidget.onWord ||
      onSearch != oldWidget.onSearch ||
      onNote != oldWidget.onNote ||
      onReference != oldWidget.onReference ||
      onBookmarks != oldWidget.onBookmarks ||
      emphasisFor != oldWidget.emphasisFor;
}
