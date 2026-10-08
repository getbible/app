import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../application/online_search_controller.dart';
import '../../domain/models/bible.dart';
import '../../domain/models/online_search.dart';
import '../../domain/models/search.dart';
import '../../domain/models/service_envelopes.dart';
import '../../services/search_match_emphasis.dart';
import 'scripture_verse_text.dart';

/// Native online search content, reusable in a full-screen route or Study pane.
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

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_loadNearEnd);
    widget.controller.addListener(_scheduleRetryAvailability);
    final OnlineSearchRequest? previous = widget.controller.request;
    if (previous != null &&
        previous.translation == widget.translation &&
        widget.initialQuery.isEmpty) {
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
      if (previous != null) widget.controller.clear();
      _applyInitialQuery();
    }
  }

  @override
  void didUpdateWidget(SearchPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_scheduleRetryAvailability);
      oldWidget.controller.cancel();
      widget.controller.addListener(_scheduleRetryAvailability);
    }
    if (oldWidget.controller != widget.controller ||
        oldWidget.translation != widget.translation ||
        oldWidget.initialQuery != widget.initialQuery ||
        oldWidget.initialPhrase != widget.initialPhrase) {
      widget.controller.clear();
      _hasSearched = false;
      _applyInitialQuery();
    }
  }

  void _applyInitialQuery() {
    _query.text = widget.initialQuery;
    if (widget.initialPhrase) _words = SearchWordMode.phrase;
    if (widget.initialQuery.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _search();
      });
    }
  }

  void _scheduleRetryAvailability() {
    _retryTimer?.cancel();
    final DateTime? retryAt = widget.controller.retryAt;
    if (retryAt == null) return;
    final Duration remaining = retryAt.difference(DateTime.now());
    if (remaining.isNegative) return;
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
    widget.controller.clear();
    setState(() {
      _hasSearched = false;
      _validationError = null;
    });
  }

  void _search() {
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
      setState(() => _validationError = error.message);
      return;
    }
    setState(() {
      _hasSearched = true;
      _validationError = null;
    });
    unawaited(
      widget.controller.search(
        widget.translation,
        _query.text,
        criteria: criteria,
        direction: widget.direction,
      ),
    );
  }

  Future<void> _open(OnlineSearchHit hit) async {
    if (_opening) return;
    setState(() {
      _opening = true;
      _openError = null;
    });
    try {
      await widget.onOpen(hit);
    } catch (error) {
      if (mounted) setState(() => _openError = error.toString());
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  @override
  void dispose() {
    _retryTimer?.cancel();
    widget.controller.removeListener(_scheduleRetryAvailability);
    widget.controller.cancel();
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
            const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Center(
                  child: CircularProgressIndicator(
                    semanticsLabel: 'Searching Scripture',
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
                        ? '${hits.length} verses in the resolved reference. Full-text filters do not apply.'
                        : '${hits.length} of ${controller.total} results loaded.',
                  ),
                ),
              ),
            )
          else if (!_hasSearched)
            const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'Enter words or a Scripture reference. Search uses the selected Bible online.',
                ),
              ),
            ),
          if (_hasSearched &&
              !controller.isLoading &&
              controller.error == null &&
              controller.kind != null &&
              hits.isEmpty)
            const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  '0 results. Try different words or broader filters.',
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
                          label: Text('Open ${hit.reference}'),
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
                      const Padding(
                        padding: EdgeInsets.only(top: 8),
                        child: Text(
                          'The service requested a pause before retrying.',
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
                              ? 'Restart search'
                              : 'Retry',
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
            const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.all(16),
                child: Text(
                  'More matches exist beyond the online offset limit. Narrow the search using books, scope or additional words.',
                ),
              ),
            )
          else if (controller.canLoadMore && controller.error == null)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Center(
                  child: controller.isLoadingMore
                      ? const CircularProgressIndicator(
                          semanticsLabel: 'Loading more matches',
                        )
                      : OutlinedButton(
                          onPressed: () => unawaited(controller.loadMore()),
                          child: const Text('Load more results'),
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
      TextField(
        key: const ValueKey<String>('online-search-query'),
        controller: _query,
        textInputAction: TextInputAction.search,
        maxLength: 500,
        decoration: InputDecoration(
          labelText: 'Search ${widget.translation.toUpperCase()}',
          hintText: 'Words, a phrase or a Scripture reference',
          errorText: _validationError,
          suffixIcon: IconButton(
            tooltip: 'Search',
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
            'Word mode',
            _words,
            const <SearchWordMode, String>{
              SearchWordMode.all: 'All words',
              SearchWordMode.any: 'Any word',
              SearchWordMode.phrase: 'Exact phrase',
            },
            (SearchWordMode value) {
              _words = value;
              if (value != SearchWordMode.all) _proximity.clear();
              _inputChanged();
            },
          ),
          _dropdown<SearchMatchMode>(
            'Match mode',
            _match,
            const <SearchMatchMode, String>{
              SearchMatchMode.exact: 'Exact word',
              SearchMatchMode.partial: 'Partial word',
            },
            (SearchMatchMode value) {
              _match = value;
              _inputChanged();
            },
          ),
          _dropdown<OnlineSearchScope>(
            'Search scope',
            _scope,
            const <OnlineSearchScope, String>{
              OnlineSearchScope.bible: 'Whole Bible',
              OnlineSearchScope.oldTestament: 'Old Testament',
              OnlineSearchScope.newTestament: 'New Testament',
              OnlineSearchScope.deuterocanon: 'Deuterocanon',
            },
            (OnlineSearchScope value) {
              _scope = value;
              _inputChanged();
            },
          ),
          FilterChip(
            label: const Text('Case sensitive'),
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
        title: const Text('Advanced filters'),
        tilePadding: EdgeInsets.zero,
        childrenPadding: const EdgeInsets.only(bottom: 12),
        expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Wrap(
            spacing: 12,
            runSpacing: 8,
            children: <Widget>[
              _dropdown<SearchDiacritics>(
                'Diacritics',
                _diacritics,
                const <SearchDiacritics, String>{
                  SearchDiacritics.fold: 'Fold diacritics',
                  SearchDiacritics.exact: 'Exact diacritics',
                },
                (SearchDiacritics value) {
                  _diacritics = value;
                  _inputChanged();
                },
              ),
              _dropdown<SearchSort>(
                'Result order',
                _sort,
                const <SearchSort, String>{
                  SearchSort.canonical: 'Bible order',
                  SearchSort.relevance: 'Relevance order',
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
                      ? 'All discovered books'
                      : '${_books.length} selected books',
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
                          'Book $number',
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
            decoration: const InputDecoration(
              labelText: 'Exclude words',
              helperText:
                  'Comma-separated; at most 32 terms, 100 characters each.',
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
            decoration: const InputDecoration(
              labelText: 'Proximity (optional)',
              helperText: '0–100 intervening units; available with All words.',
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
      title: const Text('Search selected books'),
      content: SizedBox(
        width: 440,
        height: MediaQuery.sizeOf(context).height * 0.5,
        child: Column(
          children: <Widget>[
            TextField(
              decoration: const InputDecoration(labelText: 'Find a book'),
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
            Text('${_selected.length} of 83 available selections'),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => setState(_selected.clear),
          child: const Text('All books'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_selected.toList()),
          child: const Text('Apply'),
        ),
      ],
    );
  }
}
