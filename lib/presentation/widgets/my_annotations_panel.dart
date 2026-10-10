import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../application/app_state.dart';
import '../../core/ui_strings.dart';
import '../../domain/models/annotations.dart';
import '../../domain/models/passage.dart';
import '../../domain/models/unified_bookmarks.dart';
import 'topic_verse_list.dart';

/// Existing canonical annotations remain independent of public Study resources.
class MyAnnotationsPanel extends StatefulWidget {
  const MyAnnotationsPanel({
    super.key,
    required this.state,
    required this.onOpenPassage,
    this.showNotes = false,
    this.initialGroupId,
    this.onBackToVerse,
  });
  final AppState state;
  final ValueChanged<Passage> onOpenPassage;
  final bool showNotes;
  final String? initialGroupId;
  final VoidCallback? onBackToVerse;
  @override
  State<MyAnnotationsPanel> createState() => _MyAnnotationsPanelState();
}

class _MyAnnotationsPanelState extends State<MyAnnotationsPanel> {
  String? _selectedGroup;
  String _groupQuery = '';
  final TextEditingController _groupSearch = TextEditingController();

  @override
  void initState() {
    super.initState();
    _selectedGroup = widget.initialGroupId;
    if (!widget.showNotes) {
      Future<void>.microtask(() async {
        if (!mounted) return;
        await widget.state.bookmarks.initialize(locale: widget.state.ui.locale);
      });
    }
  }

