import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/ui_strings.dart';
import '../../domain/models/bible.dart';
import '../../domain/models/passage.dart';

/// Browses the selected Bible without changing the reader until a chapter opens.
///
/// The caller owns the route and reader navigation. [onOpen] must throw when the
/// chapter cannot open, and close this surface only after successful navigation.
/// It must also reject navigation after its route has been dismissed.
class ReaderPassagePicker extends StatefulWidget {
  const ReaderPassagePicker({
    required this.books,
    required this.passage,
    required this.loadChapters,
    required this.onOpen,
    required this.onClose,
    super.key,
  });

  final List<BibleBook> books;
  final Passage passage;
  final Future<List<ChapterInfo>> Function(int book) loadChapters;
  final Future<void> Function(Passage passage) onOpen;
  final VoidCallback onClose;

  @override
  State<ReaderPassagePicker> createState() => _ReaderPassagePickerState();
}

class _ReaderPassagePickerState extends State<ReaderPassagePicker> {
  final _search = TextEditingController();
  final _scroll = ScrollController();
  BibleBook? _book;
  List<ChapterInfo> _chapters = const [];
  Passage? _retryPassage;
  int _request = 0;
  bool _loading = false;
  bool _opening = false;
  bool _failed = false;
  bool _closed = false;

  @override
  void dispose() {
    _request++;
    _search.dispose();
    _scroll.dispose();
    super.dispose();
  }

  bool _owns(int request) => mounted && !_closed && request == _request;

  void _resetScroll() {
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  Future<void> _selectBook(BibleBook book) async {
    final request = ++_request;
    FocusManager.instance.primaryFocus?.unfocus();
    _resetScroll();
    setState(() {
      _book = book;
      _chapters = const [];
      _loading = true;
      _failed = false;
      _retryPassage = null;
    });
    try {
      final chapters = await widget.loadChapters(book.number);
      if (!_owns(request)) return;
      setState(() {
        _chapters = chapters;
        _loading = false;
      });
    } on Object {
      if (!_owns(request)) return;
      setState(() {
        _loading = false;
        _failed = true;
      });
    }
  }

  void _showBooks() {
    _request++;
    _resetScroll();
    setState(() {
      _book = null;
      _chapters = const [];
      _loading = false;
      _failed = false;
      _retryPassage = null;
    });
  }

  void _close() {
    _closed = true;
    _request++;
    widget.onClose();
  }

  Future<void> _open(Passage passage) async {
    if (_opening) return;
    final request = ++_request;
    setState(() {
      _opening = true;
      _failed = false;
      _retryPassage = passage;
    });
    try {
      await widget.onOpen(passage);
      if (!_owns(request)) return;
      setState(() => _opening = false);
    } on Object {
      if (!_owns(request)) return;
      setState(() {
        _opening = false;
        _failed = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final strings = UiStrings.of(context);
    final book = _book;
    return PopScope<void>(
      // System Back first returns from chapters to books. An opening reader
      // request may dismiss the route; its caller owns cancellation of that work.
      canPop: book == null || _opening,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) {
          _closed = true;
          _request++;
        } else if (!_opening) {
          _showBooks();
        }
      },
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = math.max(0.0, constraints.maxWidth - 32);
          final scale = MediaQuery.textScalerOf(context).scale(16) / 16;
          return ListView(
            key: const ValueKey('passage-picker-scroll'),
            controller: _scroll,
            padding: const EdgeInsets.all(16),
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (book != null)
                    IconButton(
                      key: const ValueKey('passage-picker-back'),
                      tooltip: strings.text('All discovered books'),
                      onPressed: _opening ? null : _showBooks,
                      constraints: const BoxConstraints(
                        minWidth: 48,
                        minHeight: 48,
                      ),
                      icon: const BackButtonIcon(),
                    ),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Semantics(
                            header: true,
                            child: Text(
                              book?.name ?? strings.text('Choose passage'),
                              textDirection: book == null
                                  ? null
                                  : book.isRtl
                                  ? TextDirection.rtl
                                  : TextDirection.ltr,
                              style: Theme.of(context).textTheme.titleLarge,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            widget.passage.translation.toUpperCase(),
                            semanticsLabel:
                                '${strings.text('Translation')}: ${widget.passage.translation.toUpperCase()}',
                            style: Theme.of(context).textTheme.labelLarge,
                          ),
                        ],
                      ),
                    ),
                  ),
                  IconButton(
                    key: const ValueKey('passage-picker-close'),
                    tooltip: strings.text('Close Bible navigation'),
                    onPressed: _close,
                    constraints: const BoxConstraints(
                      minWidth: 48,
                      minHeight: 48,
                    ),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              if (book == null) ...[
                const SizedBox(height: 12),
                TextField(
                  key: const ValueKey('passage-picker-search'),
                  controller: _search,
                  decoration: InputDecoration(
                    labelText: strings.text('Find a book'),
                    prefixIcon: const Icon(Icons.search),
                    border: const OutlineInputBorder(),
                  ),
                  onChanged: (_) => setState(() {}),
                ),
                const SizedBox(height: 16),
                ..._bookGroups(context, width, scale),
              ] else ...[
                _heading(context, strings.text('Chapters')),
                if (_loading || _opening)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    child: LinearProgressIndicator(
                      semanticsLabel: _opening
                          ? strings.text('Loading passage')
                          : strings.text('Loading'),
                    ),
                  ),
                if (_failed) ...[
                  Semantics(
                    liveRegion: true,
                    child: Text(
                      strings.text('The passage could not be loaded.'),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: TextButton.icon(
                      key: const ValueKey('passage-picker-retry'),
                      onPressed: () => _retryPassage == null
                          ? _selectBook(book)
                          : _open(_retryPassage!),
                      icon: const Icon(Icons.refresh),
                      label: Text(strings.text('Retry')),
                      style: TextButton.styleFrom(
                        minimumSize: const Size(48, 48),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                ],
                if (!_loading && !_failed && _chapters.isEmpty)
                  Text(strings.text('This book has no chapters.')),
                if (_chapters.isNotEmpty)
                  _chapterGrid(context, book, width, scale),
              ],
            ],
          );
        },
      ),
    );
  }

