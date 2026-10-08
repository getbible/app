import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../application/reference_preview_controller.dart';
import '../../core/errors.dart';
import '../../domain/models/bible.dart';
import '../../domain/models/passage.dart';
import '../../domain/models/reference.dart';
import 'scripture_verse_text.dart';

/// Labels can be supplied by the application's locale layer. Scripture and
/// source citation labels are always displayed exactly as the API supplies them.
final class ReferencePreviewLabels {
  const ReferencePreviewLabels({
    this.title = 'Reference preview',
    this.reference = 'Scripture reference',
    this.hint = 'John 3:16; Psalm 23',
    this.preview = 'Preview',
    this.close = 'Close reference preview',
    this.back = 'Previous citation',
    this.copy = 'Copy',
    this.copied = 'Scripture copied',
    this.open = 'Open in reader',
    this.loading = 'Loading reference',
    this.retry = 'Try again',
    this.empty =
        'Enter a reference to preview Scripture in your selected Bible.',
    this.unavailable = 'This reference or translation is unavailable.',
    this.offline =
        'Unable to load this reference. Check your connection and try again.',
  });

  final String title;
  final String reference;
  final String hint;
  final String preview;
  final String close;
  final String back;
  final String copy;
  final String copied;
  final String open;
  final String loading;
  final String retry;
  final String empty;
  final String unavailable;
  final String offline;
}

/// Reusable content for a compact sheet or a side panel beside Scripture.
/// This widget never reads a chapter, persists a position or changes translation.
class ReferencePreview extends StatefulWidget {
  const ReferencePreview({
    required this.controller,
    required this.selectedTranslation,
    required this.onOpenInReader,
    required this.onClose,
    this.translationName,
    this.selectedTranslationDirection = 'LTR',
    this.labels = const ReferencePreviewLabels(),
    this.showReferenceInput = true,
    this.showSourceStyles = true,
    super.key,
  });

  final ReferencePreviewController controller;
  final String selectedTranslation;
  final String? translationName;
  final String selectedTranslationDirection;
  final Future<void> Function(Passage passage) onOpenInReader;
  final VoidCallback onClose;
  final ReferencePreviewLabels labels;
  final bool showReferenceInput;
  final bool showSourceStyles;

  @override
  State<ReferencePreview> createState() => _ReferencePreviewState();
}

class _ReferencePreviewState extends State<ReferencePreview> {
  final TextEditingController _input = TextEditingController();
  bool _opening = false;
  String? _actionError;
  ReferenceRequest? _actionRequest;

  String? _translationNameFor(ReferenceRequest? request) =>
      request?.translationName ??
      (request == null || request.translation == widget.selectedTranslation
          ? widget.translationName
          : null);

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  void _submit() {
    final String reference = _input.text;
    if (reference.trim().isEmpty) return;
    final ReferenceRequest? source = widget.controller.request;
    unawaited(
      widget.controller.open(
        TextReferenceRequest(
          translation: source?.translation ?? widget.selectedTranslation,
          translationName: _translationNameFor(source),
          translationDirection:
              source?.translationDirection ??
              (source == null ||
                      source.translation == widget.selectedTranslation
                  ? widget.selectedTranslationDirection
                  : 'LTR'),
          reference: reference,
        ),
      ),
    );
  }