  @override
  void didUpdateWidget(MyAnnotationsPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.initialGroupId != widget.initialGroupId) {
      _selectedGroup = widget.initialGroupId;
    }
  }

  @override
  void dispose() {
    _groupSearch.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge([widget.state, widget.state.bookmarks]),
    builder: (BuildContext context, Widget? child) =>
        widget.showNotes ? _notes(widget.state) : _markings(widget.state),
  );

  Widget _manageButton() => OutlinedButton.icon(
    onPressed: () => unawaited(
      showDialog<void>(
        context: context,
        builder: (BuildContext context) =>
            _ManageGroupsDialog(state: widget.state),
      ),
    ),
    icon: const Icon(Icons.palette_outlined),
    label: Text(UiStrings.of(context).text('Manage groups')),
  );

  Widget _markings(AppState state) {
    if (_selectedGroup != null &&
        !state.groups.any((group) => group.id == _selectedGroup)) {
      _selectedGroup = null;
    }
    if (_selectedGroup != null) {
      final MarkingGroup? group = state.groups
          .where((MarkingGroup item) => item.id == _selectedGroup)
          .firstOrNull;
      final List<BookmarkDisplayRow> items = bookmarkDisplayRows(
        state.savedMarkings.where((item) => item.groupId == _selectedGroup),
      );
      return CustomScrollView(
        key: ValueKey<String>('marking-group:$_selectedGroup'),
        slivers: <Widget>[
          SliverToBoxAdapter(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Wrap(
                    spacing: 12,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      TextButton.icon(
                        onPressed: () => setState(() => _selectedGroup = null),
                        icon: const Icon(Icons.arrow_back),
                        label: Text(UiStrings.of(context).text('All topics')),
                      ),
                      if (widget.onBackToVerse != null)
                        TextButton.icon(
                          onPressed: widget.onBackToVerse,
                          icon: const Icon(Icons.keyboard_return),
                          label: Text(
                            UiStrings.of(context).text('Back to verse'),
                          ),
                        ),
                    ],
                  ),
                ),
                ListTile(
                  leading: group == null
                      ? null
                      : CircleAvatar(
                          radius: 12,
                          backgroundColor: Color(
                            int.parse(group.color.substring(1), radix: 16) |
                                0xff000000,
                          ),
                        ),
                  title: Text(
                    group?.name ?? UiStrings.of(context).text('Markings'),
                  ),
                  subtitle: Text(
                    UiStrings.of(
                      context,
                    ).text('{count} bookmarks', {'count': items.length}),
                  ),
                ),
                if (group?.source?.effectiveScope ==
                    state.bookmarks.publicTopics.sourceScope)
                  _globalSection(state, topicId: group!.source!.topicId),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: _manageButton(),
                  ),
                ),
              ],
            ),
          ),
          if (items.isEmpty)
            SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  UiStrings.of(context).text('No markings in this group yet.'),
                ),
              ),
            )
          else
            TopicVerseList(
              key: ValueKey('saved-topic:$_selectedGroup'),
              lookup: state.referenceLookup,
              items: [
                for (final row in items)
                  TopicVerseItem(
                    passage: row.marking.passage.copyWith(
                      translation: state.passage.translation,
                      verse: row.marking.verse,
                    ),
                    reference: _displayReference(state, row),
                    global: row.global,
                    personal: row.personal,
                    selectedQuote: row.marking.isWholeVerse
                        ? null
                        : row.marking.quote,
                    quoteTranslation: row.marking.passage.translation,
                  ),
              ],
              preferences: state.preferences,
              onOpen: (item) => widget.onOpenPassage(item.passage),
              actionsBuilder: (item, index) {
                final row = items[index];
                return [
                  if (row.personal)
                    IconButton(
                      tooltip: UiStrings.of(
                        context,
                      ).text('Remove personal bookmark'),
                      icon: const Icon(Icons.person_remove_outlined),
                      onPressed: state.bookmarks.busy
                          ? null
                          : () => _deleteOrigin(
                              state,
                              row.marking,
                              BookmarkOrigin.personal,
                            ),
                    ),
                  if (row.global)
                    IconButton(
                      tooltip: UiStrings.of(
                        context,
                      ).text('Remove global bookmark'),
                      icon: const Icon(Icons.public_off),
                      onPressed: state.bookmarks.busy
                          ? null
                          : () => _deleteOrigin(
                              state,
                              row.marking,
                              BookmarkOrigin.global,
                            ),
                    ),
                ];
              },
            ),
        ],
      );
    }
    final String query = _groupQuery.trim().toLowerCase();
    final List<MarkingGroup> visible = state.groups
        .where(
          (MarkingGroup group) =>
              query.isEmpty ||
              group.name.toLowerCase().contains(query) ||
              (group.source?.effectiveScope ==
                      state.bookmarks.publicTopics.sourceScope &&
                  state.bookmarks
                          .topic(group.source!.topicId)
                          ?.matches(query) ==
                      true),
        )
        .toList(growable: false);
    final Map<String, int> counts = <String, int>{};
    for (final row in bookmarkDisplayRows(state.savedMarkings)) {
      counts.update(
        row.marking.groupId,
        (int count) => count + 1,
        ifAbsent: () => 1,
      );
    }
    final TextScaler textScaler = MediaQuery.textScalerOf(context);
    final double scale = textScaler.scale(16) / 16;
    final TextStyle nameStyle =
        (Theme.of(context).textTheme.bodyMedium ??
                const TextStyle(fontSize: 14, height: 1.5))
            .copyWith(fontWeight: FontWeight.w600);
    final TextStyle countStyle =
        Theme.of(context).textTheme.bodySmall ??
        const TextStyle(fontSize: 12, height: 1.5);
    final double cardHeight =
        40 +
        textScaler.scale(nameStyle.fontSize ?? 14) *
            (nameStyle.height ?? 1.5) *
            2 +
        textScaler.scale(countStyle.fontSize ?? 12) *
            (countStyle.height ?? 1.5);
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) =>
          CustomScrollView(
            key: const ValueKey<String>('marking-groups'),
            slivers: <Widget>[
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      TextField(
                        controller: _groupSearch,
                        decoration: InputDecoration(
                          hintText: UiStrings.of(
                            context,
                          ).text('Find a marking group'),
                          prefixIcon: Icon(Icons.search),
                          isDense: true,
                        ),
                        onChanged: (String value) =>
                            setState(() => _groupQuery = value),
                      ),
                      const SizedBox(height: 8),
                      Align(
                        alignment: AlignmentDirectional.centerStart,
                        child: _manageButton(),
                      ),
                      _globalSection(state),
                    ],
                  ),
                ),
              ),
              if (visible.isEmpty)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Text(
                      UiStrings.of(
                        context,
                      ).text('No marking groups match this search.'),
                    ),
                  ),
                ),
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                sliver: SliverGrid.builder(
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: math.max(
                      1,
                      ((constraints.maxWidth - 24) / (220 * math.max(1, scale)))
                          .floor(),
                    ),
                    mainAxisExtent: cardHeight,
                    crossAxisSpacing: 10,
                    mainAxisSpacing: 10,
                  ),
                  itemCount: visible.length,
                  itemBuilder: (BuildContext context, int index) {
                    final MarkingGroup group = visible[index];
                    final int count = counts[group.id] ?? 0;
                    final bool selected =
                        state.preferences.activeMarkingGroupId == group.id;
                    return Semantics(
                      button: true,
                      selected: selected,
                      child: Card(
                        clipBehavior: Clip.antiAlias,
                        color: selected
                            ? Theme.of(context).colorScheme.secondaryContainer
                            : null,
                        child: InkWell(
                          onTap: () {
                            unawaited(state.selectActiveGroup(group.id));
                            setState(() => _selectedGroup = group.id);
                          },
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: Row(
                              children: <Widget>[
                                Container(
                                  width: 18,
                                  height: 40,
                                  decoration: BoxDecoration(
                                    color: _hexColor(group.color),
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Column(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: <Widget>[
                                      Text(
                                        group.name,
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                        style: nameStyle,
                                      ),
                                      Text(
                                        count == 1
                                            ? UiStrings.of(context)(
                                                'oneMarking',
                                              )
                                            : UiStrings.of(context)(
                                                'markingCount',
                                                {'count': count},
                                              ),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: countStyle,
                                      ),
                                    ],
                                  ),
                                ),
                                if (selected)
                                  const Icon(Icons.check_circle, size: 18),
                              ],
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
    );
  }

  String _displayReference(AppState state, BookmarkDisplayRow row) {
    final marking = row.marking;
    final book = state.books
        .where((book) => book.number == marking.passage.book)
        .firstOrNull;
    // Display current translation metadata without rewriting the imported
    // reference or quotation. Dynamic book IDs also cover extended canons.
    return book == null
        ? marking.reference
        : '${book.name} ${marking.passage.chapter}:${marking.verse}';
  }

  Future<void> _deleteOrigin(
    AppState state,
    Marking marking,
    BookmarkOrigin origin,
  ) async {
    final strings = UiStrings.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        scrollable: true,
        title: Text(
          origin == BookmarkOrigin.personal
              ? UiStrings.of(context).text('Remove personal bookmark?')
              : UiStrings.of(context).text('Remove global bookmark?'),
        ),
        content: Text(
          strings.text(
            'Remove this membership at {reference}? Other topics and the other origin remain saved.',
            {'reference': marking.reference},
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(strings('cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(strings.text('Remove')),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await state.bookmarks.removeMembership(
        passage: marking.passage,
        verse: marking.verse,
        groupId: marking.groupId,
        start: marking.start,
        end: marking.end,
        origin: origin,
      );
    }
  }

  Widget _globalControls(AppState state, {String? topicId}) {
    final controller = state.bookmarks;
    final strings = UiStrings.of(context);
    final hasGlobal = state.savedMarkings.any(
      (mark) =>
          mark.sharedSource?.effectiveScope ==
              controller.publicTopics.sourceScope &&
          (topicId == null || mark.sharedSource?.topicId == topicId),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (topicId == null)
            Text(
              strings.text(
                'Your topics and public topics share this bookmark list. Downloading adds global memberships; your personal bookmarks remain independent.',
              ),
            ),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.tonalIcon(
                onPressed: controller.busy
                    ? null
                    : () => unawaited(
                        controller.download(
                          topicId: topicId,
                          translation: state.passage.translation,
                          locale: state.ui.locale,
                        ),
                      ),
                icon: const Icon(Icons.download),
                label: Text(
                  topicId == null
                      ? UiStrings.of(
                          context,
                        ).text('Download all global bookmarks')
                      : UiStrings.of(
                          context,
                        ).text('Download this topic’s global bookmarks'),
                ),
              ),
              OutlinedButton.icon(
                onPressed: controller.busy || !hasGlobal
                    ? null
                    : () => unawaited(_removeGlobal(state, topicId)),
                icon: const Icon(Icons.public_off),
                label: Text(
                  topicId == null
                      ? UiStrings.of(context).text('Remove global bookmarks')
                      : UiStrings.of(
                          context,
                        ).text('Remove this topic’s global bookmarks'),
                ),
              ),
            ],
          ),
          if (controller.busy) const LinearProgressIndicator(),
          if (controller.error != null) ...[
            Text(
              strings.text(
                'Global topics could not be updated. Your saved bookmarks are still available. {error}',
                {'error': controller.error.toString()},
              ),
            ),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton(
                onPressed: controller.busy
                    ? null
                    : () => unawaited(
                        controller.initialize(locale: state.ui.locale),
                      ),
                child: Text(strings.text('Retry')),
              ),
            ),
          ],
        ],
      ),
    );
  }

  // Public-service status and download controls must not push private topics
  // out of reach on a short screen, especially with large text or an error.
  Widget _globalSection(AppState state, {String? topicId}) => ExpansionTile(
    key: PageStorageKey<String>('global-bookmarks:${topicId ?? 'all'}'),
    leading: Icon(
      state.bookmarks.error == null ? Icons.public : Icons.error_outline,
    ),
    title: Text(UiStrings.of(context).text('Global bookmarks')),
    children: [_globalControls(state, topicId: topicId)],
  );

  Future<void> _removeGlobal(AppState state, String? topicId) async {
    final strings = UiStrings.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        scrollable: true,
        title: Text(strings.text('Remove downloaded global bookmarks?')),
        content: Text(
          strings.text(
            'Personal bookmarks, topic names, colors, notes and notebooks will remain saved.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(strings('cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(strings.text('Remove')),
          ),
        ],
      ),
    );
    if (confirmed == true) await state.bookmarks.removeGlobal(topicId: topicId);
  }

  Widget _notes(AppState state) {
    final List<VerseNote> notes = <VerseNote>[...state.savedNotes]
      ..sort(compareNotes);
    if (notes.isEmpty) {
      return SingleChildScrollView(
        padding: EdgeInsets.all(24),
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            UiStrings.of(context).text(
              'No verse notes yet. Select a verse and choose Add note to create one.',
            ),
          ),
        ),
      );
    }
    return ListView.builder(
      itemCount: notes.length,
      itemBuilder: (BuildContext context, int index) {
        final VerseNote note = notes[index];
        return ListTile(
          title: Text(note.reference),
          subtitle: Text(
            note.text,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
          ),
          onTap: () => widget.onOpenPassage(
            Passage(
              translation: state.passage.translation,
              book: note.passage.book,
              chapter: note.passage.chapter,
              verse: note.verse,
            ),
          ),
        );
      },
    );
  }
}

