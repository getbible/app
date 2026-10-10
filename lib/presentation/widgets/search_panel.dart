import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../application/online_search_controller.dart';
import '../../core/ui_strings.dart';
import '../../domain/models/bible.dart';
import '../../domain/models/online_search.dart';
import '../../domain/models/search.dart';
import '../../domain/models/service_envelopes.dart';
import '../../services/search_match_emphasis.dart';
import 'scripture_verse_text.dart';

/// Native search content defaults to a complete installed Bible when available.
/// An explicit online/installed source choice remains under the reader's control.
/// The injected controller owns requests; widgets only edit typed criteria.
class SearchPanel extends StatefulWidget {
  const SearchPanel({
    super.key,
    required this.controller,
    required this.translation,
    required this.books,
    required this.onOpen,
    this.direction = 'LTR',
    this.initialQuery = '',
    this.initialPhrase = false,
    this.showSourceStyles = true,
  });

  final OnlineSearchController controller;
  final String translation;
  final List<BibleBook> books;
  final Future<void> Function(OnlineSearchHit) onOpen;
  final String direction;
  final String initialQuery;
  final bool initialPhrase;
  final bool showSourceStyles;

  @override
  State<SearchPanel> createState() => _SearchPanelState();
}

class _SearchPanelState extends State<SearchPanel> {
  final TextEditingController _query = TextEditingController();
  final TextEditingController _exclusions = TextEditingController();
  final TextEditingController _proximity = TextEditingController();
  final ScrollController _scroll = ScrollController();
  SearchExecutionMode _mode = SearchExecutionMode.online;
  bool _sourceChosen = false;
  SearchWordMode _words = SearchWordMode.all;
  SearchMatchMode _match = SearchMatchMode.exact;
  OnlineSearchScope _scope = OnlineSearchScope.bible;
  SearchDiacritics _diacritics = SearchDiacritics.fold;
  SearchSort _sort = SearchSort.canonical;
  List<int> _books = <int>[];
  bool _caseSensitive = false;
  bool _hasSearched = false;
  String? _validationError;
  String? _openError;
  bool _opening = false;
  Timer? _retryTimer;
  Timer? _searchTimer;
  int _inputGeneration = 0;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_loadNearEnd);
    widget.controller.addListener(_scheduleRetryAvailability);
    _useDefaultSource();
    final OnlineSearchRequest? previous = widget.controller.request;
    if (previous != null &&
        previous.translation == widget.translation &&
        widget.initialQuery.isEmpty) {
      _mode = widget.controller.mode;
      // A restored result set keeps its source and filter semantics.
      _sourceChosen = true;
      _query.text = previous.text;
      final OnlineSearchCriteria criteria = previous.criteria;
      _words = criteria.words;
      _match = criteria.match;
      _scope = criteria.scope;
      _diacritics = criteria.diacritics;
      _sort = criteria.sort;
      _books = criteria.books.toList();
      _caseSensitive = criteria.caseSensitive;
      _exclusions.text = criteria.exclusions.join(', ');
      _proximity.text = criteria.proximity?.toString() ?? '';
      _hasSearched = true;
    } else {
      if (previous != null) widget.controller.clear(notify: false);
      _applyInitialQuery();
    }
    _scheduleRetryAvailability();
  }

  @override
  void didUpdateWidget(SearchPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_scheduleRetryAvailability);
      oldWidget.controller.cancel(notify: false);
      widget.controller.addListener(_scheduleRetryAvailability);
    }
    if (oldWidget.controller != widget.controller ||
        oldWidget.translation != widget.translation ||
        oldWidget.initialQuery != widget.initialQuery ||
        oldWidget.initialPhrase != widget.initialPhrase) {
      _retryTimer?.cancel();
      _searchTimer?.cancel();
      _inputGeneration++;
      widget.controller.clear(notify: false);
      _hasSearched = false;
      if (oldWidget.translation != widget.translation) _sourceChosen = false;
      _useDefaultSource();
      _opening = false;
      _openError = null;
      _applyInitialQuery();
    }
    if (!_hasSearched) _useDefaultSource();
  }

  void _useDefaultSource() {
    if (_sourceChosen) return;
    final mode = widget.controller.defaultModeFor(widget.translation);
    if (_mode == mode) return;
    _mode = mode;
    _diacritics = mode == SearchExecutionMode.installed
        ? SearchDiacritics.exact
        : SearchDiacritics.fold;
    if (mode == SearchExecutionMode.installed) _useInstalledCriteria();
  }

  void _useInstalledCriteria() {
    _diacritics = SearchDiacritics.exact;
    _sort = SearchSort.canonical;
    if (_scope == OnlineSearchScope.deuterocanon) {
      _scope = OnlineSearchScope.bible;
    }
    _proximity.clear();
  }

  void _applyInitialQuery() {
    final generation = ++_inputGeneration;
    _query.text = widget.initialQuery;
    if (widget.initialPhrase) _words = SearchWordMode.phrase;
    if (widget.initialQuery.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && generation == _inputGeneration) _search();
      });
    }
  }

  void _scheduleRetryAvailability() {
    _retryTimer?.cancel();
    final Duration? remaining = widget.controller.retryDelay;
    if (remaining == null || remaining <= Duration.zero) return;
    _retryTimer = Timer(remaining, () {
      if (mounted) setState(() {});
    });
  }

  void _loadNearEnd() {
    if (_scroll.hasClients && _scroll.position.extentAfter < 240) {
      unawaited(widget.controller.loadMore());
    }
  }

  void _inputChanged() {
    _searchTimer?.cancel();
    _inputGeneration++;
    widget.controller.clear();
    setState(() {
      _hasSearched = false;
      _validationError = null;
      _openError = null;
      _opening = false;
    });
    if (_query.text.trim().isNotEmpty) {
      final generation = _inputGeneration;
      _searchTimer = Timer(const Duration(milliseconds: 250), () {
        if (mounted && generation == _inputGeneration) _search();
      });
    }
  }

  void _search() {
    _searchTimer?.cancel();
    _inputGeneration++;
    if (_query.text.trim().isEmpty) {
      widget.controller.clear();
      setState(() => _hasSearched = false);
      return;
    }
    OnlineSearchCriteria criteria;
    try {
      criteria = OnlineSearchCriteria(
        words: _words,
        match: _match,
        caseSensitive: _caseSensitive,
        scope: _scope,
        books: _books,
        diacritics: _diacritics,
        exclusions: _exclusions.text.trim().isEmpty
            ? const <String>[]
            : _exclusions.text
                  .split(',')
                  .map((String value) => value.trim())
                  .toList(),
        proximity: _proximity.text.isEmpty
            ? null
            : int.tryParse(_proximity.text),
        sort: _sort,
      );
      if (_proximity.text.isNotEmpty && criteria.proximity == null) {
        throw const FormatException(
          'Proximity must be an integer from 0 to 100.',
        );
      }
    } on FormatException catch (error) {
      setState(
        () => _validationError = UiStrings.of(context).text(error.message),
      );
      return;
    }
    setState(() {
      _hasSearched = true;
      _opening = false;
      _openError = null;
      _validationError = null;
    });
    unawaited(
      widget.controller.search(
        widget.translation,
        _query.text,
        criteria: criteria,
        direction: widget.direction,
        mode: _mode,
      ),
    );
  }

  Future<void> _open(OnlineSearchHit hit) async {
    if (_opening) return;
    final generation = _inputGeneration;
    setState(() {
      _opening = true;
      _openError = null;
    });
    try {
      await widget.onOpen(hit);
    } catch (error) {
      if (mounted && generation == _inputGeneration) {
        setState(() => _openError = error.toString());
      }
    } finally {
      if (mounted && generation == _inputGeneration) {
        setState(() => _opening = false);
      }
    }
  }

  @override
  void dispose() {
    _searchTimer?.cancel();
    _inputGeneration++;
    _retryTimer?.cancel();
    widget.controller.removeListener(_scheduleRetryAvailability);
    widget.controller.cancel(notify: false);
    _query.dispose();
    _exclusions.dispose();
    _proximity.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.controller,
    builder: (BuildContext context, Widget? child) {
      final OnlineSearchController controller = widget.controller;
      final List<OnlineSearchHit> hits = controller.results;
      return CustomScrollView(
        controller: _scroll,
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        slivers: <Widget>[
          SliverPadding(
            padding: const EdgeInsets.all(16),
            sliver: SliverToBoxAdapter(child: _controls(context)),
          ),
          if (controller.isLoading)
            SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Center(
                  child: CircularProgressIndicator(
                    semanticsLabel: UiStrings.of(
                      context,
                    ).text('Searching Scripture'),
                  ),
                ),
              ),
            )
          else if (controller.kind != null)
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              sliver: SliverToBoxAdapter(
                child: Semantics(
                  liveRegion: true,
                  child: Text(
                    controller.kind == SearchResultKind.reference
                        ? UiStrings.of(context).text(
                            '{count} verses in the resolved reference. Full-text filters do not apply.',
                            {'count': hits.length},
                          )
                        : UiStrings.of(context).text(
                            '{loaded} of {total} results loaded.',
                            {'loaded': hits.length, 'total': controller.total},
                          ),
                  ),
                ),
              ),
            )
          else if (!_hasSearched)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  _mode == SearchExecutionMode.online
                      ? UiStrings.of(context).text(
                          'Enter words or a Scripture reference. Search uses the selected Bible online.',
                        )
                      : UiStrings.of(context).text(
                          'Search only the selected installed Bible. No query is sent online.',
                        ),
                ),
              ),
            ),
          if (_hasSearched &&
              !controller.isLoading &&
              controller.error == null &&
              controller.kind != null &&
              hits.isEmpty)
            SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  UiStrings.of(
                    context,
                  ).text('0 results. Try different words or broader filters.'),
                ),
              ),
            ),
          SliverList.builder(
            itemCount: hits.length,
            itemBuilder: (BuildContext context, int index) {
              final OnlineSearchHit hit = hits[index];
              return Card(
                key: ValueKey<String>('search-hit-${hit.identity}'),
                margin: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      Align(
                        alignment: AlignmentDirectional.centerStart,
                        child: TextButton.icon(
                          onPressed: _opening
                              ? null
                              : () => unawaited(_open(hit)),
                          icon: const Icon(Icons.open_in_new),
                          label: Text(
                            UiStrings.of(context).text('Open {reference}', {
                              'reference': hit.reference,
                            }),
                          ),
                        ),
                      ),
                      ScriptureVerseText(
                        verse: hit.verse,
                        style: Theme.of(context).textTheme.bodyLarge!,
                        textDirection: hit.direction == 'RTL'
                            ? TextDirection.rtl
                            : TextDirection.ltr,
                        showSourceStyles: widget.showSourceStyles,
                        emphasis: searchMatchEmphasis(
                          hit.verse,
                          hit.terms,
                          caseSensitive:
                              controller.request?.criteria.caseSensitive ??
                              false,
                          match:
                              controller.request?.criteria.match ??
                              SearchMatchMode.partial,
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
          if (controller.error != null)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    Semantics(
                      liveRegion: true,
                      child: Text(controller.error.toString()),
                    ),
                    if (controller.retryAt != null)
                      Padding(
                        padding: EdgeInsets.only(top: 8),
                        child: Text(
                          UiStrings.of(context).text(
                            'The service requested a pause before retrying.',
                          ),
                        ),
                      ),
                    const SizedBox(height: 8),
                    Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: OutlinedButton.icon(
                        onPressed: controller.canRetry
                            ? () => unawaited(controller.retry())
                            : null,
                        icon: const Icon(Icons.refresh),
                        label: Text(
                          controller.requiresRestart
                              ? UiStrings.of(context).text('Restart search')
                              : UiStrings.of(context).text('Retry'),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          if (_openError != null)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Semantics(liveRegion: true, child: Text(_openError!)),
              ),
            ),
          if (controller.offsetLimitReached)
            SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.all(16),
                child: Text(
                  UiStrings.of(context).text(
                    'More matches exist beyond the page offset limit. Narrow the search using books, scope or additional words.',
                  ),
                ),
              ),
            )
          else if (controller.canLoadMore && controller.error == null)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Center(
                  child: controller.isLoadingMore
                      ? CircularProgressIndicator(
                          semanticsLabel: UiStrings.of(
                            context,
                          ).text('Loading more matches'),
                        )
                      : OutlinedButton(
                          onPressed: () => unawaited(controller.loadMore()),
                          child: Text(
                            UiStrings.of(context).text('Load more results'),
                          ),
                        ),
                ),
              ),
            ),
          const SliverToBoxAdapter(child: SizedBox(height: 24)),
        ],
      );
    },
  );

  Widget _controls(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: <Widget>[
      if (widget.controller.supportsInstalledSearch) ...[
        _dropdown<SearchExecutionMode>(
          UiStrings.of(context).text('Search source'),
          _mode,
          {
            SearchExecutionMode.online: UiStrings.of(
              context,
            ).text('Online search'),
            SearchExecutionMode.installed: UiStrings.of(
              context,
            ).text('Installed Bible (offline)'),
          },
          (value) {
            _sourceChosen = true;
            _mode = value;
            if (value == SearchExecutionMode.installed) {
              _useInstalledCriteria();
            }
            _inputChanged();
          },
        ),
        if (_mode == SearchExecutionMode.installed)
          Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: Text(
              UiStrings.of(context).text(
                'Offline search uses exact diacritics and Bible order. Folding, relevance, proximity and Deuterocanon scope require Online search. Choose individual books to include other offline scopes. Install the selected Bible in Offline resources first.',
              ),
            ),
          ),
      ],
      TextField(
        key: const ValueKey<String>('online-search-query'),
        controller: _query,
        textInputAction: TextInputAction.search,
        maxLength: 500,
        decoration: InputDecoration(
          labelText: UiStrings.of(
            context,
          ).text('Search {bible}', {'bible': widget.translation.toUpperCase()}),
          hintText: UiStrings.of(
            context,
          ).text('Words, a phrase or a Scripture reference'),
          errorText: _validationError,
          suffixIcon: IconButton(
            tooltip: UiStrings.of(context).text('Search'),
            onPressed: _search,
            icon: const Icon(Icons.search),
          ),
        ),
        onChanged: (_) => _inputChanged(),
        onSubmitted: (_) => _search(),
      ),
      const SizedBox(height: 8),
      Wrap(
        spacing: 12,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: <Widget>[
          _dropdown<SearchWordMode>(
            UiStrings.of(context).text('Word mode'),
            _words,
            <SearchWordMode, String>{
              SearchWordMode.all: UiStrings.of(context).text('All words'),
              SearchWordMode.any: UiStrings.of(context).text('Any word'),
              SearchWordMode.phrase: UiStrings.of(context).text('Exact phrase'),
            },
            (SearchWordMode value) {
              _words = value;
              if (value != SearchWordMode.all) _proximity.clear();
              _inputChanged();
            },
          ),
          _dropdown<SearchMatchMode>(
            UiStrings.of(context).text('Match mode'),
            _match,
            <SearchMatchMode, String>{
              SearchMatchMode.exact: UiStrings.of(context).text('Exact word'),
              SearchMatchMode.partial: UiStrings.of(
                context,
              ).text('Partial word'),
            },
            (SearchMatchMode value) {
              _match = value;
              _inputChanged();
            },
          ),
          _dropdown<OnlineSearchScope>(
            UiStrings.of(context).text('Search scope'),
            _scope,
            <OnlineSearchScope, String>{
              OnlineSearchScope.bible: UiStrings.of(
                context,
              ).text('Whole Bible'),
              OnlineSearchScope.oldTestament: UiStrings.of(
                context,
              ).text('Old Testament'),
              OnlineSearchScope.newTestament: UiStrings.of(
                context,
              ).text('New Testament'),
              OnlineSearchScope.deuterocanon: UiStrings.of(
                context,
              ).text('Deuterocanon'),
            },
            (OnlineSearchScope value) {
              _scope = value;
              _inputChanged();
            },
          ),
          FilterChip(
            label: Text(UiStrings.of(context).text('Case sensitive')),
            selected: _caseSensitive,
            onSelected: (bool value) {
              _caseSensitive = value;
              _inputChanged();
            },
          ),
        ],
      ),
      const SizedBox(height: 8),
      ExpansionTile(
        title: Text(UiStrings.of(context).text('Advanced filters')),
        tilePadding: EdgeInsets.zero,
        childrenPadding: const EdgeInsets.only(bottom: 12),
        expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Wrap(
            spacing: 12,
            runSpacing: 8,
            children: <Widget>[
              _dropdown<SearchDiacritics>(
                UiStrings.of(context).text('Diacritics'),
                _diacritics,
                <SearchDiacritics, String>{
                  SearchDiacritics.fold: UiStrings.of(
                    context,
                  ).text('Fold diacritics'),
                  SearchDiacritics.exact: UiStrings.of(
                    context,
                  ).text('Exact diacritics'),
                },
                (SearchDiacritics value) {
                  _diacritics = value;
                  _inputChanged();
                },
              ),
              _dropdown<SearchSort>(
                UiStrings.of(context).text('Result order'),
                _sort,
                <SearchSort, String>{
                  SearchSort.canonical: UiStrings.of(
                    context,
                  ).text('Bible order'),
                  SearchSort.relevance: UiStrings.of(
                    context,
                  ).text('Relevance order'),
                },
                (SearchSort value) {
                  _sort = value;
                  _inputChanged();
                },
              ),
              OutlinedButton.icon(
                onPressed: widget.books.isEmpty ? null : _chooseBooks,
                icon: const Icon(Icons.library_books),
                label: Text(
                  _books.isEmpty
                      ? UiStrings.of(context).text('All discovered books')
                      : UiStrings.of(context).text('{count} selected books', {
                          'count': _books.length,
                        }),
                ),
              ),
            ],
          ),
          if (_books.isNotEmpty)
            Wrap(
              spacing: 8,
              children: <Widget>[
                for (final int number in _books)
                  InputChip(
                    label: Text(
                      widget.books
                              .where((BibleBook book) => book.number == number)
                              .firstOrNull
                              ?.name ??
                          UiStrings.of(
                            context,
                          ).text('Book {number}', {'number': number}),
                    ),
                    onDeleted: () {
                      _books.remove(number);
                      _inputChanged();
                    },
                  ),
              ],
            ),
          const SizedBox(height: 12),
          TextField(
            controller: _exclusions,
            maxLength: 3231,
            decoration: InputDecoration(
              labelText: UiStrings.of(context).text('Exclude words'),
              helperText: UiStrings.of(
                context,
              ).text('Comma-separated; at most 32 terms, 100 characters each.'),
            ),
            onChanged: (_) => _inputChanged(),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _proximity,
            enabled: _words == SearchWordMode.all,
            keyboardType: TextInputType.number,
            inputFormatters: <TextInputFormatter>[
              FilteringTextInputFormatter.digitsOnly,
            ],
            decoration: InputDecoration(
              labelText: UiStrings.of(context).text('Proximity (optional)'),
              helperText: UiStrings.of(
                context,
              ).text('0–100 intervening units; available with All words.'),
            ),
            onChanged: (_) => _inputChanged(),
          ),
        ],
      ),
    ],
  );

  Widget _dropdown<T>(
    String label,
    T value,
    Map<T, String> choices,
    ValueChanged<T> onChanged,
  ) => Semantics(
    label: label,
    child: SizedBox(
      width: 260,
      child: DropdownButton<T>(
        isExpanded: true,
        itemHeight: null,
        value: value,
        selectedItemBuilder: (BuildContext context) => choices.values
            .map(
              (String text) => Align(
                alignment: AlignmentDirectional.centerStart,
                child: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis),
              ),
            )
            .toList(),
        items: choices.entries
            .map(
              (MapEntry<T, String> entry) => DropdownMenuItem<T>(
                value: entry.key,
                child: Text(entry.value),
              ),
            )
            .toList(),
        onChanged: (T? selected) {
          if (selected != null) onChanged(selected);
        },
      ),
    ),
  );

  Future<void> _chooseBooks() async {
    final List<int>? chosen = await showDialog<List<int>>(
      context: context,
      builder: (BuildContext context) =>
          _SearchBooksDialog(books: widget.books, selected: _books),
    );
    if (chosen == null || !mounted) return;
    _books = chosen;
    _inputChanged();
  }
}