  Future<void> _open(Passage passage) async {
    if (_opening) return;
    final ReferenceRequest? request = widget.controller.request;
    setState(() {
      _opening = true;
      _actionError = null;
    });
    try {
      await widget.onOpenInReader(passage);
    } catch (error) {
      if (mounted) {
        setState(() {
          _actionError = error.toString();
          _actionRequest = request;
        });
      }
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  Future<void> _copy(ReferenceResult result) async {
    final ReferenceRequest? request = widget.controller.request;
    try {
      await Clipboard.setData(ClipboardData(text: result.copyText));
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(SnackBar(content: Text(widget.labels.copied)));
    } catch (error) {
      if (mounted) {
        setState(() {
          _actionError = error.toString();
          _actionRequest = request;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.controller,
    builder: (BuildContext context, Widget? child) {
      final ReferencePreviewController state = widget.controller;
      final ReferenceRequest? request = state.request;
      final ReferenceResult? result = state.result;
      final String translation =
          _translationNameFor(request) ??
          (request?.translation ?? widget.selectedTranslation).toUpperCase();
      return SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
              child: Row(
                children: <Widget>[
                  if (state.canGoBack)
                    IconButton(
                      constraints: const BoxConstraints(
                        minWidth: 48,
                        minHeight: 48,
                      ),
                      tooltip: widget.labels.back,
                      onPressed: () => unawaited(state.goBack()),
                      icon: const Icon(Icons.arrow_back),
                    ),
                  Expanded(
                    child: Text(
                      widget.labels.title,
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                  IconButton(
                    constraints: const BoxConstraints(
                      minWidth: 48,
                      minHeight: 48,
                    ),
                    tooltip: widget.labels.close,
                    onPressed: widget.onClose,
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
            ),
            Expanded(
              child: CustomScrollView(
                key: ValueKey<ReferenceRequest?>(request),
                slivers: <Widget>[
                  SliverToBoxAdapter(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          child: Text(
                            translation,
                            style: Theme.of(context).textTheme.labelLarge,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (widget.showReferenceInput)
                          Padding(
                            padding: const EdgeInsets.all(16),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: <Widget>[
                                TextField(
                                  key: const ValueKey<String>(
                                    'reference-preview-input',
                                  ),
                                  controller: _input,
                                  textInputAction: TextInputAction.search,
                                  onSubmitted: (_) => _submit(),
                                  decoration: InputDecoration(
                                    labelText: widget.labels.reference,
                                    hintText: widget.labels.hint,
                                    border: const OutlineInputBorder(),
                                  ),
                                ),
                                const SizedBox(height: 8),
                                FilledButton.tonalIcon(
                                  onPressed: _submit,
                                  icon: const Icon(Icons.menu_book),
                                  label: Text(widget.labels.preview),
                                ),
                              ],
                            ),
                          ),
                        if (request != null)
                          Padding(
                            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                            child: SelectableText(
                              request.label,
                              style: Theme.of(context).textTheme.titleMedium,
                              maxLines: 3,
                            ),
                          ),
                        const Divider(height: 1),
                        if (_actionError != null &&
                            identical(_actionRequest, request))
                          Padding(
                            padding: const EdgeInsets.all(12),
                            child: Semantics(
                              liveRegion: true,
                              child: SelectableText(_actionError!, maxLines: 3),
                            ),
                          ),
                      ],
                    ),
                  ),
                  _body(state, result),
                ],
              ),
            ),
            if (result != null)
              Padding(
                padding: const EdgeInsets.all(12),
                child: Wrap(
                  alignment: WrapAlignment.end,
                  spacing: 8,
                  runSpacing: 8,
                  children: <Widget>[
                    OutlinedButton.icon(
                      onPressed: () => unawaited(_copy(result)),
                      icon: const Icon(Icons.copy),
                      label: Text(widget.labels.copy),
                    ),
                    FilledButton.icon(
                      onPressed: _opening
                          ? null
                          : () => unawaited(
                              _open(
                                result.passageFor(
                                  result.chapters.first,
                                  result.chapters.first.verses.first,
                                ),
                              ),
                            ),
                      icon: const Icon(Icons.open_in_new),
                      label: Text(widget.labels.open),
                    ),
                  ],
                ),
              ),
          ],
        ),
      );
    },
  );

  Widget _body(ReferencePreviewController state, ReferenceResult? result) {
    if (state.isLoading) {
      return SliverFillRemaining(
        hasScrollBody: false,
        child: Center(
          child: Semantics(
            label: widget.labels.loading,
            liveRegion: true,
            child: const CircularProgressIndicator(),
          ),
        ),
      );
    }
    final Object? error = state.error;
    if (error != null) {
      final String message = switch (error) {
        ResourceUnavailableException() => widget.labels.unavailable,
        RateLimitException() => error.message,
        InvalidApiRequestException() => error.message,
        HttpStatusException() => error.message,
        NetworkException() => widget.labels.offline,
        FormatException() => error.message,
        _ => error.toString(),
      };
      return SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            children: <Widget>[
              Semantics(liveRegion: true, child: Text(message)),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: () => unawaited(state.retry()),
                icon: const Icon(Icons.refresh),
                label: Text(widget.labels.retry),
              ),
            ],
          ),
        ),
      );
    }
    if (result == null) {
      return SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Text(widget.labels.empty),
        ),
      );
    }
    return SliverPadding(
      padding: const EdgeInsets.all(16),
      sliver: SliverList.list(
        children: <Widget>[
          for (final ReferenceChapter chapter in result.chapters) ...<Widget>[
            Text(
              chapter.bookName.isNotEmpty
                  ? '${chapter.bookName} ${chapter.chapter}'
                  : chapter.references.isNotEmpty
                  ? chapter.references.join('; ')
                  : 'Book ${chapter.bookNumber}, chapter ${chapter.chapter}',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            if (chapter.references.isNotEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: <Widget>[
                    for (final String reference in chapter.references)
                      Chip(label: Text(reference)),
                  ],
                ),
              ),
            for (final Verse verse in chapter.verses)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Directionality(
                  textDirection: _direction(chapter, state.request),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Padding(
                        padding: const EdgeInsetsDirectional.only(
                          top: 12,
                          end: 8,
                        ),
                        child: Text(
                          '${verse.verse}',
                          style: Theme.of(context).textTheme.labelLarge,
                        ),
                      ),
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: ScriptureVerseText(
                            verse: verse,
                            showSourceStyles: widget.showSourceStyles,
                            style: Theme.of(context).textTheme.bodyLarge!,
                            textDirection: _direction(chapter, state.request),
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: '${widget.labels.open}: ${verse.verse}',
                        constraints: const BoxConstraints(
                          minWidth: 48,
                          minHeight: 48,
                        ),
                        onPressed: _opening
                            ? null
                            : () => unawaited(
                                _open(result.passageFor(chapter, verse)),
                              ),
                        icon: const Icon(Icons.open_in_new, size: 20),
                      ),
                    ],
                  ),
                ),
              ),
            const SizedBox(height: 20),
          ],
        ],
      ),
    );
  }

  TextDirection _direction(
    ReferenceChapter chapter,
    ReferenceRequest? request,
  ) {
    final String direction = chapter.metadata.containsKey('direction')
        ? chapter.direction
        : request?.translationDirection ?? widget.selectedTranslationDirection;
    return direction.toUpperCase() == 'RTL'
        ? TextDirection.rtl
        : TextDirection.ltr;
  }
}

