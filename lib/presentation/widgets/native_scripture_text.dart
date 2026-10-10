import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import '../../domain/models/bible.dart';
import '../../services/scripture_text.dart';

/// Adds a word tap to Flutter's selectable document without a competing gesture
/// recognizer. Native scrolling, long press and double-click selection retain
/// precedence. The brief single-tap delay lets a double-click form its selection.
class NativeScriptureText extends StatefulWidget {
  const NativeScriptureText({
    super.key,
    required this.span,
    required this.mapping,
    this.textDirection,
    this.contextMenuBuilder,
    this.onSelectionChanged,
    this.focusNode,
    this.onWordTap,
  });

  final TextSpan span;
  final ScriptureParagraphTextMap mapping;
  final TextDirection? textDirection;
  final EditableTextContextMenuBuilder? contextMenuBuilder;
  final SelectionChangedCallback? onSelectionChanged;
  final FocusNode? focusNode;
  final void Function(Verse, ScriptureTextRange)? onWordTap;

  @override
  State<NativeScriptureText> createState() => _NativeScriptureTextState();
}

class _NativeScriptureTextState extends State<NativeScriptureText> {
  final GlobalKey _documentKey = GlobalKey();
  Offset? _tapPosition;
  Timer? _wordTap;
  ScrollPosition? _pendingScroll;

  void _cancelWord() {
    _wordTap?.cancel();
    _wordTap = null;
    _pendingScroll?.removeListener(_cancelWord);
    _pendingScroll?.isScrollingNotifier.removeListener(_cancelOnScroll);
    _pendingScroll = null;
  }

  void _cancelOnScroll() {
    if (_pendingScroll?.isScrollingNotifier.value == true) _cancelWord();
  }

  @override
  void didUpdateWidget(NativeScriptureText oldWidget) {
    super.didUpdateWidget(oldWidget);
    final bool sameSource =
        oldWidget.mapping.locations.length == widget.mapping.locations.length &&
        Iterable<int>.generate(widget.mapping.locations.length).every(
          (int index) => identical(
            oldWidget.mapping.locations[index].$1,
            widget.mapping.locations[index].$1,
          ),
        );
    if (!sameSource || oldWidget.mapping.text != widget.mapping.text) {
      _cancelWord();
    }
  }

  @override
  void dispose() {
    _cancelWord();
    super.dispose();
  }

  EditableTextState? _editable() {
    EditableTextState? result;
    void visit(Element element) {
      if (element is StatefulElement && element.state is EditableTextState) {
        result = element.state as EditableTextState;
      } else if (result == null) {
        element.visitChildElements(visit);
      }
    }

    final BuildContext? context = _documentKey.currentContext;
    if (context is Element) visit(context);
    return result;
  }

  void _scheduleWord() {
    final Offset? position = _tapPosition;
    if (position == null || widget.onWordTap == null) return;
    _cancelWord();
    final EditableTextState? editable = _editable();
    if (editable == null) return;
    // Resolve before any scrolling can move the stored global point.
    final int offset = editable.renderEditable
        .getPositionForPoint(position)
        .offset;
    Verse? source;
    ScriptureTextRange? selectedWord;
    for (final (Verse verse, ScriptureTextRange location)
        in widget.mapping.locations) {
      if (!location.contains(offset)) continue;
      source = verse;
      selectedWord = ScriptureTextMap(verse.text).words
          .where(
            (ScriptureTextRange range) =>
                range.contains(offset - location.start),
          )
          .firstOrNull;
      break;
    }
    if (source == null || selectedWord == null) return;
    final Verse capturedVerse = source;
    final ScriptureTextRange capturedWord = selectedWord;
    _pendingScroll = Scrollable.maybeOf(context)?.position;
    _pendingScroll?.addListener(_cancelWord);
    _pendingScroll?.isScrollingNotifier.addListener(_cancelOnScroll);
    _wordTap = Timer(const Duration(milliseconds: 350), () {
      _cancelWord();
      if (!mounted) return;
      final EditableTextState? editable = _editable();
      if (editable == null ||
          !editable.widget.focusNode.hasFocus ||
          !editable.textEditingValue.selection.isCollapsed) {
        return;
      }
      widget.onWordTap?.call(capturedVerse, capturedWord);
    });
  }

