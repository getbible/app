import 'dart:async';

import 'package:flutter/material.dart';

import '../../application/offline_controller.dart';
import '../../domain/models/offline_resource.dart';

/// A native, scrollable resource manager. Opening it only reads durable local
/// state; fetching a catalogue and installing a resource are separate actions.
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
    unawaited(widget.controller.initialize());
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
                title: const Text('Offline resources'),
                trailing: widget.onClose == null
                    ? null
                    : IconButton(
                        tooltip: 'Close offline resources',
                        onPressed: widget.onClose,
                        icon: const Icon(Icons.close),
                      ),
              ),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    const Text(
                      'Install public Bibles and Study resources for use without a connection. Downloads start only when you choose Install. Notes and notebooks remain separate.',
                    ),
                    const SizedBox(height: 12),
                    Text(
                      '${_size(controller.usedBytes)} of ${_size(controller.quotaBytes)} offline content budget used. Device or browser storage may have a lower limit.',
                    ),
                    if (controller.error != null) ...[
                      const SizedBox(height: 12),
                      Semantics(
                        liveRegion: true,
                        child: Text(
                          controller.error!,
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
                          '${progress.label} · ${_size(progress.bytes)} saved',
                        ),
                      ),
                      const SizedBox(height: 8),
                      LinearProgressIndicator(value: progress.fraction),
                      Align(
                        alignment: AlignmentDirectional.centerEnd,
                        child: TextButton.icon(
                          onPressed: controller.cancel,
                          icon: const Icon(Icons.cancel_outlined),
                          label: const Text('Cancel download'),
                        ),
                      ),
                    ],
                    const SizedBox(height: 16),
                    Text(
                      'Installed',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    if (controller.installed.isEmpty)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 12),
                        child: Text(
                          'No complete resources installed yet. Previously opened online chapters may still be cached.',
                        ),
                      ),
                    Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: TextButton.icon(
                        onPressed: controller.refreshInstalled,
                        icon: const Icon(Icons.refresh),
                        label: const Text('Refresh download status'),
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
                              Text(attempt.message),
                              if (attempt.state != OfflineAttemptState.running)
                                TextButton.icon(
                                  onPressed: controller.installing
                                      ? null
                                      : () => _install(attempt.resource),
                                  icon: const Icon(Icons.refresh),
                                  label: const Text('Retry download'),
                                )
                              else
                                const Text(
                                  'A running download is protected. If its window closed unexpectedly, retry after two minutes.',
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
                          'Available resources',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        OutlinedButton.icon(
                          onPressed: controller.loading
                              ? null
                              : controller.discover,
                          icon: const Icon(Icons.refresh),
                          label: Text(
                            controller.catalog.isEmpty
                                ? 'Browse catalogue'
                                : 'Check for updates',
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
                        hint: const Text('All resources'),
                        isExpanded: true,
                        decoration: const InputDecoration(
                          labelText: 'Resource type',
                        ),
                        items: [
                          const DropdownMenuItem(
                            value: null,
                            child: Text('All resources'),
                          ),
                          for (final kind in OfflineResourceKind.values)
                            DropdownMenuItem(
                              value: kind,
                              child: Text(_kindLabel(kind)),
                            ),
                        ],
                        onChanged: (value) => setState(() => _kind = value),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        key: const ValueKey<String>('offline-resource-filter'),
                        controller: _filterController,
                        focusNode: _filterFocus,
                        decoration: const InputDecoration(
                          labelText: 'Find a resource',
                          prefixIcon: Icon(Icons.search),
                        ),
                        onChanged: (_) => setState(() {}),
                      ),
                      const SizedBox(height: 8),
                      for (final resource in items.take(100))
                        _catalogCard(resource),
                      if (items.length > 100)
                        const Text(
                          'Showing the first 100 resources. Narrow your search to find more.',
                        ),
                      if (items.isEmpty) const Text('No matching resources.'),
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
            '${_kindLabel(installed.resource.kind)} · ${_size(installed.byteCount)} · ${_hasUpdate(installed.resource) ? 'Update available' : 'Installed'}',
          ),
          Text(
            'Verified source revision: ${installed.resource.revision.isEmpty ? 'source snapshot' : installed.resource.revision}',
          ),
          if (installed.resource.attribution.isNotEmpty)
            Text(installed.resource.attribution),
          Wrap(
            spacing: 8,
            children: [
              TextButton.icon(
                onPressed: widget.controller.installing
                    ? null
                    : () => _install(_latest(installed.resource)),
                icon: const Icon(Icons.system_update_alt),
                label: const Text('Update / verify'),
              ),
              TextButton.icon(
                onPressed: widget.controller.installing
                    ? null
                    : () => _remove(installed),
                icon: const Icon(Icons.delete_outline),
                label: const Text('Remove download'),
              ),
            ],
          ),
        ],
      ),
    ),
  );

  bool _hasUpdate(OfflineResourceDescriptor existing) {
    final latest = _latest(existing);
    return latest.revision.isNotEmpty && latest.revision != existing.revision;
  }

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
              '${_kindLabel(resource.kind)} · ${resource.estimatedBytes == null ? 'Download size not published' : 'Estimated download: ${_size(resource.estimatedBytes!)}'}',
            ),
            if (resource.attribution.isNotEmpty) Text(resource.attribution),
            Text(
              resource.sourceUri.toString(),
              style: Theme.of(context).textTheme.bodySmall,
            ),
            TextButton.icon(
              onPressed: widget.controller.installing
                  ? null
                  : () => _install(resource),
              icon: Icon(installed ? Icons.system_update_alt : Icons.download),
              label: Text(installed ? 'Update / verify' : 'Install'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _install(OfflineResourceDescriptor resource) async {
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Install ${resource.title}?'),
        content: SingleChildScrollView(
          child: Text(
            [
              resource.estimatedBytes == null
                  ? 'The source does not publish a download size.'
                  : 'Estimated download: ${_size(resource.estimatedBytes!)}.',
              'An update temporarily needs space for both versions. The previous installation remains readable until every file is verified.',
              if (resource.attribution.isNotEmpty) resource.attribution,
            ].join('\n\n'),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Install'),
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
        title: Text('Remove ${resource.resource.title}?'),
        content: const Text(
          'This removes only the installed public resource and its search index. Your notes, notebooks, copied markings and preferences are preserved.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Remove download'),
          ),
        ],
      ),
    );
    if (accepted == true && mounted) {
      await widget.controller.remove(resource.resource.key);
    }
  }
}

String _kindLabel(OfflineResourceKind kind) => switch (kind) {
  OfflineResourceKind.bible => 'Bible',
  OfflineResourceKind.dictionary => 'Dictionary',
  OfflineResourceKind.commentary => 'Commentary',
  OfflineResourceKind.bookmarks => 'Public topics',
};

String _size(int bytes) => bytes < 1024 * 1024
    ? '${(bytes / 1024).toStringAsFixed(1)} KiB'
    : '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MiB';
