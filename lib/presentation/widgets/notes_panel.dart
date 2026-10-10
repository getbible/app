import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../application/notebook_controller.dart';
import '../../core/ui_strings.dart';
import '../../data/platform/platform_text_file_service.dart';
import '../../domain/models/notebook.dart';
import '../../domain/models/passage.dart';
import '../../domain/models/reference.dart';
import '../../domain/models/study_context.dart';
import '../../services/markdown_service.dart';
import '../../services/text_file_service.dart';
import 'notebook_input_limit_formatter.dart';
import 'text_export_actions.dart';

/// Local notebooks complement the reader's existing inline canonical notes.
/// No notebook content is sent to public services by this widget.
final class NotesPanel extends StatefulWidget {
  const NotesPanel({
    required this.controller,
    required this.context,
    required this.onPreviewReference,
    required this.onOpenPassage,
    this.files,
    super.key,
  });
  final NotebookController controller;
  final StudyContext context;
  final Future<void> Function(ReferenceRequest) onPreviewReference;
  final Future<void> Function(Passage) onOpenPassage;
  final TextFileService? files;
  @override
  State<NotesPanel> createState() => _NotesPanelState();
}

final class _NotesPanelState extends State<NotesPanel>
    with WidgetsBindingObserver {
  bool _preparingExport = false;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(widget.controller.load());
  }

  @override
  void didUpdateWidget(NotesPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      unawaited(oldWidget.controller.flush());
      unawaited(widget.controller.load());
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      unawaited(widget.controller.flush());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(widget.controller.flush());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Shortcuts(
    shortcuts: const <ShortcutActivator, Intent>{
      SingleActivator(LogicalKeyboardKey.enter, control: true):
          _SaveNotebookIntent(),
      SingleActivator(LogicalKeyboardKey.enter, meta: true):
          _SaveNotebookIntent(),
    },
    child: Actions(
      actions: <Type, Action<Intent>>{
        _SaveNotebookIntent: CallbackAction<_SaveNotebookIntent>(
          onInvoke: (_) {
            unawaited(widget.controller.flush());
            return null;
          },
        ),
      },
      child: AnimatedBuilder(
        animation: widget.controller,
        builder: (BuildContext context, Widget? child) {
          final NotebookController controller = widget.controller;
          final Notebook? notebook = controller.notebook;
          return ListView(
            key: const ValueKey<String>('notes-panel-list'),
            padding: const EdgeInsets.all(16),
            children: <Widget>[
              Text(
                UiStrings.of(context).text('Personal notebooks'),
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 8),
              Text(
                UiStrings.of(context).text(
                  'Study and sermon notes stay on this device. Verse notes remain inline under Scripture.',
                ),
              ),
              const SizedBox(height: 8),
              Text(
                UiStrings.of(context).text(
                  'Use Complete private backup to save notebooks and retained drafts. Website-compatible backups contain verse notes and markings only.',
                ),
                style: TextStyle(fontSize: 12),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: <Widget>[
                  FilledButton.icon(
                    onPressed: controller.isLoading
                        ? null
                        : () => controller.createNotebook(),
                    icon: const Icon(Icons.add),
                    label: Text(UiStrings.of(context).text('New notebook')),
                  ),
                  if (notebook != null)
                    OutlinedButton.icon(
                      onPressed: () => controller.flush(),
                      icon: const Icon(Icons.save_outlined),
                      label: Text(
                        controller.isSaving
                            ? UiStrings.of(context).text('Saving…')
                            : controller.isDirty
                            ? UiStrings.of(context).text('Save now')
                            : UiStrings.of(context).text('Saved locally'),
                      ),
                    ),
                  if (notebook != null)
                    OutlinedButton.icon(
                      onPressed: _preparingExport ? null : _exportMarkdown,
                      icon: const Icon(Icons.download_outlined),
                      label: Text(
                        UiStrings.of(context).text('Export notebook Markdown'),
                      ),
                    ),
                ],
              ),
              if (controller.error != null) ...<Widget>[
                const SizedBox(height: 12),
                Semantics(
                  liveRegion: true,
                  child: Material(
                    color: Theme.of(context).colorScheme.errorContainer,
                    borderRadius: BorderRadius.circular(8),
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(
                            UiStrings.of(context).text(
                              'The notebook could not be saved or loaded. Your open draft is retained. {error}',
                              {'error': controller.error.toString()},
                            ),
                          ),
                          TextButton.icon(
                            onPressed: controller.retry,
                            icon: const Icon(Icons.refresh),
                            label: Text(UiStrings.of(context).text('Retry')),
                          ),
                          if (controller.hasConflict)
                            TextButton(
                              onPressed: controller.recoverDraftAsNewNotebook,
                              child: Text(
                                UiStrings.of(
                                  context,
                                ).text('Save draft as new notebook'),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
              if (controller.inputLimitMessage != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Semantics(
                    liveRegion: true,
                    child: Text(controller.inputLimitMessage!),
                  ),
                ),
              if (controller.hasUnsavedDrafts && !controller.isDirty)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    UiStrings.of(context).text(
                      '{unsavedCount} other notebook draft(s) need saving.',
                      {'unsavedCount': controller.unsavedCount},
                    ),
                  ),
                ),
              if (controller.isLoading)
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: Center(child: CircularProgressIndicator()),
                ),
              if (controller.notebooks.isNotEmpty)
                ExpansionTile(
                  key: const PageStorageKey<String>('personal-notebook-list'),
                  title: Text(
                    notebook?.displayTitle ??
                        UiStrings.of(context).text('Choose a notebook'),
                  ),
                  subtitle: Text(
                    UiStrings.of(context).text('{length} notebook(s)', {
                      'length': controller.notebooks.length,
                    }),
                  ),
                  children: controller.notebooks
                      .map(
                        (NotebookSummary item) => ListTile(
                          selected: item.id == controller.selectedId,
                          title: Text(item.displayTitle),
                          subtitle: Text(
                            UiStrings.of(context).text(
                              '{blockCount} block(s)',
                              {'blockCount': item.blockCount},
                            ),
                          ),
                          onTap: () => controller.selectNotebook(item.id),
                        ),
                      )
                      .toList(growable: false),
                ),
              if (controller.additionalRecoveredDrafts.isNotEmpty) ...<Widget>[
                const SizedBox(height: 12),
                Text(
                  UiStrings.of(
                    context,
                  ).text('Additional recovered drafts from another editor:'),
                ),
                for (final NotebookDraft draft
                    in controller.additionalRecoveredDrafts)
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(draft.notebook.displayTitle),
                          Text(
                            UiStrings.of(context).text(
                              'Retained locally; the saved notebook is unchanged.',
                            ),
                          ),
                          TextButton.icon(
                            onPressed: () =>
                                controller.recoverSavedDraft(draft),
                            icon: const Icon(Icons.restore),
                            label: Text(
                              UiStrings.of(
                                context,
                              ).text('Save as new notebook'),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
              if (notebook == null && !controller.isLoading)
                Padding(
                  padding: EdgeInsets.symmetric(vertical: 24),
                  child: Text(
                    UiStrings.of(context).text(
                      'Create a notebook for your study notes or sermon outline.',
                    ),
                  ),
                ),
              if (notebook != null) ...<Widget>[
                const SizedBox(height: 12),
                _NotebookTitle(
                  key: ValueKey<String>('title:${notebook.id}'),
                  notebook: notebook,
                  inputFormatter: NotebookInputLimitFormatter(
                    codeUnitCapacity: () =>
                        controller.notebook?.titleTextCapacity ??
                        notebook.titleTextCapacity,
                    maxRunes: maxNotebookTitleRunes,
                    onLimit: () => _reportInputLimit(
                      UiStrings.of(context).text(
                        'This edit exceeds the title or notebook size limit. Shorten the text before continuing.',
                      ),
                    ),
                  ),
                  onChanged: (String title) =>
                      _edit(() => controller.updateTitle(title)),
                ),
                const SizedBox(height: 12),
                for (int index = 0; index < notebook.blocks.length; index++)
                  _NotebookBlockEditor(
                    key: ValueKey<String>(
                      '${notebook.id}:${notebook.blocks[index].id}',
                    ),
                    block: notebook.blocks[index],
                    inputFormatter: NotebookInputLimitFormatter(
                      codeUnitCapacity: () =>
                          controller.notebook?.blockTextCapacity(
                            notebook.blocks[index].id,
                          ) ??
                          notebook.blockTextCapacity(notebook.blocks[index].id),
                      onLimit: () => _reportInputLimit(
                        UiStrings.of(context).text(
                          'This edit exceeds the note block or notebook size limit. Shorten this block or another block before continuing.',
                        ),
                      ),
                    ),
                    position: index + 1,
                    canMoveUp: index > 0,
                    canMoveDown: index < notebook.blocks.length - 1,
                    onChanged: (String text) => _edit(
                      () => controller.updateBlockText(
                        notebook.blocks[index].id,
                        text,
                      ),
                    ),
                    onMoveUp: () =>
                        controller.moveBlock(notebook.blocks[index].id, -1),
                    onMoveDown: () =>
                        controller.moveBlock(notebook.blocks[index].id, 1),
                    onDelete: () => _deleteBlock(notebook.blocks[index]),
                    onPreview: _previewReference,
                    onOpen: (Passage passage) =>
                        _openPassage(notebook.id, passage),
                  ),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: <Widget>[
                    OutlinedButton.icon(
                      onPressed: notebook.blocks.length >= 1000
                          ? null
                          : () => _edit(controller.addTextBlock),
                      icon: const Icon(Icons.add),
                      label: Text(UiStrings.of(context).text('Add note block')),
                    ),
                    OutlinedButton.icon(
                      onPressed:
                          notebook.blocks.length >= 1000 ||
                              widget.context.verse == null ||
                              widget.context.chapter < 1
                          ? null
                          : _insertScripture,
                      icon: const Icon(Icons.format_quote),
                      label: Text(
                        UiStrings.of(context).text('Insert current Scripture'),
                      ),
                    ),
                    TextButton.icon(
                      onPressed: () => _deleteNotebook(notebook),
                      icon: const Icon(Icons.delete_outline),
                      label: Text(
                        UiStrings.of(context).text('Delete notebook'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  UiStrings.of(context).text(
                    'Autosaves locally. Ctrl/⌘ + Enter saves immediately.',
                  ),
                  style: TextStyle(fontSize: 12),
                ),
              ],
            ],
          );
        },
      ),
    ),
  );

  void _edit(VoidCallback action) {
    try {
      action();
    } on FormatException catch (error) {
      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(SnackBar(content: Text(error.message)));
    }
  }

  Future<void> _exportMarkdown() async {
    if (_preparingExport) return;
    final NotebookController controller = widget.controller;
    final String? notebookId = controller.selectedId;
    if (notebookId == null) return;
    setState(() => _preparingExport = true);
    try {
      await controller.flush();
      if (!mounted ||
          widget.controller != controller ||
          controller.selectedId != notebookId) {
        return;
      }
      if (controller.hasUndurableDrafts) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(
            content: Text(
              UiStrings.of(
                context,
              ).text('Save or retry your notebook draft before exporting.'),
            ),
          ),
        );
        return;
      }
      final Notebook? notebook = controller.notebook;
      if (notebook == null) return;
      final String markdown = exportNotebookMarkdown(notebook);
      final bool shortened = markdown.length > 32000;
      final String preview = shortened
          ? String.fromCharCodes(markdown.runes.take(32000))
          : markdown;
      final TextFileService files =
          widget.files ??
          PlatformTextFileService(
            textFilesLabel: UiStrings.of(context).text('Text and JSON files'),
          );
      bool busy = false;
      await showDialog<void>(
        context: context,
        builder: (BuildContext dialogContext) => StatefulBuilder(
          builder: (BuildContext dialogContext, StateSetter setDialogState) => PopScope(
            canPop: !busy,
            child: AlertDialog(
              title: Text(notebook.displayTitle),
              content: SizedBox(
                width: 640,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      UiStrings.of(context).text(
                        'Readable Markdown for saving or sharing. Use Complete private backup for a restorable copy.',
                      ),
                    ),
                    const SizedBox(height: 12),
                    Flexible(
                      child: SingleChildScrollView(
                        child: SelectableText(preview),
                      ),
                    ),
                    if (shortened)
                      Text(
                        UiStrings.of(context).text(
                          'Preview shortened. The saved file includes the complete notebook.',
                        ),
                      ),
                    const SizedBox(height: 12),
                    TextExportActions(
                      text: markdown,
                      filename: 'getbible-notebook.md',
                      mimeType: 'text/markdown',
                      subject: notebook.displayTitle,
                      files: files,
                      onBusyChanged: (bool value) =>
                          setDialogState(() => busy = value),
                    ),
                  ],
                ),
              ),
              actions: <Widget>[
                TextButton(
                  onPressed: busy
                      ? null
                      : () => Navigator.of(dialogContext).pop(),
                  child: Text(UiStrings.of(context).text('Close')),
                ),
              ],
            ),
          ),
        ),
      );
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(
            content: Text(
              UiStrings.of(context).text(
                'The notebook could not be exported. Your private draft remains available.',
              ),
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _preparingExport = false);
    }
  }

  void _reportInputLimit(String message) {
    // Input formatting completes before notifier-driven widget rebuilding.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.controller.reportInputLimit(message);
    });
  }

  Future<void> _previewReference(ReferenceRequest request) async {
    try {
      await widget.onPreviewReference(request);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(
            content: Text(
              UiStrings.of(context).text(
                'The reference could not be opened. {error}',
                {'error': error},
              ),
            ),
          ),
        );
      }
    }
  }

  Future<void> _openPassage(String notebookId, Passage passage) async {
    final NotebookController controller = widget.controller;
    final StudyContext source = widget.context;
    await controller.flush();
    if (!mounted ||
        widget.controller != controller ||
        controller.selectedId != notebookId ||
        widget.context != source) {
      return;
    }
    try {
      await widget.onOpenPassage(passage);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(
            content: Text(
              UiStrings.of(context).text(
                'The passage could not be opened. Your notebook draft is retained. {error}',
                {'error': error},
              ),
            ),
          ),
        );
      }
    }
  }

  Future<void> _insertScripture() async {
    final StudyContext source = widget.context;
    final String? notebookId = widget.controller.selectedId;
    if (source.verse == null || source.chapter < 1 || notebookId == null) {
      return;
    }
    final NotebookReference reference = NotebookReference(
      passage: source.passage.copyWith(verse: source.verse!.verse),
      label: source.label,
      quotation: source.selectedText ?? source.verse!.text,
      direction: source.direction.toUpperCase(),
    );
    bool quote = true;
    final bool? insert = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => StatefulBuilder(
        builder: (BuildContext dialogContext, StateSetter setState) => AlertDialog(
          title: Text(UiStrings.of(context).text('Insert Scripture')),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  '${reference.label} (${reference.passage.translation.toUpperCase()})',
                ),
                const SizedBox(height: 12),
                SelectableText(
                  reference.quotation,
                  textDirection: reference.direction == 'RTL'
                      ? TextDirection.rtl
                      : TextDirection.ltr,
                ),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(
                    UiStrings.of(context).text('Include this quotation'),
                  ),
                  value: quote,
                  onChanged: (bool? value) => setState(() {
                    quote = value ?? true;
                  }),
                ),
                TextButton.icon(
                  onPressed: () => _previewReference(reference.previewRequest),
                  icon: const Icon(Icons.visibility_outlined),
                  label: Text(
                    UiStrings.of(context).text('Open reference preview'),
                  ),
                ),
              ],
            ),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: Text(UiStrings.of(context).text('Cancel')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: Text(UiStrings.of(context).text('Insert')),
            ),
          ],
        ),
      ),
    );
    if (!mounted ||
        insert != true ||
        widget.controller.selectedId != notebookId) {
      return;
    }
    _edit(
      () => widget.controller.addReference(
        NotebookReference(
          passage: reference.passage,
          label: reference.label,
          quotation: quote ? reference.quotation : '',
          direction: reference.direction,
        ),
      ),
    );
  }

  Future<void> _deleteBlock(NotebookBlock block) async {
    final String? selected = widget.controller.selectedId;
    final bool? confirmed = await _confirm(
      UiStrings.of(context).text('Delete note block?'),
      UiStrings.of(
        context,
      ).text('This permanently deletes this block from the notebook.'),
    );
    if (mounted &&
        confirmed == true &&
        selected == widget.controller.selectedId) {
      widget.controller.deleteBlock(block.id);
    }
  }

  Future<void> _deleteNotebook(Notebook notebook) async {
    final bool? confirmed = await _confirm(
      UiStrings.of(context).text('Delete notebook?'),
      UiStrings.of(context).text(
        '“{displayTitle}” and its blocks will be permanently deleted from this device.',
        {'displayTitle': notebook.displayTitle},
      ),
    );
    if (mounted && confirmed == true) {
      await widget.controller.deleteNotebook(notebook.id);
    }
  }

  Future<bool?> _confirm(String title, String body) => showDialog<bool>(
    context: context,
    builder: (BuildContext context) => AlertDialog(
      title: Text(title),
      content: Text(body),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: Text(UiStrings.of(context).text('Cancel')),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: Text(UiStrings.of(context).text('Delete')),
        ),
      ],
    ),
  );
}

