import 'dart:async';

import 'package:flutter/material.dart';

import '../../application/dictionary_controller.dart';
import '../../core/ui_strings.dart';
import '../../domain/models/dictionary.dart';
import '../../domain/models/reference.dart';
import '../../domain/models/service_envelopes.dart';
import '../../domain/models/study_citation.dart';
import '../../domain/models/study_context.dart';
import 'study_offline_status.dart';

/// Native plain-text dictionary UI. The controller owns resource requests and
/// the reader supplies the one shared, selected-Bible Scripture preview.
final class DictionaryPanel extends StatefulWidget {
  const DictionaryPanel({
    required this.controller,
    required this.context,
    required this.onPreviewReference,
    this.onSetUpOffline,
    super.key,
  });
  final DictionaryController controller;
  final StudyContext context;
  final Future<void> Function(ReferenceRequest) onPreviewReference;
  final VoidCallback? onSetUpOffline;

  @override
  State<DictionaryPanel> createState() => _DictionaryPanelState();
}

final class _DictionaryPanelState extends State<DictionaryPanel> {
  final TextEditingController _query = TextEditingController();
  int _visibleMatches = 20;
  int _openingGeneration = 0;

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
    final generation = ++_openingGeneration;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && generation == _openingGeneration) {
        unawaited(widget.controller.open(widget.context));
      }
    });
  }

  @override
  void dispose() {
    _openingGeneration++;
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
          StudyOfflineStatus(
            installed: state.selectedModule == null ? null : state.isInstalled,
            onSetUpOffline: widget.onSetUpOffline,
          ),
          if (lookup != null && lookup.sourceWord.isNotEmpty) ...<Widget>[
            SelectableText(
              lookup.sourceWord,
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            if (lookup.strongs.isNotEmpty)
              _detail(UiStrings.of(context).text('Strong’s'), lookup.strongs),
            if (lookup.lemmas.isNotEmpty)
              _detail(UiStrings.of(context).text('Lemma'), lookup.lemmas),
            if (lookup.morphology.isNotEmpty)
              _detail(
                UiStrings.of(context).text('Morphology'),
                lookup.morphology,
              ),
            if (lookup.transliterations.isNotEmpty)
              _detail(
                UiStrings.of(context).text('Transliteration'),
                lookup.transliterations,
              ),
            const SizedBox(height: 12),
          ],
          TextField(
            key: const ValueKey('dictionary-lookup-query'),
            controller: _query,
            enabled: state.modules.isNotEmpty,
            textInputAction: TextInputAction.search,
            maxLength: 500,
            decoration: InputDecoration(
              labelText: UiStrings.of(context).text('Find a dictionary word'),
              helperText: UiStrings.of(context).text(
                'Searches published words and aliases, not definition text.',
              ),
              helperMaxLines: 3,
              border: const OutlineInputBorder(),
              suffixIcon: IconButton(
                tooltip: UiStrings.of(context).text('Search dictionaries'),
                onPressed: () => unawaited(state.searchWords(_query.text)),
                icon: const Icon(Icons.search),
              ),
            ),
            onSubmitted: (query) => unawaited(state.searchWords(query)),
            onChanged: state.isBrowsing
                ? (query) {
                    setState(() => _visibleMatches = 20);
                    unawaited(state.searchIndex(query));
                  }
                : null,
          ),
          const SizedBox(height: 12),
          if (!state.isBrowsing)
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton(
                onPressed: () {
                  _query.clear();
                  unawaited(state.searchWords(''));
                },
                child: Text(
                  UiStrings.of(context).text('Browse all dictionaries'),
                ),
              ),
            ),
          if (state.choices.isNotEmpty)
            DropdownButtonFormField<String>(
              key: ValueKey<String?>(state.selectedModule?.id),
              initialValue: state.selectedModule?.id,
              isExpanded: true,
              itemHeight: null,
              decoration: InputDecoration(
                labelText: state.isBrowsing
                    ? UiStrings.of(context).text('Dictionary')
                    : UiStrings.of(
                        context,
                      ).text('Dictionaries with definitions'),
                border: OutlineInputBorder(),
              ),
              hint: Text(UiStrings.of(context).text('Choose a resource')),
              items: state.choices
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
                  ? UiStrings.of(
                      context,
                    ).text('No dictionary resources are currently published.')
                  : state.choices.isEmpty && !state.isBrowsing
                  ? ''
                  : UiStrings.of(context).text(
                      'Choose a dictionary with a confirmed definition. Its source language is shown.',
                      const {},
                    ),
            ),
          if (state.metadata != null) ...<Widget>[
            Text(
              UiStrings.of(context).text('Source language: {language}', {
                'language': state.metadata!.language,
              }),
            ),
            const SizedBox(height: 12),
          ],
          if (state.usingInstalledChoices) ...[
            Text(
              UiStrings.of(context).text('Searching installed dictionaries.'),
            ),
            if (state.onlineChoicesAvailable)
              TextButton.icon(
                onPressed: () => unawaited(state.includeOnlineDictionaries()),
                icon: const Icon(Icons.public),
                label: Text(
                  UiStrings.of(context).text('Include online dictionaries'),
                ),
              ),
          ],
          if (state.isDiscovering)
            Semantics(
              liveRegion: true,
              label: UiStrings.of(
                context,
              ).text('Checking dictionary definitions'),
              child: const LinearProgressIndicator(),
            ),
          if (state.discoveryResult?.unavailable.isNotEmpty ?? false) ...[
            const SizedBox(height: 12),
            Semantics(
              liveRegion: true,
              child: Text(
                UiStrings.of(context).text(
                  '{count} dictionaries could not be checked. Showing confirmed definitions.',
                  {'count': state.discoveryResult!.unavailable.length},
                ),
              ),
            ),
            TextButton.icon(
              onPressed: state.isDiscovering
                  ? null
                  : () => unawaited(state.retryDiscovery()),
              icon: const Icon(Icons.refresh),
              label: Text(
                UiStrings.of(context).text('Check dictionaries again'),
              ),
            ),
          ],
          if (state.discoveryResult?.limitReached ?? false)
            Text(
              UiStrings.of(context).text(
                'The lookup limit was reached. Browse an individual dictionary to continue.',
              ),
            ),
          if (!state.isBrowsing &&
              state.discoveryResult?.complete == true &&
              state.choices.isEmpty)
            Text(
              state.usingInstalledChoices
                  ? UiStrings.of(context).text(
                      'No exact definition could be confirmed in the installed dictionaries.',
                    )
                  : UiStrings.of(context).text(
                      'No exact definition could be confirmed for this selection.',
                    ),
            ),
          if (state.discoveryResult?.suggestions.isNotEmpty ?? false) ...[
            const SizedBox(height: 12),
            Text(UiStrings.of(context).text('Related entries')),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final suggestion in state.discoveryResult!.suggestions)
                  OutlinedButton(
                    onPressed: () {
                      _query.text = suggestion.entry.key;
                      unawaited(state.openSuggestion(suggestion));
                    },
                    child: Text(
                      '${suggestion.entry.key} · ${suggestion.module.name}',
                    ),
                  ),
              ],
            ),
          ],
          if (state.isLoading)
            Padding(
              padding: EdgeInsets.all(16),
              child: Center(
                child: CircularProgressIndicator(
                  semanticsLabel: UiStrings.of(
                    context,
                  ).text('Loading dictionary'),
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
                label: Text(UiStrings.of(context).text('Retry dictionary')),
              ),
            ),
          ],
          if (state.preferenceError != null)
            Text(
              UiStrings.of(context).text(
                'The resource choice could not be saved on this device. The dictionary remains available.',
              ),
            ),
          if (state.metadata != null &&
              !state.isLoading &&
              state.matches.isEmpty &&
              state.error == null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Text(
                state.query.isEmpty
                    ? UiStrings.of(
                        context,
                      ).text('Enter a word to search this dictionary’s index.')
                    : UiStrings.of(context).text(
                        'No published word or lexical identifier matches this lookup. Try another dictionary or enter a word.',
                      ),
              ),
            ),
          if (state.matches.isNotEmpty) ...<Widget>[
            const SizedBox(height: 12),
            Text(
              state.matches.length == 1
                  ? UiStrings.of(context).text('{count} indexed definition', {
                      'count': state.matches.length,
                    })
                  : UiStrings.of(context).text('{count} indexed definitions', {
                      'count': state.matches.length,
                    }),
            ),
            ...state.matches
                .take(_visibleMatches)
                .map(
                  (DictionaryIndexEntry match) => ListTile(
                    contentPadding: EdgeInsets.zero,
                    selected: entry?.id == match.id,
                    title: Text(match.key),
                    subtitle: Text(
                      match.occurrence > 1
                          ? UiStrings.of(context).text(
                              '{id} · definition {count}',
                              {'id': match.id, 'count': match.occurrence},
                            )
                          : match.id,
                    ),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => unawaited(state.openEntry(match.id)),
                  ),
                ),
            if (state.matches.length > _visibleMatches)
              TextButton(
                onPressed: () => setState(() => _visibleMatches += 20),
                child: Text(
                  UiStrings.of(context).text('Show more dictionary words'),
                ),
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
                  label: Text(
                    UiStrings.of(context).text('Previous dictionary word'),
                  ),
                ),
              ),
            SelectableText(
              entry.key,
              style: Theme.of(context).textTheme.titleLarge,
            ),
            Text(
              UiStrings.of(context).text(
                '{id} · {language} · definition {count}',
                {
                  'id': entry.id,
                  'language': entry.language,
                  'count': entry.occurrence,
                },
              ),
            ),
            const SizedBox(height: 12),
            // SelectableText preserves paragraph breaks and renders source HTML
            // characters literally; definitions never enter an HTML renderer.
            SelectableText(
              entry.text,
              key: ValueKey(
                'dictionary-definition-${entry.dictionary}/${entry.id}',
              ),
              textDirection:
                  {
                    'ar',
                    'he',
                    'fa',
                    'ur',
                  }.contains(entry.language.toLowerCase().split('-').first)
                  ? TextDirection.rtl
                  : TextDirection.ltr,
            ),
            if (entry.references.isNotEmpty) ...<Widget>[
              const SizedBox(height: 12),
              Text(UiStrings.of(context).text('Scripture citations')),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: entry.references
                    .map(
                      (StudyCitation citation) => ActionChip(
                        materialTapTargetSize: MaterialTapTargetSize.padded,
                        label: Text(citation.reference),
                        tooltip: citation.isScripture
                            ? UiStrings.of(context).text(
                                'Preview {reference}',
                                {'reference': citation.reference},
                              )
                            : UiStrings.of(
                                context,
                              ).text('Introduction citation unavailable'),
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
            if (entry.seeAlso.isNotEmpty)
              _links(UiStrings.of(context).text('See also'), entry.seeAlso),
            if (entry.backlinks.isNotEmpty)
              _links(
                UiStrings.of(context).text('Linked from'),
                entry.backlinks,
              ),
          ],
          if (state.metadata != null) ...<Widget>[
            const Divider(height: 24),
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              title: Text(UiStrings.of(context).text('Dictionary attribution')),
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
                  UiStrings.of(
                    context,
                  ).text('Citation provenance: {api} · {versification}', {
                    'api': state.metadata!.referenceApi,
                    'versification': state.metadata!.referenceVersification,
                  }),
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
                  materialTapTargetSize: MaterialTapTargetSize.padded,
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