  List<Widget> _bookGroups(BuildContext context, double width, double scale) {
    final strings = UiStrings.of(context);
    final query = _search.text.trim().toLowerCase();
    final filtered = widget.books.where(
      (book) =>
          query.isEmpty ||
          book.name.toLowerCase().contains(query) ||
          book.number.toString() == query,
    );
    if (widget.books.isEmpty) {
      return [Text(strings.text('This translation has no books.'))];
    }
    if (filtered.isEmpty) {
      return [Text(strings.text('No matching resources.'))];
    }
    final groups = <(String, List<BibleBook>)>[
      (
        strings.text('Old Testament'),
        filtered
            .where((book) => book.number >= 1 && book.number <= 39)
            .toList(),
      ),
      (
        strings.text('New Testament'),
        filtered
            .where((book) => book.number >= 40 && book.number <= 66)
            .toList(),
      ),
      (
        strings.text('All discovered books'),
        filtered.where((book) => book.number < 1 || book.number > 66).toList(),
      ),
    ];
    final columns = (width / (64 * scale)).floor().clamp(
      1,
      width < 500 ? 4 : 8,
    );
    final cellWidth = (width - (columns - 1) * 8) / columns;
    final labels = _abbreviatedBooks(widget.books);
    return [
      for (final (title, books) in groups)
        if (books.isNotEmpty) ...[
          _heading(context, title),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final book in books)
                SizedBox(
                  width: cellWidth,
                  child: Tooltip(
                    message: book.name,
                    excludeFromSemantics: true,
                    child: _choice(
                      context,
                      key: ValueKey('passage-book-${book.number}'),
                      selected: widget.passage.book == book.number,
                      label: labels[book.number]!,
                      semanticLabel: book.name,
                      textDirection: book.isRtl
                          ? TextDirection.rtl
                          : TextDirection.ltr,
                      onPressed: () => _selectBook(book),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 20),
        ],
    ];
  }

  Widget _chapterGrid(
    BuildContext context,
    BibleBook book,
    double width,
    double scale,
  ) {
    final columns = (width / (48 + 24 * scale)).floor().clamp(1, 8);
    final cellWidth = (width - (columns - 1) * 8) / columns;
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final chapter in _chapters)
          SizedBox(
            width: chapter.isIntroduction || chapter.chapter == 0
                ? width
                : cellWidth,
            child: _choice(
              context,
              key: ValueKey('passage-chapter-${chapter.chapter}'),
              selected:
                  widget.passage.book == book.number &&
                  widget.passage.chapter == chapter.chapter,
              label: chapter.isIntroduction || chapter.chapter == 0
                  ? UiStrings.of(context).text('Introduction')
                  : chapter.chapter.toString(),
              semanticLabel: chapter.name,
              textDirection: book.isRtl ? TextDirection.rtl : TextDirection.ltr,
              onPressed: _opening
                  ? null
                  : () => _open(
                      widget.passage.copyWith(
                        book: book.number,
                        chapter: chapter.chapter,
                        clearVerse: true,
                      ),
                    ),
            ),
          ),
      ],
    );
  }

  Widget _heading(BuildContext context, String title) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Semantics(
      header: true,
      child: Text(title, style: Theme.of(context).textTheme.titleMedium),
    ),
  );

  Widget _choice(
    BuildContext context, {
    required Key key,
    required bool selected,
    required String label,
    required TextDirection textDirection,
    required VoidCallback? onPressed,
    String? semanticLabel,
  }) {
    final colors = Theme.of(context).colorScheme;
    return Semantics(
      selected: selected,
      child: OutlinedButton(
        key: key,
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(48, 56),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
          backgroundColor: selected ? colors.primaryContainer : null,
          foregroundColor: selected ? colors.onPrimaryContainer : null,
          side: BorderSide(color: selected ? colors.primary : colors.outline),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
        onPressed: onPressed,
        child: Text(
          label,
          semanticsLabel: semanticLabel,
          textAlign: TextAlign.center,
          textDirection: textDirection,
        ),
      ),
    );
  }
}

