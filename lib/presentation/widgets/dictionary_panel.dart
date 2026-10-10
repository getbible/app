import 'dart:async';

import 'package:flutter/material.dart';

import '../../application/dictionary_controller.dart';
import '../../core/ui_strings.dart';
import '../../domain/models/dictionary.dart';
import '../../domain/models/reference.dart';
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
  String? _lastControllerQuery;

  void _synchronizeQuery() {
    final query = widget.controller.query;
    if (_lastControllerQuery == query) return;
    _lastControllerQuery = query;
    // Typing already owns selection/composition. Only navigation-driven changes
    // should replace the field value (important for native IME input).
    if (_query.text == query) return;
    _query.value = TextEditingValue(
      text: query,
      selection: TextSelection.collapsed(offset: query.length),
    );
  }

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_synchronizeQuery);
    _openContext();
  }

  @override
  void didUpdateWidget(DictionaryPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller)) {
      oldWidget.controller.removeListener(_synchronizeQuery);
      oldWidget.controller.close();
      widget.controller.addListener(_synchronizeQuery);
    }
    if (!identical(oldWidget.context, widget.context) ||
        !identical(oldWidget.controller, widget.controller)) {
      _openContext();
    }
  }

  void _openContext() {
    _query.text = widget.context.selectedText ?? '';
    _lastControllerQuery = _query.text;
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
    widget.controller.removeListener(_synchronizeQuery);
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
      return LayoutBuilder(
        builder: (context, constraints) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: ListView(
                key: const ValueKey('dictionary-definition-scroll'),
                padding: const EdgeInsets.all(24),
                children: <Widget>[
                  if (state.choices.isNotEmpty)
                    DropdownButtonFormField<String>(
                      key: const ValueKey('dictionary-resource-choice'),
                      initialValue: state.selectedModule?.id,
                      isExpanded: true,
                      // A dense button reserves one line even when a resource
                      // name wraps. Keep menu padding out of the selected value
                      // and let the field grow with its text and accessibility
                      // scale instead of clipping the dictionary name.
                      isDense: false,
                      itemHeight: null,
                      selectedItemBuilder: (context) => [
                        for (final module in state.choices)
                          Align(
                            alignment: AlignmentDirectional.centerStart,
                            child: Text('${module.name} (${module.language})'),
                          ),
                      ],
                      decoration: InputDecoration(
                        labelText: state.isBrowsing
                            ? UiStrings.of(context).text('Dictionary')
                            : UiStrings.of(context).text(
                                'Dictionaries with definitions ({count})',
                                {'count': state.choices.length},
                              ),
                        border: const OutlineInputBorder(),
                      ),
                      hint: Text(
                        UiStrings.of(context).text('Choose a resource'),
                      ),
                      items: [
                        for (final module in state.choices)
                          DropdownMenuItem<String>(
                            value: module.id,
                            child: Padding(
                              padding: const EdgeInsets.symmetric(vertical: 8),
                              child: Text(
                                '${module.name} (${module.language})',
                              ),
                            ),
                          ),
                      ],
                      onChanged: (id) {
                        if (id != null) unawaited(state.selectModule(id));
                      },
                    ),
                  const SizedBox(height: 16),
                  _lookupForm(context, state),
                  if (lookup != null && lookup.strongs.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      children: [
                        for (final strong in lookup.strongs)
                          ActionChip(
                            label: Text(strong),
                            materialTapTargetSize: MaterialTapTargetSize.padded,
                            onPressed: state.modules.isEmpty
                                ? null
                                : () => unawaited(state.searchWords(strong)),
                          ),
                      ],
                    ),
                  ],
                  if (lookup != null && lookup.lemmas.isNotEmpty)
                    _detail(UiStrings.of(context).text('Lemma'), lookup.lemmas),
                  if (lookup != null && lookup.morphology.isNotEmpty)
                    _detail(
                      UiStrings.of(context).text('Morphology'),
                      lookup.morphology,
                    ),
                  if (lookup != null && lookup.transliterations.isNotEmpty)
                    _detail(
                      UiStrings.of(context).text('Transliteration'),
                      lookup.transliterations,
                    ),
                  if (state.canBrowse && !state.isBrowsing)
                    Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: TextButton(
                        onPressed: () => unawaited(state.searchWords('')),
                        child: Text(
                          UiStrings.of(context).text('Browse all dictionaries'),
                        ),
                      ),
                    ),
                  if (state.usingInstalledChoices) ...[
                    Text(
                      UiStrings.of(
                        context,
                      ).text('Searching installed dictionaries.'),
                    ),
                    if (state.onlineChoicesAvailable)
                      TextButton.icon(
                        onPressed: () =>
                            unawaited(state.includeOnlineDictionaries()),
                        icon: const Icon(Icons.public),
                        label: Text(
                          UiStrings.of(
                            context,
                          ).text('Include online dictionaries'),
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
                  if (state.discoveryResult?.unavailable.isNotEmpty ??
                      false) ...[
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
                        'The lookup limit was reached. Try a more specific word.',
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
                  if (state.discoveryResult?.suggestions.isNotEmpty ??
                      false) ...[
                    const SizedBox(height: 12),
                    Text(UiStrings.of(context).text('Related entries')),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final suggestion
                            in state.discoveryResult!.suggestions)
                          OutlinedButton(
                            onPressed: () {
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
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                    Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: TextButton.icon(
                        onPressed: () => unawaited(state.retry()),
                        icon: const Icon(Icons.refresh),
                        label: Text(
                          UiStrings.of(context).text('Retry dictionary'),
                        ),
                      ),
                    ),
                  ],
                  if (state.preferenceError != null)
                    Text(
                      UiStrings.of(context).text(
                        'The resource choice could not be saved on this device. The dictionary remains available.',
                      ),
                    ),
                  if (state.isBrowsing && state.matches.isNotEmpty) ...<Widget>[
                    const SizedBox(height: 12),
                    Text(
                      state.matches.length == 1
                          ? UiStrings.of(context).text(
                              '{count} indexed definition',
                              {'count': state.matches.length},
                            )
                          : UiStrings.of(context).text(
                              '{count} indexed definitions',
                              {'count': state.matches.length},
                            ),
                    ),
                    ...state.matches
                        .take(_visibleMatches)
                        .map(
                          (DictionaryIndexEntry match) => ListTile(
                            contentPadding: EdgeInsets.zero,
                            selected: state.entry?.id == match.id,
                            title: Text(match.key),
                            subtitle: Text(
                              match.occurrence > 1
                                  ? UiStrings.of(context).text(
                                      '{id} · definition {count}',
                                      {
                                        'id': match.id,
                                        'count': match.occurrence,
                                      },
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
                          UiStrings.of(
                            context,
                          ).text('Show more dictionary words'),
                        ),
                      ),
                  ],

                  if (state.modules.isEmpty &&
                      !state.isLoading &&
                      state.error == null)
                    Text(
                      UiStrings.of(context).text(
                        'No dictionary resources are currently published.',
                      ),
                    ),
                  if (state.isBrowsing &&
                      state.matches.isEmpty &&
                      !state.isLoading)
                    Text(
                      UiStrings.of(
                        context,
                      ).text('Enter a word to search this dictionary’s index.'),
                    ),
                  if (state.canGoBack)
                    Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: TextButton.icon(
                        onPressed: state.goBack,
                        icon: const Icon(Icons.arrow_back),
                        label: Text(
                          UiStrings.of(
                            context,
                          ).text('Previous dictionary word'),
                        ),
                      ),
                    ),
                  for (final definition in state.definitions)
                    _definition(context, definition),
                ],
              ),
            ),
            if (state.metadata != null)
              ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: constraints.maxHeight * .25,
                ),
                child: SingleChildScrollView(
                  child: Padding(
                    padding: const EdgeInsetsDirectional.fromSTEB(24, 0, 24, 0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const Divider(height: 1),
                        ExpansionTile(
                          tilePadding: EdgeInsets.zero,
                          title: Semantics(
                            label: UiStrings.of(
                              context,
                            ).text('Dictionary attribution'),
                            child: Text(
                              '${state.metadata!.license.trim().isEmpty ? UiStrings.of(context).text('Dictionary attribution') : state.metadata!.license} · ${state.metadata!.language}',
                            ),
                          ),
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
                              UiStrings.of(context).text(
                                'Citation provenance: {api} · {versification}',
                                {
                                  'api': state.metadata!.referenceApi,
                                  'versification':
                                      state.metadata!.referenceVersification,
                                },
                              ),
                            ),
                          ],
                        ),

                        StudyOfflineStatus(
                          installed: state.isInstalled,
                          onSetUpOffline: widget.onSetUpOffline,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      );
    },
  );

  Widget _lookupForm(BuildContext context, DictionaryController state) =>
      LayoutBuilder(
        builder: (context, constraints) {
          final field = TextField(
            key: const ValueKey('dictionary-lookup-query'),
            controller: _query,
            enabled: state.modules.isNotEmpty,
            textInputAction: TextInputAction.search,
            maxLength: 500,
            decoration: InputDecoration(
              labelText: UiStrings.of(context).text('Find a dictionary word'),
              border: const OutlineInputBorder(),
              counterText: '',
            ),
            onSubmitted: (query) => unawaited(state.searchWords(query)),
            onChanged: state.isBrowsing
                ? (query) {
                    setState(() => _visibleMatches = 20);
                    unawaited(state.searchIndex(query));
                  }
                : null,
          );
          final button = OutlinedButton(
            onPressed: state.modules.isEmpty
                ? null
                : () => unawaited(state.searchWords(_query.text)),
            child: Text(UiStrings.of(context).text('Look up')),
          );
          return constraints.maxWidth < 420 ||
                  MediaQuery.textScalerOf(context).scale(14) > 21
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [field, const SizedBox(height: 8), button],
                )
              : Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: field),
                    const SizedBox(width: 8),
                    button,
                  ],
                );
        },
      );

  Widget _definition(BuildContext context, DictionaryEntry entry) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 18),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SelectableText(
          entry.key,
          style: Theme.of(context).textTheme.titleLarge,
        ),
        Text(
          UiStrings.of(context).text('{id} · {language} · definition {count}', {
            'id': entry.id,
            'language': entry.language,
            'count': entry.occurrence,
          }),
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
                        ? UiStrings.of(context).text('Preview {reference}', {
                            'reference': citation.reference,
                          })
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
          _links(UiStrings.of(context).text('Linked from'), entry.backlinks),
      ],
    ),
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
                      unawaited(widget.controller.followLink(link.id)),
                ),
              )
              .toList(growable: false),
        ),
      ],
    ),
  );
}
