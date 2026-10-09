import 'package:flutter/material.dart';

import '../../application/portability_controller.dart';
import '../../domain/models/private_backup.dart';
import '../../services/text_file_service.dart';
import 'text_export_actions.dart';

/// File selection, validated preview and explicit merge confirmation. The caller
/// owns the controller so closing this panel cannot discard an active import.
class PortabilityPanel extends StatefulWidget {
  const PortabilityPanel({
    required this.controller,
    required this.files,
    super.key,
  });
  final PortabilityController controller;
  final TextFileService files;

  @override
  State<PortabilityPanel> createState() => _PortabilityPanelState();
}

class _PortabilityPanelState extends State<PortabilityPanel> {
  bool _picking = false;
  bool _exporting = false;
  String? _status;
  String? _export;
  String? _filename;
  String? _exportLabel;

  bool get _busy => _picking || _exporting || widget.controller.busy;

  Future<void> _pick() async {
    if (_busy) return;
    widget.controller.clearImport();
    setState(() {
      _picking = true;
      _status = null;
    });
    try {
      final String? text = await widget.files.pickText(
        maxBytes: maxPrivateBackupBytes,
      );
      if (!mounted) return;
      if (text == null) {
        setState(() => _status = 'File selection cancelled.');
      } else {
        await widget.controller.prepareImport(text);
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _status = error is TextFileException
              ? error.message
              : 'The backup could not be opened. Please try again.';
        });
      }
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  Future<void> _prepareExport({required bool complete}) async {
    if (_busy) return;
    setState(() => _status = null);
    final String? text = complete
        ? await widget.controller.exportComplete()
        : await widget.controller.exportWebsite();
    if (!mounted || text == null) return;
    final String date = DateTime.now().toUtc().toIso8601String().substring(
      0,
      10,
    );
    setState(() {
      _export = text;
      _exportLabel = complete
          ? 'Complete private backup'
          : 'Website-compatible backup';
      _filename = 'getbible-${complete ? 'private' : 'website'}-$date.json';
    });
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.controller,
    builder: (BuildContext context, Widget? child) {
      final PrivateBackup? preview = widget.controller.preparedImport;
      final PrivateImportResult? imported = widget.controller.importResult;
      return ListView(
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          Text('Private data', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          const Text(
            'Keep your own backup of saved Scripture, verse notes, notebooks, '
            'drafts and preferences. Backups contain private text. Choose where '
            'you save them and who can access them.',
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              FilledButton.icon(
                onPressed: _busy ? null : () => _prepareExport(complete: true),
                icon: const Icon(Icons.backup_outlined),
                label: const Text('Prepare complete backup'),
              ),
              OutlinedButton(
                onPressed: _busy ? null : () => _prepareExport(complete: false),
                child: const Text('Prepare website backup'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          const Text(
            'Website backups include saved groups, markings, verse notes and '
            'reader preferences. They do not include notebooks, drafts or '
            'additional private settings. Downloaded study and Bible resources '
            'are not included in either format.',
          ),
          if (_export != null) ...<Widget>[
            const SizedBox(height: 16),
            Text('$_exportLabel ready. Save the file to keep this snapshot.'),
            const SizedBox(height: 8),
            TextExportActions(
              text: _export!,
              filename: _filename!,
              mimeType: 'application/json',
              subject: _exportLabel!,
              files: widget.files,
              allowShare: false,
              onBusyChanged: (bool busy) {
                if (mounted) setState(() => _exporting = busy);
              },
            ),
          ],
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 16),
            child: Divider(),
          ),
          Text(
            'Restore a backup',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          const Text(
            'Choose a UTF-8 JSON backup up to 64 MiB. The entire file is checked '
            'before you confirm. Import merges saved data and keeps unrelated '
            'records; conflicting notebooks are preserved as separate copies.',
          ),
          const SizedBox(height: 8),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: OutlinedButton.icon(
              onPressed: _busy ? null : _pick,
              icon: const Icon(Icons.file_open_outlined),
              label: const Text('Choose backup file'),
            ),
          ),
          if (_picking || widget.controller.busy)
            const LinearProgressIndicator(
              semanticsLabel: 'Checking or transferring private data',
            ),
          if (preview != null) ...<Widget>[
            const SizedBox(height: 16),
            Text(
              preview.isLegacy
                  ? 'Website backup preview'
                  : 'Complete private backup preview',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            Text(
              '${preview.reader.groups.length} groups, '
              '${preview.reader.markings.length} markings, '
              '${preview.reader.notes.length} verse notes, '
              '${preview.notebooks.length} notebooks, '
              '${preview.drafts.length} drafts, '
              '${preview.settings.length} private settings.',
            ),
            if (preview.isLegacy)
              const Text('This format does not contain notebooks or drafts.'),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                FilledButton(
                  onPressed: _busy ? null : widget.controller.confirmImport,
                  child: const Text('Confirm import'),
                ),
                TextButton(
                  onPressed: _busy ? null : widget.controller.clearImport,
                  child: const Text('Cancel import'),
                ),
              ],
            ),
          ],
          if (imported != null)
            Padding(
              padding: const EdgeInsets.only(top: 16),
              child: Semantics(
                liveRegion: true,
                child: Text(
                  'Import complete: ${imported.groupsAdded} groups added, '
                  '${imported.markingsAdded} markings added, '
                  '${imported.notesChanged} verse notes updated, '
                  '${imported.notebooksAdded} notebooks added, '
                  '${imported.draftsAdded} drafts added, '
                  '${imported.notebookConflicts} notebook conflicts preserved, '
                  '${imported.settingsRestored} preferences restored.',
                ),
              ),
            ),
          if (widget.controller.error ?? _status case final String message)
            Padding(
              padding: const EdgeInsets.only(top: 16),
              child: Semantics(liveRegion: true, child: Text(message)),
            ),
        ],
      );
    },
  );
}
