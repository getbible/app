import 'package:flutter/material.dart';

import '../../core/ui_strings.dart';
import '../../services/text_file_service.dart';

/// Platform actions shared by Scripture, notebook Markdown and private backups.
/// Keep the document visible after failure so another export route remains usable.
class TextExportActions extends StatefulWidget {
  const TextExportActions({
    required this.text,
    required this.filename,
    required this.mimeType,
    required this.subject,
    required this.files,
    this.allowShare = true,
    this.onBusyChanged,
    super.key,
  });
  final String text;
  final String filename;
  final String mimeType;
  final String subject;
  final TextFileService files;
  final bool allowShare;
  final ValueChanged<bool>? onBusyChanged;

  @override
  State<TextExportActions> createState() => _TextExportActionsState();
}

class _TextExportActionsState extends State<TextExportActions> {
  bool _busy = false;
  String? _status;
  int _revision = 0;

  @override
  void didUpdateWidget(TextExportActions oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text ||
        oldWidget.filename != widget.filename) {
      _revision++;
      _status = null;
    }
  }

  Future<void> _run(Future<String> Function() operation) async {
    if (_busy) return;
    final int revision = _revision;
    setState(() {
      _busy = true;
      _status = null;
    });
    widget.onBusyChanged?.call(true);
    String message;
    try {
      message = await operation();
    } catch (error) {
      message = error is TextFileException
          ? error.message
          : 'The operation could not be completed. Please try another option.';
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (revision == _revision) _status = message;
    });
    widget.onBusyChanged?.call(false);
  }

  Future<String> _save() async {
    final TextSaveResult result = await widget.files.saveText(
      text: widget.text,
      filename: widget.filename,
      mimeType: widget.mimeType,
    );
    return switch (result) {
      TextSaveResult.saved => 'File saved.',
      TextSaveResult.downloadRequested =>
        'Download requested. Check your browser downloads to keep the file.',
      TextSaveResult.cancelled => 'Save cancelled.',
      TextSaveResult.unsupported =>
        'Saving is unavailable. Copy the text instead.',
    };
  }

  Future<String> _share() async {
    final TextShareResult result = await widget.files.shareText(
      text: widget.text,
      subject: widget.subject,
    );
    return switch (result) {
      TextShareResult.completed => 'Share completed.',
      TextShareResult.presented =>
        'Share sheet opened. Choose an app to finish sharing.',
      TextShareResult.cancelled => 'Share cancelled.',
      TextShareResult.unsupported =>
        'Sharing is unavailable here. Save or copy the text instead.',
    };
  }

  Future<String> _copy() async {
    await widget.files.copyText(widget.text);
    return 'Text copied.';
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisSize: MainAxisSize.min,
    children: <Widget>[
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: <Widget>[
          FilledButton.icon(
            onPressed: _busy ? null : () => _run(_save),
            icon: const Icon(Icons.save_alt),
            label: Text(UiStrings.of(context).text('Save file')),
          ),
          if (widget.allowShare)
            OutlinedButton.icon(
              onPressed: _busy ? null : () => _run(_share),
              icon: const Icon(Icons.share),
              label: Text(UiStrings.of(context).text('Share')),
            ),
          OutlinedButton.icon(
            onPressed: _busy ? null : () => _run(_copy),
            icon: const Icon(Icons.copy),
            label: Text(UiStrings.of(context).text('Copy')),
          ),
        ],
      ),
      if (_busy)
        Padding(
          padding: EdgeInsets.only(top: 8),
          child: LinearProgressIndicator(
            semanticsLabel: UiStrings.of(context).text('Export in progress'),
          ),
        ),
      if (_status != null)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Semantics(
            liveRegion: true,
            child: Text(UiStrings.of(context).text(_status!)),
          ),
        ),
    ],
  );
}