final class _SaveNotebookIntent extends Intent {
  const _SaveNotebookIntent();
}

final class _NotebookTitle extends StatelessWidget {
  const _NotebookTitle({
    required this.notebook,
    required this.onChanged,
    required this.inputFormatter,
    super.key,
  });
  final Notebook notebook;
  final ValueChanged<String> onChanged;
  final TextInputFormatter inputFormatter;
  @override
  Widget build(BuildContext context) => TextFormField(
    initialValue: notebook.title,
    inputFormatters: <TextInputFormatter>[inputFormatter],
    decoration: InputDecoration(
      labelText: UiStrings.of(context).text('Notebook title'),
      border: const OutlineInputBorder(),
      counterText: '${notebook.title.runes.length} / $maxNotebookTitleRunes',
    ),
    onChanged: onChanged,
  );
}

final class _NotebookBlockEditor extends StatelessWidget {
  const _NotebookBlockEditor({
    required this.block,
    required this.position,
    required this.canMoveUp,
    required this.canMoveDown,
    required this.onChanged,
    required this.inputFormatter,
    required this.onMoveUp,
    required this.onMoveDown,
    required this.onDelete,
    required this.onPreview,
    required this.onOpen,
    super.key,
  });
  final NotebookBlock block;
  final int position;
  final bool canMoveUp;
  final bool canMoveDown;
  final ValueChanged<String> onChanged;
  final TextInputFormatter inputFormatter;
  final VoidCallback onMoveUp;
  final VoidCallback onMoveDown;
  final VoidCallback onDelete;
  final Future<void> Function(ReferenceRequest) onPreview;
  final Future<void> Function(Passage) onOpen;
  @override
  Widget build(BuildContext context) => Card(
    margin: const EdgeInsets.only(bottom: 12),
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 4,
            children: <Widget>[
              Text(
                UiStrings.of(
                  context,
                ).text('Block {position}', {'position': position}),
                style: Theme.of(context).textTheme.titleSmall,
              ),
              IconButton(
                tooltip: UiStrings.of(context).text('Move block up'),
                onPressed: canMoveUp ? onMoveUp : null,
                icon: const Icon(Icons.arrow_upward),
              ),
              IconButton(
                tooltip: UiStrings.of(context).text('Move block down'),
                onPressed: canMoveDown ? onMoveDown : null,
                icon: const Icon(Icons.arrow_downward),
              ),
              IconButton(
                tooltip: UiStrings.of(context).text('Delete note block'),
                onPressed: onDelete,
                icon: const Icon(Icons.delete_outline),
              ),
            ],
          ),
          if (block.reference
              case final NotebookReference reference) ...<Widget>[
            Text(
              '${reference.label} (${reference.passage.translation.toUpperCase()})',
              style: Theme.of(context).textTheme.labelLarge,
            ),
            if (reference.quotation.isNotEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: SelectableText(
                  reference.quotation,
                  textDirection: reference.direction == 'RTL'
                      ? TextDirection.rtl
                      : TextDirection.ltr,
                ),
              ),
            Wrap(
              spacing: 8,
              children: <Widget>[
                TextButton(
                  onPressed: () => onPreview(reference.previewRequest),
                  child: Text(UiStrings.of(context).text('Reference preview')),
                ),
                TextButton(
                  onPressed: () => onOpen(reference.passage),
                  child: Text(UiStrings.of(context).text('Open in reader')),
                ),
              ],
            ),
          ],
          TextFormField(
            initialValue: block.text,
            minLines: 3,
            maxLines: null,
            inputFormatters: <TextInputFormatter>[inputFormatter],
            keyboardType: TextInputType.multiline,
            decoration: InputDecoration(
              labelText: block.reference == null
                  ? UiStrings.of(context).text('Study or sermon notes')
                  : UiStrings.of(context).text('Notes about this Scripture'),
              alignLabelWithHint: true,
              border: const OutlineInputBorder(),
              counterText: '${block.text.length} / $maxNotebookBlockCodeUnits',
            ),
            onChanged: onChanged,
          ),
        ],
      ),
    ),
  );
}