  @override
  Widget build(BuildContext context) => CallbackShortcuts(
    bindings: {
      const SingleActivator(LogicalKeyboardKey.keyC, control: true):
          _copySelection,
      const SingleActivator(LogicalKeyboardKey.keyC, meta: true):
          _copySelection,
    },
    child: _ScriptureCopySemantics(
      onCopy: _copySelection,
      child: Listener(
        onPointerDown: (PointerDownEvent event) {
          _cancelWord();
          _tapPosition = event.position;
        },
        onPointerCancel: (_) => _cancelWord(),
        child: SelectableText.rich(
          widget.span,
          key: _documentKey,
          textDirection: widget.textDirection,
          focusNode: widget.focusNode,
          contextMenuBuilder:
              widget.contextMenuBuilder ?? _defaultContextMenuBuilder,
          onTap: widget.onWordTap == null ? null : _scheduleWord,
          onSelectionChanged:
              (TextSelection selection, SelectionChangedCause? cause) {
                if (!selection.isCollapsed) _cancelWord();
                widget.onSelectionChanged?.call(selection, cause);
              },
        ),
      ),
    ),
  );

  void _copySelection() {
    final editable = _editable();
    if (editable != null) copyScriptureSelection(editable, widget.mapping);
  }

  Widget _defaultContextMenuBuilder(
    BuildContext context,
    EditableTextState editable,
  ) => AdaptiveTextSelectionToolbar.buttonItems(
    anchors: editable.contextMenuAnchors,
    buttonItems: [
      for (final item in editable.contextMenuButtonItems)
        if (item.type == ContextMenuButtonType.copy)
          ContextMenuButtonItem(
            type: item.type,
            label: item.label,
            onPressed: () => copyScriptureSelection(editable, widget.mapping),
          )
        else
          item,
    ],
  );
}

/// Replaces only the existing native Copy action while semantics configurations
/// merge upwards. An outer Semantics.onCopy is insufficient: EditableText's
/// child action wins that merge. Excluding or merging all semantics would also
/// discard native selection actions or the individual inline bookmark controls.
///
/// This public rendering delegate keeps the original nodes, action availability,
/// selection coordinates, labels and child buttons. No clipboard write happens
/// until the user invokes Copy, and its content follows the same source mapping
/// as the toolbar and keyboard paths.
class _ScriptureCopySemantics extends SingleChildRenderObjectWidget {
  const _ScriptureCopySemantics({required this.onCopy, required super.child});
  final VoidCallback onCopy;

  @override
  _RenderScriptureCopySemantics createRenderObject(BuildContext context) =>
      _RenderScriptureCopySemantics(onCopy);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderScriptureCopySemantics renderObject,
  ) => renderObject.onCopy = onCopy;
}

class _RenderScriptureCopySemantics extends RenderProxyBox {
  _RenderScriptureCopySemantics(this._onCopy);
  VoidCallback _onCopy;
  set onCopy(VoidCallback value) {
    if (_onCopy == value) return;
    _onCopy = value;
    markNeedsSemanticsUpdate();
  }

  @override
  void describeSemanticsConfiguration(SemanticsConfiguration config) {
    super.describeSemanticsConfiguration(config);
    config.childConfigurationsDelegate = (children) {
      final result = ChildSemanticsConfigurationsResultBuilder();
      for (final child in children) {
        if (child.getActionHandler(SemanticsAction.copy) != null) {
          child.onCopy = _onCopy;
        }
        result.markAsMergeUp(child);
      }
      return result.build();
    };
  }
}

/// Copy original Scripture only. Verse-number and bookmark WidgetSpans are
/// presentation markers and must never leak into the clipboard or private data.
void copyScriptureSelection(
  EditableTextState editable,
  ScriptureParagraphTextMap mapping,
) {
  final selection = editable.textEditingValue.selection;
  final verses = mapping.selections(selection.start, selection.end);
  if (verses.isEmpty) return;
  unawaited(
    Clipboard.setData(
      ClipboardData(text: verses.map((verse) => verse.quote).join(' ')),
    ),
  );
  editable.hideToolbar();
}
