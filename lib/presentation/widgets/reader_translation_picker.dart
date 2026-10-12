import 'package:flutter/material.dart';

import '../../core/ui_strings.dart';
import '../../domain/models/bible.dart';

/// A catalogue-only translation chooser. Browsing never changes the reader or
/// acquires Scripture; the owner commits a choice through [onOpen].
///
/// The adaptive route supplies a bounded height. All controls share one scroll
/// area so the details and actions remain reachable with an on-screen keyboard
/// or enlarged text, including when a catalogue contains hundreds of Bibles.
class ReaderTranslationPicker extends StatefulWidget {
  const ReaderTranslationPicker({
    super.key,
    required this.translations,
    required this.value,
    required this.onOpen,
    required this.onClose,
  });

  final List<Translation> translations;
  final String value;
  final Future<void> Function(String) onOpen;
  final VoidCallback onClose;

  @override
  State<ReaderTranslationPicker> createState() =>
      _ReaderTranslationPickerState();
}

class _ReaderTranslationPickerState extends State<ReaderTranslationPicker> {
  final TextEditingController _search = TextEditingController();
  final ScrollController _scroll = ScrollController();
  final FocusNode _choiceFocus = FocusNode();
  late String _candidate = widget.value;
  bool _choosing = false;
  bool _opening = false;
  String? _error;

  Translation? _find(String abbreviation) {
    for (final translation in widget.translations) {
      if (translation.abbreviation == abbreviation) return translation;
    }
    return null;
  }