class _SearchBooksDialog extends StatefulWidget {
  const _SearchBooksDialog({required this.books, required this.selected});
  final List<BibleBook> books;
  final List<int> selected;
  @override
  State<_SearchBooksDialog> createState() => _SearchBooksDialogState();
}

class _SearchBooksDialogState extends State<_SearchBooksDialog> {
  late final Set<int> _selected = widget.selected.toSet();
  String _filter = '';
  @override
  Widget build(BuildContext context) {
    final List<BibleBook> books = widget.books
        .where(
          (BibleBook book) =>
              book.name.toLowerCase().contains(_filter.toLowerCase()),
        )
        .toList();
    return AlertDialog(
      scrollable: true,
      title: Text(UiStrings.of(context).text('Search selected books')),
      content: SizedBox(
        width: 440,
        height: MediaQuery.sizeOf(context).height * 0.5,
        child: Column(
          children: <Widget>[
            TextField(
              decoration: InputDecoration(
                labelText: UiStrings.of(context).text('Find a book'),
              ),
              onChanged: (String value) => setState(() => _filter = value),
            ),
            Expanded(
              child: ListView.builder(
                itemCount: books.length,
                itemBuilder: (BuildContext context, int index) {
                  final BibleBook book = books[index];
                  final bool selected = _selected.contains(book.number);
                  return CheckboxListTile(
                    title: Text(book.name),
                    value: selected,
                    onChanged: !selected && _selected.length >= 83
                        ? null
                        : (bool? checked) => setState(() {
                            if (checked ?? false) {
                              _selected.add(book.number);
                            } else {
                              _selected.remove(book.number);
                            }
                          }),
                  );
                },
              ),
            ),
            Text(
              UiStrings.of(context).text('{count} of 83 available selections', {
                'count': _selected.length,
              }),
            ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => setState(_selected.clear),
          child: Text(UiStrings.of(context).text('All books')),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(UiStrings.of(context).text('Cancel')),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_selected.toList()),
          child: Text(UiStrings.of(context).text('Apply')),
        ),
      ],
    );
  }
}
