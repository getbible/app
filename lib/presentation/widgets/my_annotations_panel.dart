import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../application/app_state.dart';
import '../../domain/models/annotations.dart';
import '../../domain/models/passage.dart';

/// Existing canonical annotations remain independent of public Study resources.
class MyAnnotationsPanel extends StatefulWidget {
  const MyAnnotationsPanel({
    super.key,
    required this.state,
    required this.onOpenPassage,
    this.showNotes = false,
  });
  final AppState state;
  final ValueChanged<Passage> onOpenPassage;
  final bool showNotes;
  @override
  State<MyAnnotationsPanel> createState() => _MyAnnotationsPanelState();
}

class _MyAnnotationsPanelState extends State<MyAnnotationsPanel> {
  String? _selectedGroup;
  String _groupQuery = '';
  final TextEditingController _groupSearch = TextEditingController();

  @override
  void dispose() {
    _groupSearch.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.state,
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
    label: const Text('Manage groups'),
  );

  Widget _markings(AppState state) {
    if (_selectedGroup != null) {
      final MarkingGroup? group = state.groups
          .where((MarkingGroup item) => item.id == _selectedGroup)
          .firstOrNull;
      final List<Marking> items =
          state.savedMarkings
              .where((Marking item) => item.groupId == _selectedGroup)
              .toList()
            ..sort(compareMarkings);
      return CustomScrollView(
        key: ValueKey<String>('marking-group:$_selectedGroup'),
        slivers: <Widget>[
          SliverToBoxAdapter(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                ListTile(
                  leading: const Icon(Icons.arrow_back),
                  title: Text(group?.name ?? 'Markings'),
                  onTap: () => setState(() => _selectedGroup = null),
                ),
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
            const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text('No markings in this group yet.'),
              ),
            )
          else
            SliverList.builder(
              itemCount: items.length,
              itemBuilder: (BuildContext context, int index) {
                final Marking marking = items[index];
                return Card(
                  margin: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 4,
                  ),
                  child: InkWell(
                    onTap: () => _openMarking(state, marking),
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: <Widget>[
                          Text(
                            marking.reference,
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          Text(
                            marking.quote,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          Wrap(
                            spacing: 8,
                            children: <Widget>[
                              TextButton.icon(
                                label: const Text('Open'),
                                icon: const Icon(Icons.open_in_new),
                                onPressed: () => _openMarking(state, marking),
                              ),
                              TextButton.icon(
                                label: const Text('Delete marking'),
                                icon: const Icon(Icons.delete_outline),
                                onPressed: () => _deleteMarking(state, marking),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
        ],
      );
    }
    final String query = _groupQuery.trim().toLowerCase();
    final List<MarkingGroup> visible = state.groups
        .where(
          (MarkingGroup group) =>
              query.isEmpty || group.name.toLowerCase().contains(query),
        )
        .toList(growable: false);
    final Map<String, int> counts = <String, int>{};
    for (final Marking marking in state.savedMarkings) {
      counts.update(
        marking.groupId,
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
                        decoration: const InputDecoration(
                          hintText: 'Find a marking group',
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
                    ],
                  ),
                ),
              ),
              if (visible.isEmpty)
                const SliverToBoxAdapter(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Text('No marking groups match this search.'),
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
                                        '$count ${count == 1 ? 'marking' : 'markings'}',
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

  void _openMarking(AppState state, Marking marking) => widget.onOpenPassage(
    Passage(
      translation: state.passage.translation,
      book: marking.passage.book,
      chapter: marking.passage.chapter,
      verse: marking.verse,
    ),
  );

  Future<void> _deleteMarking(AppState state, Marking marking) async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        scrollable: true,
        title: const Text('Delete this marking?'),
        content: Text('Remove the saved marking at ${marking.reference}?'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed == true) await state.deleteSavedMarking(marking.id);
  }

  Widget _notes(AppState state) {
    final List<VerseNote> notes = <VerseNote>[...state.savedNotes]
      ..sort(compareNotes);
    if (notes.isEmpty) {
      return const SingleChildScrollView(
        padding: EdgeInsets.all(24),
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'No verse notes yet. Select a verse and choose Add note to create one.',
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
                              'Marking groups',
                              style: Theme.of(context).textTheme.titleLarge,
                            ),
                          ),
                          IconButton(
                            tooltip: 'Close marking groups',
                            onPressed: () => Navigator.of(context).pop(),
                            icon: const Icon(Icons.close),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _name,
                        decoration: const InputDecoration(
                          labelText: 'Group name',
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _color,
                        decoration: const InputDecoration(
                          labelText: 'Color',
                          helperText:
                              'Six-digit hex color, for example #FDE68A',
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
                                  ? 'Saving…'
                                  : _editingId == null
                                  ? 'Add group'
                                  : 'Save group',
                            ),
                          ),
                          if (_editingId != null)
                            TextButton(
                              onPressed: _saving ? null : _clearEditor,
                              child: const Text('Cancel edit'),
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
                      tooltip: 'Delete ${group.name}',
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
        title: const Text('Delete marking group?'),
        content: Text(
          'Delete “${group.name}” and its $count saved markings? This cannot be undone.',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
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