  @override
  void didUpdateWidget(ReaderTranslationPicker oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_find(_candidate) == null) _candidate = widget.value;
  }

  @override
  void dispose() {
    _search.dispose();
    _scroll.dispose();
    _choiceFocus.dispose();
    super.dispose();
  }

  List<Translation> get _matches {
    final terms = _search.text.trim().toLowerCase().split(RegExp(r'\s+'));
    return widget.translations
        .where((translation) {
          final searchable = <String>[
            translation.translation,
            translation.abbreviation,
            translation.lang,
            translation.language,
          ].join(' ').toLowerCase();
          return terms.every(searchable.contains);
        })
        .toList(growable: false);
  }

  void _select(Translation translation) {
    setState(() {
      _candidate = translation.abbreviation;
      _choosing = false;
      _error = null;
    });
    _choiceFocus.requestFocus();
    _scroll.jumpTo(0);
  }

  Future<void> _open() async {
    if (_opening || _find(_candidate) == null) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _opening = true;
      _error = null;
    });
    try {
      await widget.onOpen(_candidate);
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final strings = UiStrings.of(context);
    final theme = Theme.of(context);
    final candidate = _find(_candidate);
    final current = _find(widget.value);
    final matches = _choosing ? _matches : const <Translation>[];
    return CustomScrollView(
      key: const ValueKey('translation-picker-scroll'),
      controller: _scroll,
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.all(16),
          sliver: SliverToBoxAdapter(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Semantics(
                        header: true,
                        child: Text(
                          strings('translation'),
                          style: theme.textTheme.headlineSmall,
                        ),
                      ),
                    ),
                    IconButton(
                      key: const ValueKey('translation-picker-close'),
                      tooltip: strings.text('Close'),
                      constraints: const BoxConstraints(
                        minWidth: 48,
                        minHeight: 48,
                      ),
                      onPressed: widget.onClose,
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
                if (current != null) ...[
                  Text(
                    strings('downloadCurrentTranslation'),
                    style: theme.textTheme.labelLarge,
                  ),
                  Text(current.translation, textDirection: _direction(current)),
                ],
                const SizedBox(height: 16),
                OutlinedButton(
                  key: const ValueKey('translation-picker-choice'),
                  focusNode: _choiceFocus,
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(48, 56),
                    padding: const EdgeInsets.all(12),
                    alignment: AlignmentDirectional.centerStart,
                  ),
                  onPressed: _opening || widget.translations.isEmpty
                      ? null
                      : () => setState(() => _choosing = !_choosing),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Text(
                              candidate?.translation ?? strings('translation'),
                              textDirection: candidate == null
                                  ? null
                                  : _direction(candidate),
                            ),
                            if (candidate != null)
                              Text(
                                '${candidate.abbreviation.toUpperCase()} · ${candidate.resolvedLanguage}',
                                textDirection: _direction(candidate),
                                style: theme.textTheme.bodySmall,
                              ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      Icon(_choosing ? Icons.expand_less : Icons.expand_more),
                    ],
                  ),
                ),
                if (_choosing) ...[
                  const SizedBox(height: 16),
                  TextField(
                    key: const ValueKey('translation-picker-search'),
                    controller: _search,
                    decoration: InputDecoration(
                      labelText: strings('search'),
                      prefixIcon: const Icon(Icons.search),
                      suffixIcon: _search.text.isEmpty
                          ? null
                          : IconButton(
                              tooltip: strings('searchResetFilters'),
                              constraints: const BoxConstraints(
                                minWidth: 48,
                                minHeight: 48,
                              ),
                              onPressed: () => setState(_search.clear),
                              icon: const Icon(Icons.clear),
                            ),
                    ),
                    textInputAction: TextInputAction.search,
                    onChanged: (_) => setState(() {}),
                    onSubmitted: (_) {
                      if (matches.length == 1) _select(matches.single);
                    },
                  ),
                  if (matches.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      child: Text(strings.text('No matching resources.')),
                    ),
                ],
                if (!_choosing && candidate != null) ...[
                  const SizedBox(height: 16),
                  _details(context, candidate),
                  const SizedBox(height: 16),
                  if (_error != null)
                    Semantics(
                      liveRegion: true,
                      child: Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Text(
                              strings('unableToOpen'),
                              style: TextStyle(color: theme.colorScheme.error),
                            ),
                            Text(_error!),
                          ],
                        ),
                      ),
                    ),
                  FilledButton.icon(
                    key: const ValueKey('translation-picker-open'),
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(48, 48),
                      padding: const EdgeInsets.all(12),
                    ),
                    onPressed: _opening ? null : _open,
                    icon: _opening
                        ? const SizedBox.square(
                            dimension: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Icon(
                            _error == null ? Icons.menu_book : Icons.refresh,
                          ),
                    label: Text(
                      _opening
                          ? strings('openingBible')
                          : _error != null
                          ? strings('tryAgain')
                          : strings.text('Open in reader'),
                    ),
                  ),
                ],
                if (widget.translations.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    child: Text(strings('noTranslations')),
                  ),
              ],
            ),
          ),
        ),
        if (_choosing)
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            sliver: SliverList.builder(
              itemCount: matches.length,
              itemBuilder: (context, index) {
                final translation = matches[index];
                final selected = translation.abbreviation == _candidate;
                final active = translation.abbreviation == widget.value;
                return Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Semantics(
                    selected: selected,
                    child: ListTile(
                      key: ValueKey(
                        'translation-picker-option-${translation.abbreviation}',
                      ),
                      selected: selected,
                      selectedTileColor: theme.colorScheme.secondaryContainer,
                      minTileHeight: 56,
                      contentPadding: const EdgeInsets.all(12),
                      title: Text(
                        translation.translation,
                        textDirection: _direction(translation),
                      ),
                      subtitle: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(
                            '${translation.abbreviation.toUpperCase()} · ${translation.resolvedLanguage}',
                            textDirection: _direction(translation),
                          ),
                          if (active)
                            Text(strings('downloadCurrentTranslation')),
                        ],
                      ),
                      trailing: selected ? const Icon(Icons.check) : null,
                      onTap: () => _select(translation),
                    ),
                  ),
                );
              },
            ),
          ),
      ],
    );
  }

  Widget _details(BuildContext context, Translation translation) {
    final strings = UiStrings.of(context);
    final theme = Theme.of(context);
    final fields = <(String, String)>[
      (strings('translation'), translation.translation),
      (strings('language'), translation.resolvedLanguage),
      (strings.text('Abbreviation'), translation.abbreviation.toUpperCase()),
      (strings('description'), translation.description),
      (strings('license'), translation.distributionLicense),
      (strings('aboutAndContact'), translation.distributionAbout),
      (strings('source'), translation.distributionSource),
    ];
    return Card(
      key: const ValueKey('translation-picker-details'),
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Semantics(
              header: true,
              child: Text(
                strings('translationDetails'),
                style: theme.textTheme.titleMedium,
              ),
            ),
            for (final (label, value) in fields)
              if (value.trim().isNotEmpty) ...[
                const SizedBox(height: 12),
                Text(label, style: theme.textTheme.labelLarge),
                Text(value, textDirection: _direction(translation)),
              ],
          ],
        ),
      ),
    );
  }

  TextDirection _direction(Translation translation) =>
      translation.isRtl ? TextDirection.rtl : TextDirection.ltr;
}
