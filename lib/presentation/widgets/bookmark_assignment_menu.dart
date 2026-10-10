import 'dart:async';

import 'package:flutter/material.dart';

import '../../application/app_state.dart';
import '../../core/ui_strings.dart';
import '../../domain/models/annotations.dart';
import '../../domain/models/passage.dart';
import '../../domain/models/unified_bookmarks.dart';
import '../../services/scripture_text.dart';

/// A contextual, scrollable topic picker. Storage retains personal/global
/// origins independently; every removal explicitly names the affected origin.
final class BookmarkAssignmentMenu extends StatefulWidget {
  const BookmarkAssignmentMenu({
    super.key,
    required this.state,
    required this.passage,
    required this.verse,
    required this.quote,
    required this.reference,
    this.start,
    this.end,
    this.selections,
    required this.onAdd,
    required this.onOpenTopic,
    required this.onClose,
  });
  final AppState state;
  final Passage passage;
  final int verse;
  final String quote, reference;
  final int? start, end;
  final List<ScriptureVerseSelection>? selections;
  final Future<void> Function(String groupId) onAdd;
  final ValueChanged<String?> onOpenTopic;
  final VoidCallback onClose;
  @override
  State<BookmarkAssignmentMenu> createState() => _BookmarkAssignmentMenuState();
}

final class _BookmarkAssignmentMenuState extends State<BookmarkAssignmentMenu> {
  final _search = TextEditingController();
  final _searchFocus = FocusNode();
  bool _saving = false;
  bool? _pickerOpen;
  Object? _error;
  @override
  void initState() {
    super.initState();
    Future<void>.microtask(() async {
      if (mounted && widget.state.bookmarks.catalogue.isEmpty) {
        await widget.state.bookmarks.initialize(locale: widget.state.ui.locale);
      }
    });
  }

