import 'dart:async';

import 'package:flutter/material.dart';

import '../../application/offline_controller.dart';
import '../../core/ui_strings.dart';
import '../../domain/models/offline_resource.dart';

/// Central controls for automatic public downloads and optional bookmark data.
/// Private notes and bookmarks are never removed by this manager.
class OfflineSetupPanel extends StatefulWidget {
  const OfflineSetupPanel({super.key, required this.controller, this.onClose});
  final OfflineController controller;
  final VoidCallback? onClose;
  @override
  State<OfflineSetupPanel> createState() => _OfflineSetupPanelState();
}

class _OfflineSetupPanelState extends State<OfflineSetupPanel> {
  OfflineResourceKind? _kind;
  // Progress and installed cards change the controls' positions in the lazy
  // list. Keep the editor state here and key its widget so those updates do not
  // reset the visible query, selection or focus while filtering remains active.
  final TextEditingController _filterController = TextEditingController();
  final FocusNode _filterFocus = FocusNode(
    debugLabel: 'Offline resource filter',
  );

  @override
  void initState() {
    super.initState();
    unawaited(widget.controller.refreshInstalled());
  }

  @override
  void dispose() {
    _filterController.dispose();
    _filterFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.controller,
    builder: (context, _) {
      final controller = widget.controller;
      final items = controller.catalog
          .where(
            (resource) =>
                (_kind == null || resource.kind == _kind) &&
                ('${resource.title} ${resource.id}').toLowerCase().contains(
                  _filterController.text.toLowerCase(),
                ),
          )
          .toList();
      return Material(
        child: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ListTile(
                title: Text(UiStrings.of(context).text('Downloads & storage')),
                trailing: widget.onClose == null
                    ? null
                    : IconButton(
                        tooltip: UiStrings.of(
                          context,
                        ).text('Close offline resources'),
                        onPressed: widget.onClose,
                        icon: const Icon(Icons.close),
                      ),
              ),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    Text(
                      UiStrings.of(context).text(
                        'Bibles download in full when you open them. Dictionaries and commentaries download automatically unless you turn off Keep offline. The complete bookmark dataset downloads only when you choose Install.',
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      UiStrings.of(context).text(
                        'While the app is open, saved resources are checked for updates every 30 days. Changed content replaces the previous copy only after verification.',
                      ),
                    ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        OutlinedButton.icon(
                          onPressed: controller.checking
                              ? null
                              : () => controller.checkForUpdates(force: true),
                          icon: const Icon(Icons.refresh),
                          label: Text(
                            UiStrings.of(context).text('Check for updates'),
                          ),
                        ),
                        TextButton.icon(
                          onPressed: _clearDownloads,
                          icon: const Icon(Icons.delete_outline),
                          label: Text(
                            UiStrings.of(context).text('Clear downloads'),
                          ),
                        ),
                      ],
                    ),
                    if (controller.queuedCount > 0)
                      Text(
                        UiStrings.of(context).text(
                          '{count} downloads waiting',
                          {'count': '${controller.queuedCount}'},
                        ),
                      ),
                    const SizedBox(height: 12),
                    Text(
                      UiStrings.of(context).text(
                        '{usedBytes} of {quotaBytes} offline content budget used. Device or browser storage may have a lower limit.',
                        {
                          'usedBytes': _size(controller.usedBytes),
                          'quotaBytes': _size(controller.quotaBytes),
                        },
                      ),
                    ),
                    if (controller.error != null) ...[
                      const SizedBox(height: 12),
                      Semantics(
                        liveRegion: true,
                        child: Text(
                          UiStrings.of(context).text(controller.error!),
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      ),
                    ],
                    if (controller.progress case final progress?) ...[
                      const SizedBox(height: 12),
                      Semantics(
                        liveRegion: true,
                        child: Text(
                          UiStrings.of(
                            context,
                          ).text('{label} · {bytes} saved', {
                            'label': _progressLabel(progress),
                            'bytes': _size(progress.bytes),
                          }),
                        ),
                      ),
                      const SizedBox(height: 8),
                      LinearProgressIndicator(value: progress.fraction),
                      Align(
                        alignment: AlignmentDirectional.centerEnd,
                        child: TextButton.icon(
                          onPressed: controller.cancel,
                          icon: const Icon(Icons.cancel_outlined),
                          label: Text(
                            UiStrings.of(context).text('Cancel download'),
                          ),
                        ),
                      ),
                    ],
                    const SizedBox(height: 16),
                    Text(
                      UiStrings.of(context).text('Installed'),
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    if (controller.installed.isEmpty)
                      Padding(
                        padding: EdgeInsets.symmetric(vertical: 12),
                        child: Text(
                          UiStrings.of(context).text(
                            'No complete resources saved yet. Automatic downloads will continue when a connection is available.',
                          ),
                        ),
                      ),
                    Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: TextButton.icon(
                        onPressed: controller.refreshInstalled,
                        icon: const Icon(Icons.refresh),
                        label: Text(
                          UiStrings.of(context).text('Refresh download status'),
                        ),
                      ),
                    ),
                    for (final installed in controller.installed)
                      _installedCard(installed),
                    for (final attempt in controller.attempts)
                      Card(
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                attempt.resource.title,
                                style: Theme.of(context).textTheme.titleSmall,
                              ),
                              Text(UiStrings.of(context).text(attempt.message)),
                              if (attempt.state != OfflineAttemptState.running)
                                TextButton.icon(
                                  onPressed: controller.installing
                                      ? null
                                      : () => _install(attempt.resource),
                                  icon: const Icon(Icons.refresh),
                                  label: Text(
                                    UiStrings.of(
                                      context,
                                    ).text('Retry download'),
                                  ),
                                )
                              else
                                Text(
                                  UiStrings.of(context).text(
                                    'A running download is protected. If its window closed unexpectedly, retry after two minutes.',
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                    const SizedBox(height: 16),
                    Wrap(
                      spacing: 12,
                      runSpacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(
                          UiStrings.of(context).text('Available resources'),
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        OutlinedButton.icon(
                          onPressed: controller.loading
                              ? null
                              : controller.discover,
                          icon: const Icon(Icons.refresh),
                          label: Text(
                            UiStrings.of(context).text('Browse catalogue'),
                          ),
                        ),
                      ],
                    ),
                    if (controller.loading)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 12),
                        child: LinearProgressIndicator(),
                      ),
                    if (controller.catalog.isNotEmpty) ...[
                      const SizedBox(height: 12),
                      DropdownButtonFormField<OfflineResourceKind>(
                        key: const ValueKey<String>('offline-resource-kind'),
                        initialValue: _kind,
                        hint: Text(UiStrings.of(context).text('All resources')),
                        isExpanded: true,
                        decoration: InputDecoration(
                          labelText: UiStrings.of(
                            context,
                          ).text('Resource type'),
                        ),
                        items: [
                          DropdownMenuItem(
                            value: null,
                            child: Text(
                              UiStrings.of(context).text('All resources'),
                            ),
                          ),
                          for (final kind in OfflineResourceKind.values)
                            DropdownMenuItem(
                              value: kind,
                              child: Text(_kindLabel(context, kind)),
                            ),
                        ],
                        onChanged: (value) => setState(() => _kind = value),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        key: const ValueKey<String>('offline-resource-filter'),
                        controller: _filterController,
                        focusNode: _filterFocus,
                        decoration: InputDecoration(
                          labelText: UiStrings.of(
                            context,
                          ).text('Find a resource'),
                          prefixIcon: Icon(Icons.search),
                        ),
                        onChanged: (_) => setState(() {}),
                      ),
                      const SizedBox(height: 8),
                      for (final resource in items.take(100))
                        _catalogCard(resource),
                      if (items.length > 100)
                        Text(
                          UiStrings.of(context).text(
                            'Showing the first 100 resources. Narrow your search to find more.',
                          ),
                        ),
                      if (items.isEmpty)
                        Text(
                          UiStrings.of(context).text('No matching resources.'),
                        ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    },
  );

  String _progressLabel(OfflineProgress progress) {
    final strings = UiStrings.of(context);
    final resource = <OfflineResourceDescriptor>[
      ...widget.controller.catalog,
      ...widget.controller.installed.map((item) => item.resource),
    ].where((item) => item.key == progress.resourceKey).firstOrNull;
    if (resource != null) {
      if (progress.label == 'Downloading ${resource.title}') {
        return strings.text('Downloading {name}', {'name': resource.title});
      }
      if (progress.label == 'Indexing ${resource.title}') {
        return strings.text('Indexing {name}', {'name': resource.title});
      }
      if (progress.label == 'Verified ${resource.title}') {
        return strings.text('Verified {name}', {'name': resource.title});
      }
    }
    return strings.text(progress.label);
  }

  Widget _installedCard(OfflineInstalledResource installed) => Card(
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            installed.resource.title,
            style: Theme.of(context).textTheme.titleSmall,
          ),
          Text(
            '${_kindLabel(context, installed.resource.kind)} · ${_size(installed.byteCount)} · ${UiStrings.of(context).text('Available offline')}',
          ),
          Text(
            UiStrings.of(context).text('Verified source revision: {revision}', {
              'revision': installed.resource.revision.isEmpty
                  ? 'source snapshot'
                  : installed.resource.revision,
            }),
          ),
          if (installed.resource.attribution.isNotEmpty)
            Text(installed.resource.attribution),
          if (_automaticKind(installed.resource.kind))
            _automaticChoice(installed.resource),
          Wrap(
            spacing: 8,
            children: [
              TextButton.icon(
                onPressed: widget.controller.installing
                    ? null
                    : () => _install(_latest(installed.resource)),
                icon: const Icon(Icons.system_update_alt),
                label: Text(UiStrings.of(context).text('Update / verify')),
              ),
              TextButton.icon(
                onPressed: () => _remove(installed),
                icon: const Icon(Icons.delete_outline),
                label: Text(UiStrings.of(context).text('Remove download')),
              ),
            ],
          ),
        ],
      ),
    ),
  );

