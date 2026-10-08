import 'dart:async';

import 'package:flutter/material.dart';

import '../../application/dictionary_controller.dart';
import '../../domain/models/dictionary.dart';
import '../../domain/models/reference.dart';
import '../../domain/models/service_envelopes.dart';
import '../../domain/models/study_citation.dart';
import '../../domain/models/study_context.dart';

/// Native plain-text dictionary UI. The controller owns resource requests and
/// the reader supplies the one shared, selected-Bible Scripture preview.
final class DictionaryPanel extends StatefulWidget {
  const DictionaryPanel({
    required this.controller,
    required this.context,
    required this.onPreviewReference,
    super.key,
  });
  final DictionaryController controller;
  final StudyContext context;
  final Future<void> Function(ReferenceRequest) onPreviewReference;

  @override
  State<DictionaryPanel> createState() => _DictionaryPanelState();
}

final class _DictionaryPanelState extends State<DictionaryPanel> {
  final TextEditingController _query = TextEditingController();
  int _visibleMatches = 20;

  @override
  void initState() {
    super.initState();
    _openContext();
  }

  @override
  void didUpdateWidget(DictionaryPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller)) {
      oldWidget.controller.close();
    }
    if (!identical(oldWidget.context, widget.context) ||
        !identical(oldWidget.controller, widget.controller)) {
      _openContext();
    }
  }

  void _openContext() {
    _query.text = widget.context.selectedText ?? '';
    _visibleMatches = 20;
    unawaited(widget.controller.open(widget.context));
  }

  @override
  void dispose() {
    _query.dispose();
    widget.controller.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.controller,
    builder: (BuildContext context, Widget? child) {
      final DictionaryController state = widget.controller;
      final DictionaryLookup? lookup = state.lookup;
      final DictionaryEntry? entry = state.entry;
      return ListView(
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          if (lookup != null && lookup.sourceWord.isNotEmpty) ...<Widget>[
            SelectableText(
              lookup.sourceWord,
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            if (lookup.strongs.isNotEmpty) _detail('Strong’s', lookup.strongs),
            if (lookup.lemmas.isNotEmpty) _detail('Lemma', lookup.lemmas),
            if (lookup.morphology.isNotEmpty)
              _detail('Morphology', lookup.morphology),
            if (lookup.transliterations.isNotEmpty)
              _detail('Transliteration', lookup.transliterations),
            const SizedBox(height: 12),
          ],
          if (state.modules.isNotEmpty)
            DropdownButtonFormField<String>(
              key: ValueKey<String?>(state.selectedModule?.id),
              initialValue: state.selectedModule?.id,
              isExpanded: true,
              itemHeight: null,
              decoration: const InputDecoration(
                labelText: 'Dictionary',
                border: OutlineInputBorder(),
              ),
              hint: const Text('Choose a resource'),
              items: state.modules
                  .map(
                    (DictionaryModule module) => DropdownMenuItem<String>(
                      value: module.id,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: Text(
                          '${module.name} · ${module.language}${module.strongPrefix == null ? '' : ' · ${module.strongPrefix}'}',
                        ),
                      ),
                    ),
                  )
                  .toList(growable: false),
              onChanged: (String? id) {
                if (id != null) unawaited(state.selectModule(id));
              },
            ),
          const SizedBox(height: 12),
          if (state.needsResourceChoice)
            Text(
              state.modules.isEmpty
                  ? 'No dictionary resources are currently published.'
                  : 'No compatible default is available for ${widget.context.language}. Choose a resource; its source language will be shown.',
            ),
          if (state.metadata != null) ...<Widget>[
            Text('Source language: ${state.metadata!.language}'),
            const SizedBox(height: 12),
            TextField(
              controller: _query,
              decoration: const InputDecoration(
                labelText: 'Find a dictionary word',
                helperText:
                    'Searches published words and aliases, not definition text.',
                helperMaxLines: 3,
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.search),
              ),
              onChanged: (String query) {
                setState(() => _visibleMatches = 20);
                unawaited(state.searchIndex(query));
              },
            ),
          ],
          if (state.isLoading)
            const Padding(
              padding: EdgeInsets.all(16),
              child: Center(
                child: CircularProgressIndicator(
                  semanticsLabel: 'Loading dictionary',
                ),
              ),
            ),
          if (state.error != null) ...<Widget>[
            const SizedBox(height: 12),
            Text(
              state.error.toString(),
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton.icon(
                onPressed: () => unawaited(state.retry()),
                icon: const Icon(Icons.refresh),
                label: const Text('Retry dictionary'),
              ),
            ),
          ],
          if (state.preferenceError != null)
            const Text(
              'The resource choice could not be saved on this device. The dictionary remains available.',
            ),
          if (state.metadata != null &&
              !state.isLoading &&
              state.matches.isEmpty &&
              state.error == null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Text(
                state.query.isEmpty
                    ? 'Enter a word to search this dictionary’s index.'
                    : 'No published word or lexical identifier matches this lookup. Try another dictionary or enter a word.',
              ),
            ),
          if (state.matches.isNotEmpty) ...<Widget>[
            const SizedBox(height: 12),
            Text(
              '${state.matches.length} indexed definition${state.matches.length == 1 ? '' : 's'}',
            ),
            ...state.matches
                .take(_visibleMatches)
                .map(
                  (DictionaryIndexEntry match) => ListTile(
                    contentPadding: EdgeInsets.zero,
                    selected: entry?.id == match.id,
                    title: Text(match.key),
                    subtitle: Text(
                      '${match.id}${match.occurrence > 1 ? ' · definition ${match.occurrence}' : ''}',
                    ),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => unawaited(state.openEntry(match.id)),
                  ),
                ),
            if (state.matches.length > _visibleMatches)
              TextButton(
                onPressed: () => setState(() => _visibleMatches += 20),
                child: const Text('Show more dictionary words'),
              ),
          ],
          if (entry != null) ...<Widget>[
            const Divider(height: 24),
            if (state.canGoBack)
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: TextButton.icon(
                  onPressed: state.goBack,
                  icon: const Icon(Icons.arrow_back),
                  label: const Text('Previous dictionary word'),
                ),
              ),
            SelectableText(
              entry.key,
              style: Theme.of(context).textTheme.titleLarge,
            ),
            Text(
              '${entry.id} · ${entry.language} · definition ${entry.occurrence}',
            ),
            const SizedBox(height: 12),
            // SelectableText preserves paragraph breaks and renders source HTML
            // characters literally; definitions never enter an HTML renderer.
            SelectableText(entry.text),
            if (entry.references.isNotEmpty) ...<Widget>[
              const SizedBox(height: 12),
              const Text('Scripture citations'),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: entry.references
                    .map(
                      (StudyCitation citation) => ActionChip(
                        label: Text(citation.reference),
                        tooltip: citation.isScripture
                            ? citation.osis
                            : 'Introduction citation unavailable',
                        onPressed: citation.isScripture
                            ? () => unawaited(
                                widget.onPreviewReference(
                                  citation.requestFor(widget.context),
                                ),
                              )
                            : null,
                      ),
                    )
                    .toList(growable: false),
              ),
            ],
            if (entry.seeAlso.isNotEmpty) _links('See also', entry.seeAlso),
            if (entry.backlinks.isNotEmpty)
              _links('Linked from', entry.backlinks),
          ],
          if (state.metadata != null) ...<Widget>[
            const Divider(height: 24),
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              title: const Text('Dictionary attribution'),
              children: <Widget>[
                SelectableText(
                  '${state.metadata!.name}\n${state.metadata!.source}\n${state.metadata!.license}\n${state.metadata!.copyright}\n${state.metadata!.copyrightHolder}\n${state.metadata!.sourceModuleUrl}',
                ),
                const SizedBox(height: 8),
                SelectableText(state.metadata!.conversionNote),
                if (state.metadata!.textSource.isNotEmpty)
                  SelectableText(state.metadata!.textSource),
                if (state.metadata!.distributionNotes.isNotEmpty)
                  SelectableText(state.metadata!.distributionNotes),
                if (state.metadata!.about.isNotEmpty)
                  SelectableText(state.metadata!.about),
                Text(
                  'Citation provenance: ${state.metadata!.referenceApi} · ${state.metadata!.referenceVersification}',
                ),
              ],
            ),
          ],
        ],
      );
    },
  );

  Widget _detail(String label, List<String> values) => Padding(
    padding: const EdgeInsets.only(bottom: 4),
    child: SelectableText('$label: ${values.join(', ')}'),
  );

  Widget _links(String label, List<DictionaryLink> links) => Padding(
    padding: const EdgeInsets.only(top: 12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(label),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: links
              .map(
                (DictionaryLink link) => ActionChip(
                  label: Text(link.key),
                  onPressed: () =>
                      unawaited(widget.controller.openEntry(link.id)),
                ),
              )
              .toList(growable: false),
        ),
      ],
    ),
  );
}