  @override
  void dispose() {
    _search.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge([widget.state, widget.state.bookmarks]),
    builder: (context, _) {
      final strings = UiStrings.of(context);
      final state = widget.state;
      final marks = state.savedMarkings
          .where(
            (mark) =>
                mark.matchesPassage(widget.passage) &&
                (widget.selections != null
                    ? widget.selections!.any(
                        (selection) =>
                            mark.verse == selection.verse.verse &&
                            mark.start == selection.range.start &&
                            mark.end == selection.range.end,
                      )
                    : mark.verse == widget.verse &&
                          (widget.start == null ||
                              (mark.start == widget.start &&
                                  mark.end == widget.end))),
          )
          .toList();
      final assignments = <String, List<Marking>>{};
      for (final mark in marks) {
        assignments
            .putIfAbsent(
              '${mark.groupId}|${mark.verse}|${mark.start}|${mark.end}',
              () => [],
            )
            .add(mark);
      }
      final query = normalizeBookmarkTopicName(_search.text);
      final groups =
          state.groups
              .where(
                (group) =>
                    normalizeBookmarkTopicName(group.name).contains(query) ||
                    (group.source?.effectiveScope ==
                            state.bookmarks.publicTopics.sourceScope &&
                        state.bookmarks
                                .topic(group.source!.topicId)
                                ?.matches(query) ==
                            true),
              )
              .where((group) => !_isAssigned(group, marks))
              .toList()
            ..sort((a, b) => a.name.compareTo(b.name));
      final recent = state.bookmarks.recentGroupIds
          .map((id) => groups.where((group) => group.id == id).firstOrNull)
          .whereType<MarkingGroup>()
          .toList();
      final recentIds = recent.map((group) => group.id).toSet();
      final blocked = _saving || state.bookmarks.busy;
      final pickerOpen = _pickerOpen ??= assignments.isEmpty;
      return FocusTraversalGroup(
        child: _AssignmentLayout(
          header: Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(16, 4, 4, 4),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    strings('verseBookmarks', {'reference': widget.reference}),
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                IconButton(
                  tooltip: strings.text('Close'),
                  onPressed: widget.onClose,
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
          ),
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (widget.start != null)
                  Padding(
                    padding: const EdgeInsets.all(8),
                    child: Text(
                      widget.quote,
                      maxLines: 4,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                for (final values in assignments.values)
                  _assignment(values, blocked, strings),
                if (assignments.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(8),
                    child: Text(strings('noVerseBookmarks')),
                  ),
                const SizedBox(height: 8),
                Semantics(
                  expanded: pickerOpen,
                  child: OutlinedButton.icon(
                    onPressed: blocked
                        ? null
                        : () => setState(() => _pickerOpen = !pickerOpen),
                    icon: Icon(pickerOpen ? Icons.remove : Icons.add),
                    label: Text(strings('addAnotherTopic')),
                    style: OutlinedButton.styleFrom(
                      alignment: AlignmentDirectional.centerStart,
                      minimumSize: const Size(0, 48),
                    ),
                  ),
                ),
                if (_saving || state.bookmarks.loading)
                  const LinearProgressIndicator(),
                if (_error != null || state.bookmarks.error != null)
                  Text(
                    strings.text('Could not update bookmarks. {error}', {
                      'error': (_error ?? state.bookmarks.error).toString(),
                    }),
                  ),
                if (pickerOpen) ...[
                  const SizedBox(height: 8),
                  TextField(
                    controller: _search,
                    focusNode: _searchFocus,
                    decoration: InputDecoration(
                      labelText: strings('findTopic'),
                      prefixIcon: const Icon(Icons.search),
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
                  const SizedBox(height: 8),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 260),
                    child: ListView(
                      primary: false,
                      shrinkWrap: true,
                      children: [
                        if (recent.isNotEmpty) ...[
                          Padding(
                            padding: const EdgeInsets.all(8),
                            child: Text(
                              strings('recentTopics'),
                              style: Theme.of(context).textTheme.labelMedium,
                            ),
                          ),
                          for (final group in recent)
                            _topic(group, marks, blocked, strings),
                        ],
                        Padding(
                          padding: const EdgeInsets.all(8),
                          child: Text(
                            strings('allTopics'),
                            style: Theme.of(context).textTheme.labelMedium,
                          ),
                        ),
                        for (final group in groups.where(
                          (group) => !recentIds.contains(group.id),
                        ))
                          _topic(group, marks, blocked, strings),
                        if (groups.isEmpty)
                          Padding(
                            padding: const EdgeInsets.all(16),
                            child: Text(
                              strings(
                                query.isEmpty
                                    ? 'allTopicsAssigned'
                                    : 'noMatchingTopics',
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
          footer: Padding(
            padding: const EdgeInsets.all(8),
            child: TextButton(
              onPressed: blocked ? null : () => widget.onOpenTopic(null),
              style: TextButton.styleFrom(
                alignment: AlignmentDirectional.centerStart,
                minimumSize: const Size(0, 48),
              ),
              child: Text(strings('manageTopics')),
            ),
          ),
        ),
      );
    },
  );

  Widget _assignment(List<Marking> values, bool blocked, UiStrings strings) {
    final row = BookmarkDisplayRow(values);
    final mark = row.marking;
    final group = widget.state.groups
        .where((group) => group.id == mark.groupId)
        .firstOrNull;
    final color = group == null
        ? Theme.of(context).colorScheme.primary
        : Color(int.parse(group.color.substring(1), radix: 16) | 0xff000000);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: TextButton(
            onPressed: blocked ? null : () => widget.onOpenTopic(mark.groupId),
            style: TextButton.styleFrom(
              alignment: AlignmentDirectional.centerStart,
              minimumSize: const Size(0, 48),
            ),
            child: Row(
              children: [
                CircleAvatar(radius: 6, backgroundColor: color),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(group?.name ?? mark.groupId),
                      if ((widget.selections?.length ?? 0) > 1)
                        Text(mark.reference),
                      if (!mark.isWholeVerse)
                        Text(
                          mark.quote,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        if (row.global)
          IconButton(
            tooltip: strings.text('Remove global bookmark'),
            onPressed: blocked
                ? null
                : () => _remove(mark, BookmarkOrigin.global),
            icon: Semantics(
              label: strings.text(
                row.personal
                    ? 'Global and personal bookmark'
                    : 'Global bookmark',
              ),
              child: ExcludeSemantics(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(strings.text('G')),
                    const Icon(Icons.close, size: 14),
                  ],
                ),
              ),
            ),
          ),
        if (row.personal)
          IconButton(
            tooltip: strings.text('Remove personal bookmark'),
            onPressed: blocked
                ? null
                : () => _remove(mark, BookmarkOrigin.personal),
            icon: const Icon(Icons.close),
          ),
      ],
    );
  }

  bool _isAssigned(MarkingGroup group, List<Marking> marks) {
    bool hasMembership(int verse, int? start, int? end) => marks.any(
      (mark) =>
          mark.groupId == group.id &&
          !mark.isSharedBookmark &&
          mark.verse == verse &&
          mark.start == start &&
          mark.end == end,
    );
    return widget.selections != null
        ? widget.selections!.every(
            (selection) => hasMembership(
              selection.verse.verse,
              selection.range.start,
              selection.range.end,
            ),
          )
        : hasMembership(widget.verse, widget.start, widget.end);
  }

  Widget _topic(
    MarkingGroup group,
    List<Marking> marks,
    bool blocked,
    UiStrings strings,
  ) {
    final assigned = _isAssigned(group, marks);
    return ListTile(
      minTileHeight: 48,
      leading: Semantics(
        label: strings.text('Topic color {color}', {'color': group.color}),
        child: CircleAvatar(
          radius: 10,
          backgroundColor: Color(
            int.parse(group.color.substring(1), radix: 16) | 0xff000000,
          ),
        ),
      ),
      title: Text(group.name),
      trailing: Icon(assigned ? Icons.check_circle : Icons.add),
      selected: assigned,
      enabled: !blocked && !assigned,
      onTap: () => unawaited(
        _save(() async {
          await widget.onAdd(group.id);
          await widget.state.bookmarks.rememberGroup(group.id);
          _search.clear();
        }),
      ),
    );
  }

  void _remove(Marking mark, BookmarkOrigin origin) => unawaited(
    _save(
      () => widget.state.bookmarks.removeMembership(
        passage: mark.passage,
        verse: mark.verse,
        groupId: mark.groupId,
        start: mark.start,
        end: mark.end,
        origin: origin,
      ),
    ),
  );

  Future<void> _save(Future<void> Function() action) async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await action();
    } catch (error) {
      if (mounted) setState(() => _error = error);
    } finally {
      if (mounted) {
        setState(() => _saving = false);
        if (_pickerOpen == true) _searchFocus.requestFocus();
      }
    }
  }
}

/// Keeps the normal menu compact with stable chrome. When the keyboard and
/// accessible text leave too little room for that chrome, the complete menu
/// scrolls so every control remains reachable without truncating its label.
final class _AssignmentLayout extends StatelessWidget {
  const _AssignmentLayout({
    required this.header,
    required this.body,
    required this.footer,
  });

  final Widget header, body, footer;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final textScale = MediaQuery.textScalerOf(context).scale(14) / 14;
      final scrollChrome = constraints.maxHeight < 180 * textScale;
      final contents = Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          header,
          const Divider(height: 1),
          if (scrollChrome) body else Flexible(fit: FlexFit.loose, child: body),
          const Divider(height: 1),
          footer,
        ],
      );
      return scrollChrome ? SingleChildScrollView(child: contents) : contents;
    },
  );
}