/// Source-derived prefixes keep a compact grid without imposing English book
/// names on other Bibles. Grow colliding prefixes together (Phili/Phile), keep
/// numbered-book prefixes and never split a Unicode grapheme. Tooltips and
/// accessibility labels retain each complete published name.
Map<int, String> _abbreviatedBooks(List<BibleBook> books) {
  final parts = <int, (String, List<String>)>{};
  final lengths = <int, int>{};
  for (final book in books) {
    final name = book.name.trim();
    final numbered = RegExp(r'^(\d+)\s+(.+)$').firstMatch(name);
    parts[book.number] = (
      numbered == null ? '' : '${numbered.group(1)}\u00a0',
      (numbered?.group(2) ?? name).characters.toList(),
    );
    lengths[book.number] = 3;
  }
  Map<int, String> labels() => {
    for (final book in books)
      book.number:
          '${parts[book.number]!.$1}${parts[book.number]!.$2.take(lengths[book.number]!).join()}',
  };
  Map<String, List<int>> collisions(Map<int, String> values) {
    final groups = <String, List<int>>{};
    for (final entry in values.entries) {
      groups.putIfAbsent(entry.value.toLowerCase(), () => []).add(entry.key);
    }
    return groups;
  }

  var result = labels();
  while (true) {
    var extended = false;
    for (final group in collisions(result).values) {
      if (group.length < 2) continue;
      for (final number in group) {
        if (lengths[number]! >= parts[number]!.$2.length) continue;
        lengths[number] = lengths[number]! + 1;
        extended = true;
      }
    }
    if (!extended) break;
    result = labels();
  }
  for (final group in collisions(result).values) {
    if (group.length < 2) continue;
    for (final number in group) {
      result[number] = '${result[number]} · $number';
    }
  }
  return result;
}