  OfflineResourceDescriptor _latest(OfflineResourceDescriptor existing) {
    for (final item in widget.controller.catalog) {
      if (item.key == existing.key) return item;
    }
    return existing;
  }

  Widget _catalogCard(OfflineResourceDescriptor resource) {
    final installed = widget.controller.installed.any(
      (item) => item.resource.key == resource.key,
    );
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(resource.title, style: Theme.of(context).textTheme.titleSmall),
            Text(
              '${_kindLabel(context, resource.kind)} · ${resource.estimatedBytes == null ? UiStrings.of(context).text('Download size not published') : UiStrings.of(context).text('Estimated download: {estimatedBytes}', {'estimatedBytes': _size(resource.estimatedBytes!)})}',
            ),
            if (resource.attribution.isNotEmpty) Text(resource.attribution),
            Text(
              resource.sourceUri.toString(),
              style: Theme.of(context).textTheme.bodySmall,
            ),
            if (_automaticKind(resource.kind))
              _automaticChoice(resource)
            else
              TextButton.icon(
                onPressed: widget.controller.installing
                    ? null
                    : () => _install(resource),
                icon: Icon(
                  installed ? Icons.system_update_alt : Icons.download,
                ),
                label: Text(
                  installed
                      ? UiStrings.of(context).text('Update / verify')
                      : UiStrings.of(context).text('Install'),
                ),
              ),
          ],
        ),
      ),
    );
  }

  bool _automaticKind(OfflineResourceKind kind) =>
      kind == OfflineResourceKind.dictionary ||
      kind == OfflineResourceKind.commentary;

  Widget _automaticChoice(OfflineResourceDescriptor resource) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      CheckboxListTile(
        contentPadding: EdgeInsets.zero,
        controlAffinity: ListTileControlAffinity.leading,
        title: Text(UiStrings.of(context).text('Keep offline')),
        subtitle: Text(
          UiStrings.of(context).text(
            'Turning this off removes the downloaded copy and stops automatic downloads for this resource.',
          ),
        ),
        value: !widget.controller.excludedKeys.contains(resource.key),
        onChanged: (enabled) {
          if (enabled != null) {
            unawaited(
              widget.controller.setAutomaticDownload(resource, enabled),
            );
          }
        },
      ),
      if (widget.controller.failures[resource.key] case final failure?)
        Text(
          UiStrings.of(context).text(failure),
          style: TextStyle(color: Theme.of(context).colorScheme.error),
        ),
    ],
  );

  Future<void> _clearDownloads() async {
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(UiStrings.of(context).text('Clear downloads?')),
        content: SingleChildScrollView(
          child: Text(
            UiStrings.of(context).text(
              'This removes public downloads and cached content. Your notes, notebooks, bookmarks and download choices remain. Bibles download again when opened; enabled dictionaries and commentaries return on next use or startup. The complete bookmark dataset stays removed until you choose to install it again.',
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(UiStrings.of(context).text('Cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(UiStrings.of(context).text('Clear downloads')),
          ),
        ],
      ),
    );
    if (accepted == true && mounted) await widget.controller.clearDownloads();
  }

  Future<void> _install(OfflineResourceDescriptor resource) async {
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          UiStrings.of(
            context,
          ).text('Install {title}?', {'title': resource.title}),
        ),
        content: SingleChildScrollView(
          child: Text(
            [
              resource.estimatedBytes == null
                  ? UiStrings.of(
                      context,
                    ).text('The source does not publish a download size.')
                  : UiStrings.of(context).text(
                      'Estimated download: {estimatedBytes}.',
                      {'estimatedBytes': _size(resource.estimatedBytes!)},
                    ),
              UiStrings.of(context).text(
                'An update temporarily needs space for both versions. The previous installation remains readable until every file is verified.',
              ),
              if (resource.attribution.isNotEmpty) resource.attribution,
            ].join('\n\n'),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(UiStrings.of(context).text('Cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(UiStrings.of(context).text('Install')),
          ),
        ],
      ),
    );
    if (accepted == true && mounted) await widget.controller.install(resource);
  }

  Future<void> _remove(OfflineInstalledResource resource) async {
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          UiStrings.of(
            context,
          ).text('Remove {title}?', {'title': resource.resource.title}),
        ),
        content: Text(
          UiStrings.of(context).text(
            'This removes only the installed public resource and its search index. Your notes, notebooks, copied markings and preferences are preserved.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(UiStrings.of(context).text('Cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(UiStrings.of(context).text('Remove download')),
          ),
        ],
      ),
    );
    if (accepted == true && mounted) {
      await widget.controller.remove(resource.resource.key);
    }
  }
}

String _kindLabel(
  BuildContext context,
  OfflineResourceKind kind,
) => switch (kind) {
  OfflineResourceKind.bible => UiStrings.of(context).text('Bible'),
  OfflineResourceKind.dictionary => UiStrings.of(context).text('Dictionary'),
  OfflineResourceKind.commentary => UiStrings.of(context).text('Commentary'),
  OfflineResourceKind.bookmarks => UiStrings.of(context).text('Public topics'),
};

String _size(int bytes) => bytes < 1024 * 1024
    ? '${(bytes / 1024).toStringAsFixed(1)} KiB'
    : '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MiB';
