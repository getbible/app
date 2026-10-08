import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/scripture_text.dart';

/// Keeps Flutter's native selection actions while copying original Scripture.
///
/// Native paragraph documents use WidgetSpans for interactive verse numbers.
/// Their U+FFFC placeholders must not enter the clipboard via Ctrl/Cmd+C.
/// Wrap the paragraph's SelectableText with the same mapping used by its toolbar;
/// other shortcuts and editable fields continue to use their native actions.
class ScriptureParagraphSelection extends StatelessWidget {
  const ScriptureParagraphSelection({
    super.key,
    required this.mapping,
    required this.child,
    this.onCopyError,
  });

  final ScriptureParagraphTextMap mapping;
  final Widget child;
  final ValueChanged<Object>? onCopyError;

  @override
  Widget build(BuildContext context) => Actions(
    actions: <Type, Action<Intent>>{
      CopySelectionTextIntent: _ParagraphCopyAction(mapping, onCopyError),
    },
    child: child,
  );
}

final class _ParagraphCopyAction
    extends ContextAction<CopySelectionTextIntent> {
  _ParagraphCopyAction(this.mapping, this.onCopyError);

  final ScriptureParagraphTextMap mapping;
  final ValueChanged<Object>? onCopyError;

  @override
  Object? invoke(CopySelectionTextIntent intent, [BuildContext? context]) {
    final BuildContext? focusContext =
        FocusManager.instance.primaryFocus?.context;
    final EditableTextState? editable = focusContext
        ?.findAncestorStateOfType<EditableTextState>();
    // Cut and unrelated editable documents retain the framework's own behavior.
    if (intent.collapseSelection ||
        editable == null ||
        !editable.widget.readOnly ||
        editable.textEditingValue.text != mapping.text) {
      final Action<CopySelectionTextIntent>? native = callingAction;
      return native is ContextAction<CopySelectionTextIntent>
          ? native.invoke(intent, context)
          : native?.invoke(intent);
    }
    final TextSelection selected = editable.textEditingValue.selection;
    if (!editable.widget.selectionEnabled ||
        !selected.isValid ||
        selected.isCollapsed) {
      return null;
    }
    final List<ScriptureVerseSelection> ranges = mapping.selections(
      selected.start,
      selected.end,
    );
    if (ranges.isNotEmpty) {
      unawaited(
        _copy(
          ranges.map((ScriptureVerseSelection item) => item.quote).join(' '),
        ),
      );
    }
    return null;
  }

  Future<void> _copy(String text) async {
    try {
      await Clipboard.setData(ClipboardData(text: text));
    } catch (error, stack) {
      if (onCopyError != null) {
        onCopyError!(error);
      } else {
        FlutterError.reportError(
          FlutterErrorDetails(
            exception: error,
            stack: stack,
            library: 'Scripture paragraph selection',
            context: ErrorDescription('while copying selected Scripture'),
          ),
        );
      }
    }
  }
}
