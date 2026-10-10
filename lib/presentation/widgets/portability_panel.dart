import 'package:flutter/material.dart';

import '../../application/portability_controller.dart';
import '../../core/ui_strings.dart';
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
        setState(
          () =>
              _status = UiStrings.of(context).text('File selection cancelled.'),
        );
      } else {
        await widget.controller.prepareImport(text);
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _status = error is TextFileException
              ? error.message
              : UiStrings.of(
                  context,
                ).text('The backup could not be opened. Please try again.');
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
          ? UiStrings.of(context).text('Complete private backup')
          : UiStrings.of(context).text('Website-compatible backup');
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
          Text(
            UiStrings.of(context).text('Private data'),
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 8),
          Text(
            UiStrings.of(context).text(
              'Keep your own backup of saved Scripture, verse notes, notebooks, drafts and preferences. Backups contain private text. Choose where you save them and who can access them.',
            ),
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              FilledButton.icon(
                onPressed: _busy ? null : () => _prepareExport(complete: true),
                icon: const Icon(Icons.backup_outlined),
                label: Text(
                  UiStrings.of(context).text('Prepare complete backup'),
                ),
              ),
              OutlinedButton(
                onPressed: _busy ? null : () => _prepareExport(complete: false),
                child: Text(
                  UiStrings.of(context).text('Prepare website backup'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            UiStrings.of(context).text(
              'Website backups include saved groups, markings, verse notes and reader preferences. They do not include notebooks, drafts or additional private settings. Downloaded study and Bible resources are not included in either format.',
            ),
          ),
          if (_export != null) ...<Widget>[
            const SizedBox(height: 16),
            Text(
              UiStrings.of(context).text(
                '{exportLabel} ready. Save the file to keep this snapshot.',
                {'exportLabel': _exportLabel!},
              ),
            ),
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
            UiStrings.of(context).text('Restore a backup'),
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          Text(
            UiStrings.of(context).text(
              'Choose a UTF-8 JSON backup up to 64 MiB. The entire file is checked before you confirm. Import merges saved data and keeps unrelated records; conflicting notebooks are preserved as separate copies.',
            ),
          ),
          const SizedBox(height: 8),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: OutlinedButton.icon(
              onPressed: _busy ? null : _pick,
              icon: const Icon(Icons.file_open_outlined),
              label: Text(UiStrings.of(context).text('Choose backup file')),
            ),
          ),
          if (_picking || widget.controller.busy)
            LinearProgressIndicator(
              semanticsLabel: UiStrings.of(
                context,
              ).text('Checking or transferring private data'),
            ),
          if (preview != null) ...<Widget>[
            const SizedBox(height: 16),
            Text(
              preview.isLegacy
                  ? UiStrings.of(context).text('Website backup preview')
                  : UiStrings.of(
                      context,
                    ).text('Complete private backup preview'),
              style: Theme.of(context).textTheme.titleMedium,
            ),
            Text(
              UiStrings.of(context).text(
                '{groups} groups, {markings} markings, {notes} verse notes, {notebooks} notebooks, {drafts} drafts, {settings} private settings.',
                {
                  'groups': preview.reader.groups.length,
                  'markings': preview.reader.markings.length,
                  'notes': preview.reader.notes.length,
                  'notebooks': preview.notebooks.length,
                  'drafts': preview.drafts.length,
                  'settings': preview.settings.length,
                },
              ),
            ),
            if (preview.isLegacy)
              Text(
                UiStrings.of(
                  context,
                ).text('This format does not contain notebooks or drafts.'),
              ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                FilledButton(
                  onPressed: _busy ? null : widget.controller.confirmImport,
                  child: Text(UiStrings.of(context).text('Confirm import')),
                ),
                TextButton(
                  onPressed: _busy ? null : widget.controller.clearImport,
                  child: Text(UiStrings.of(context).text('Cancel import')),
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
                  UiStrings.of(context).text(
                    'Import complete: {groupsAdded} groups added, {markingsAdded} markings added, {notesChanged} verse notes updated, {notebooksAdded} notebooks added, {draftsAdded} drafts added, {notebookConflicts} notebook conflicts preserved, {settingsRestored} preferences restored.',
                    {
                      'groupsAdded': imported.groupsAdded,
                      'markingsAdded': imported.markingsAdded,
                      'notesChanged': imported.notesChanged,
                      'notebooksAdded': imported.notebooksAdded,
                      'draftsAdded': imported.draftsAdded,
                      'notebookConflicts': imported.notebookConflicts,
                      'settingsRestored': imported.settingsRestored,
                    },
                  ),
                ),
              ),
            ),
          if (widget.controller.error ?? _status case final String message)
            Padding(
              padding: const EdgeInsets.only(top: 16),
              child: Semantics(
                liveRegion: true,
                child: Text(UiStrings.of(context).text(message)),
              ),
            ),
        ],
      );
    },
  );
}