/// Route presentation restores the underlying reader's focus/scroll on close.
/// The same ReferencePreview can instead be embedded directly in a wide Study
/// layout; the controller and exact-verse navigation contract remain unchanged.
Future<void> showAdaptiveReferencePreview({
  required BuildContext context,
  required ReferencePreviewController controller,
  required String selectedTranslation,
  required Future<void> Function(Passage passage) onOpenInReader,
  String? translationName,
  String selectedTranslationDirection = 'LTR',
  bool showSourceStyles = true,
  ReferenceRequest? initialRequest,
  ReferencePreviewLabels labels = const ReferencePreviewLabels(),
}) async {
  if (initialRequest != null) unawaited(controller.open(initialRequest));
  Widget content(BuildContext routeContext) => ReferencePreview(
    controller: controller,
    selectedTranslation: selectedTranslation,
    translationName: translationName,
    selectedTranslationDirection: selectedTranslationDirection,
    showSourceStyles: showSourceStyles,
    labels: labels,
    onOpenInReader: (Passage passage) async {
      final ReferenceResult? capturedResult = controller.result;
      final ModalRoute<Object?>? route = ModalRoute.of(routeContext);
      await onOpenInReader(passage);
      // This surface owns its dismissal. An old Open operation must not pop
      // another route after close, or dismiss a newly selected citation.
      if (!routeContext.mounted ||
          route?.isCurrent != true ||
          !controller.isVisible ||
          !identical(controller.result, capturedResult)) {
        return;
      }
      Navigator.of(routeContext).pop();
    },
    onClose: () => Navigator.of(routeContext).pop(),
  );
  try {
    if (MediaQuery.sizeOf(context).width < 900) {
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        builder: (BuildContext routeContext) => Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.viewInsetsOf(routeContext).bottom,
          ),
          child: SizedBox(
            height: MediaQuery.sizeOf(routeContext).height * .88,
            child: content(routeContext),
          ),
        ),
      );
    } else {
      await showDialog<void>(
        context: context,
        builder: (BuildContext routeContext) => Dialog(
          alignment: AlignmentDirectional.centerEnd,
          insetPadding: const EdgeInsets.all(12),
          child: SizedBox(
            width: 480,
            height: MediaQuery.sizeOf(routeContext).height - 24,
            child: content(routeContext),
          ),
        ),
      );
    }
  } finally {
    controller.close();
  }
}