class _ManageGroupsDialog extends StatefulWidget {
  const _ManageGroupsDialog({required this.state});

  final AppState state;

  @override
  State<_ManageGroupsDialog> createState() => _ManageGroupsDialogState();
}

class _ManageGroupsDialogState extends State<_ManageGroupsDialog> {
  String? _editingId;
  final TextEditingController _name = TextEditingController();
  final TextEditingController _color = TextEditingController(text: '#FDE68A');
  String? _error;
  bool _saving = false;

  @override
  void dispose() {
    _name.dispose();
    _color.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final double availableHeight =
        MediaQuery.sizeOf(context).height -
        MediaQuery.viewInsetsOf(context).bottom -
        MediaQuery.paddingOf(context).vertical -
        32;
    return Dialog(
      insetPadding: const EdgeInsets.all(16),
      child: SizedBox(
        width: 560,
        height: math.max(48, availableHeight * 0.9),
        child: AnimatedBuilder(
          animation: widget.state,
          builder: (BuildContext context, Widget? child) => CustomScrollView(
            slivers: <Widget>[
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      Row(
                        children: <Widget>[
                          Expanded(
                            child: Text(
                              UiStrings.of(context).text('Marking groups'),
                              style: Theme.of(context).textTheme.titleLarge,
                            ),
                          ),
                          IconButton(
                            tooltip: UiStrings.of(
                              context,
                            ).text('Close marking groups'),
                            onPressed: () => Navigator.of(context).pop(),
                            icon: const Icon(Icons.close),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _name,
                        decoration: InputDecoration(
                          labelText: UiStrings.of(context).text('Group name'),
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _color,
                        decoration: InputDecoration(
                          labelText: UiStrings.of(context).text('Color'),
                          helperText: UiStrings.of(context).text(
                            'Six-digit hex color, for example {example}',
                            {'example': '#FDE68A'},
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: <Widget>[
                          FilledButton.icon(
                            onPressed: _saving ? null : _save,
                            icon: Icon(
                              _editingId == null ? Icons.add : Icons.check,
                            ),
                            label: Text(
                              _saving
                                  ? UiStrings.of(context).text('Saving…')
                                  : _editingId == null
                                  ? UiStrings.of(context).text('Add group')
                                  : UiStrings.of(context).text('Save group'),
                            ),
                          ),
                          if (_editingId != null)
                            TextButton(
                              onPressed: _saving ? null : _clearEditor,
                              child: Text(
                                UiStrings.of(context).text('Cancel edit'),
                              ),
                            ),
                        ],
                      ),
                      if (_error != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Text(
                            _error!,
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.error,
                            ),
                          ),
                        ),
                      const Divider(height: 24),
                    ],
                  ),
                ),
              ),
              SliverList.builder(
                itemCount: widget.state.groups.length,
                itemBuilder: (BuildContext context, int index) {
                  final MarkingGroup group = widget.state.groups[index];
                  return ListTile(
                    leading: Container(
                      width: 20,
                      height: 20,
                      decoration: BoxDecoration(
                        color: _hexColor(group.color),
                        shape: BoxShape.circle,
                      ),
                    ),
                    title: Text(group.name),
                    subtitle: Text(group.color),
                    onTap: _saving
                        ? null
                        : () => setState(() {
                            _editingId = group.id;
                            _name.text = group.name;
                            _color.text = group.color;
                            _error = null;
                          }),
                    trailing: IconButton(
                      tooltip: UiStrings.of(
                        context,
                      ).text('Delete {name}', {'name': group.name}),
                      onPressed: _saving || widget.state.groups.length <= 1
                          ? null
                          : () => unawaited(_delete(group)),
                      icon: const Icon(Icons.delete_outline),
                    ),
                  );
                },
              ),
              const SliverToBoxAdapter(child: SizedBox(height: 16)),
            ],
          ),
        ),
      ),
    );
  }

  void _clearEditor() => setState(() {
    _editingId = null;
    _name.clear();
    _color.text = '#FDE68A';
    _error = null;
  });

  Future<void> _save() async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.state.saveMarkingGroup(
        id: _editingId,
        name: _name.text,
        color: _color.text,
      );
      if (!mounted) return;
      setState(() {
        _editingId = null;
        _name.clear();
        _color.text = '#FDE68A';
        _error = null;
      });
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _delete(MarkingGroup group) async {
    final int count = widget.state.savedMarkings
        .where((Marking item) => item.groupId == group.id)
        .length;
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        scrollable: true,
        title: Text(UiStrings.of(context).text('Delete marking group?')),
        content: Text(
          UiStrings.of(context).text(
            'Delete “{name}” and its {count} saved markings? This cannot be undone.',
            {'name': group.name, 'count': count},
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(UiStrings.of(context).text('Cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(UiStrings.of(context).text('Delete')),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await widget.state.deleteMarkingGroup(group.id);
  }
}

Color _hexColor(String hex) =>
    Color(int.parse(hex.substring(1), radix: 16) | 0xff000000);
