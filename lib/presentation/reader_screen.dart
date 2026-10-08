import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../application/app_state.dart';
import '../domain/models/annotations.dart';
import '../domain/models/bible.dart';
import '../domain/models/cache.dart';
import '../domain/models/passage.dart';
import '../domain/models/search.dart';
import '../services/markdown_service.dart';
import 'boundary_turn_controller.dart';
import 'widgets/reader_translation_field.dart';
import 'widgets/scripture_verification_badge.dart';

class ReaderScreen extends StatefulWidget {
  const ReaderScreen({super.key});

  @override
  State<ReaderScreen> createState() => _ReaderScreenState();
}

class _ReaderScreenState extends State<ReaderScreen> {
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  final ScrollController _scrollController = ScrollController();
  final Map<int, GlobalKey> _verseKeys = <int, GlobalKey>{};
  final BoundaryTurnController _boundaryTurns = BoundaryTurnController();
  bool _boundaryRecordedForGesture = false;
  bool _showChrome = true;
  int? _editingNote;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_updateChrome);
  }

  void _updateChrome() {
    final bool next =
        !_scrollController.hasClients || _scrollController.offset < 56;
    if (next != _showChrome && mounted) setState(() => _showChrome = next);
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final AppState state = context.watch<AppState>();
    return Scaffold(
      key: _scaffoldKey,
      drawer: _ReaderDrawer(state: state),
      endDrawer: _StudyDrawer(state: state, onOpenPassage: _openPassage),
      appBar: _showChrome
          ? _ReaderAppBar(
              state: state,
              onMenu: () => _scaffoldKey.currentState?.openDrawer(),
              onStudy: () => _scaffoldKey.currentState?.openEndDrawer(),
              onSearch: () => _showSearch(context, state),
              onHome: () => unawaited(state.openDailyScripture()),
              onTurn: (int direction) => unawaited(_turn(state, direction)),
              onMarkdown: () => _showMarkdown(context, state),
            )
          : null,
      body: SafeArea(child: _body(context, state)),
    );
  }

  Widget _body(BuildContext context, AppState state) {
    if (state.loading && state.current == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (state.error != null && state.current == null) {
      return _ErrorState(state: state);
    }
    final BibleChapter chapter = state.current!;
    final TextDirection direction = chapter.isRtl
        ? TextDirection.rtl
        : TextDirection.ltr;
    return Directionality(
      textDirection: direction,
      child: Stack(
        children: <Widget>[
          Column(
            children: <Widget>[
              if (_showChrome) _ChapterHeading(state: state),
              if (state.legacyScripture)
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                  child: Text(
                    'Saved legacy Scripture (API v2). Connect to refresh this passage from v3.',
                  ),
                ),
              if (state.error != null)
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 8,
                  ),
                  child: Text(
                    state.error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              Expanded(
                child: GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onHorizontalDragEnd: (DragEndDetails details) {
                    final double velocity = details.primaryVelocity ?? 0;
                    if (velocity.abs() < 350) return;
                    unawaited(_turn(state, velocity > 0 ? -1 : 1));
                  },
                  child: CallbackShortcuts(
                    bindings: <ShortcutActivator, VoidCallback>{
                      const SingleActivator(
                        LogicalKeyboardKey.arrowLeft,
                        alt: true,
                      ): () =>
                          unawaited(_turn(state, -1)),
                      const SingleActivator(
                        LogicalKeyboardKey.arrowRight,
                        alt: true,
                      ): () =>
                          unawaited(_turn(state, 1)),
                    },
                    child: Focus(
                      autofocus: true,
                      child: NotificationListener<ScrollNotification>(
                        onNotification: (ScrollNotification notice) =>
                            _onScrollNotification(notice, state),
                        child: _ReaderBody(
                          state: state,
                          controller: _scrollController,
                          verseKeys: _verseKeys,
                          editingNote: _editingNote,
                          onEditNote: (int? verse) =>
                              setState(() => _editingNote = verse),
                          onOpenVerseMenu: _showVerseMenu,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              if (_showChrome)
                _MobileChapterNavigation(state: state, onTurn: _turn),
            ],
          ),
          if (!_showChrome) _EdgeChapterNavigation(state: state, onTurn: _turn),
        ],
      ),
    );
  }

  bool _onScrollNotification(ScrollNotification notice, AppState state) {
    if (notice is ScrollStartNotification) {
      _boundaryRecordedForGesture = false;
      return false;
    }
    if (notice is! OverscrollNotification || notice.overscroll == 0) {
      return false;
    }
    if (_boundaryRecordedForGesture) return false;
    _boundaryRecordedForGesture = true;
    final int direction = notice.overscroll > 0 ? 1 : -1;
    if (_boundaryTurns.register(direction, DateTime.now())) {
      unawaited(_turn(state, direction));
    }
    return false;
  }

  Future<void> _turn(AppState state, int direction) async {
    if (state.loading ||
        _editingNote != null ||
        ModalRoute.of(context)?.isCurrent != true ||
        _scaffoldKey.currentState?.isDrawerOpen == true ||
        _scaffoldKey.currentState?.isEndDrawerOpen == true) {
      return;
    }
    if ((direction < 0 && !state.canGoPrevious) ||
        (direction > 0 && !state.canGoNext)) {
      return;
    }
    await state.turnChapter(direction);
    if (!mounted) return;
    if (_scrollController.hasClients) _scrollController.jumpTo(0);
    if (!_showChrome) setState(() => _showChrome = true);
  }

  Future<void> _showMarkdown(BuildContext context, AppState state) =>
      showDialog<void>(
        context: context,
        builder: (BuildContext context) =>
            _ScriptureShareDialog(state: state, initialVerse: null),
      );

  Future<void> _openPassage(Passage passage) async {
    final AppState state = context.read<AppState>();
    await Navigator.of(context).maybePop();
    if (!mounted) return;
    await state.loadPassage(passage);
    if (!mounted) return;
    await _scrollToVerse(passage.verse);
  }

  Future<void> _scrollToVerse(int? verse) async {
    if (verse == null) return;
    final AppState state = context.read<AppState>();
    final BibleChapter? chapter = state.current;
    final Passage origin = state.passage;
    bool ownsScroll() =>
        mounted && identical(state.current, chapter) && state.passage == origin;
    await WidgetsBinding.instance.endOfFrame;
    if (!ownsScroll() || !_scrollController.hasClients) return;
    final List<Verse> verses = chapter?.verses ?? const <Verse>[];
    final int targetIndex = verses.indexWhere(
      (Verse item) => item.verse == verse,
    );
    if (targetIndex < 0) return;
    // A lazy chapter list has no element for a distant verse yet. First place
    // its estimated row in view, then realize adjacent viewports until the
    // actual keyed verse is mounted. Original source IDs may be noncontiguous.
    if (_verseKeys[verse]?.currentContext == null && verses.length > 1) {
      final ScrollPosition position = _scrollController.position;
      _scrollController.jumpTo(
        position.maxScrollExtent * targetIndex / (verses.length - 1),
      );
      await WidgetsBinding.instance.endOfFrame;
    }
    final Set<int> visitedOffsets = <int>{};
    while (ownsScroll()) {
      final BuildContext? target = _verseKeys[verse]?.currentContext;
      if (target != null &&
          target.mounted &&
          target.findRenderObject()?.attached == true) {
        if (!mounted || !ownsScroll()) return;
        final bool reducedMotion =
            state.preferences.reduceMotion ||
            MediaQuery.disableAnimationsOf(context);
        await Scrollable.ensureVisible(
          target,
          alignment: 0.2,
          duration: reducedMotion
              ? Duration.zero
              : const Duration(milliseconds: 260),
        );
        return;
      }
      if (!_scrollController.hasClients) return;
      final List<int> realized = <int>[
        for (int index = 0; index < verses.length; index++)
          if (_verseKeys[verses[index].verse]?.currentContext != null) index,
      ];
      final ScrollPosition position = _scrollController.position;
      final int direction = realized.isNotEmpty && targetIndex < realized.first
          ? -1
          : 1;
      final double next =
          (position.pixels + direction * position.viewportDimension * .8).clamp(
            position.minScrollExtent,
            position.maxScrollExtent,
          );
      // Stop at a boundary or a repeated offset rather than guessing a maximum
      // introduction length. Every iteration either reveals the target or
      // advances to a previously unseen part of this chapter.
      if (next == position.pixels || !visitedOffsets.add(next.round())) return;
      _scrollController.jumpTo(next);
      await WidgetsBinding.instance.endOfFrame;
    }
  }

  Future<void> _showVerseMenu(
    BuildContext anchorContext,
    Verse verse,
    String reference,
  ) async {
    final AppState state = context.read<AppState>();
    final RenderBox button = anchorContext.findRenderObject()! as RenderBox;
    final RenderBox overlay =
        Overlay.of(context).context.findRenderObject()! as RenderBox;
    final Offset topLeft = button.localToGlobal(Offset.zero, ancestor: overlay);
    final Rect target = topLeft & button.size;
    final MarkingGroup? active = state.activeGroup ?? state.groups.firstOrNull;
    final String? choice = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(target, Offset.zero & overlay.size),
      semanticLabel: 'Choose marking for $reference',
      items: <PopupMenuEntry<String>>[
        if (active != null)
          PopupMenuItem<String>(
            value: active.id,
            child: _GroupChoice(group: active),
          ),
        if (state.groups.length > 1)
          const PopupMenuItem<String>(
            value: '__groups__',
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.palette_outlined),
              title: Text('More marking groups…'),
            ),
          ),
        const PopupMenuDivider(),
        PopupMenuItem<String>(
          value: '__note__',
          child: Text(
            state.notes.any((VerseNote note) => note.verse == verse.verse)
                ? 'Edit note'
                : 'Add note',
          ),
        ),
        const PopupMenuItem<String>(
          value: '__share__',
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.share_outlined),
            title: Text('Copy or share Scripture'),
          ),
        ),
        if (state.markings.any(
          (Marking marking) =>
              marking.verse == verse.verse && marking.isWholeVerse,
        ))
          const PopupMenuItem<String>(
            value: '__none__',
            child: Text('Remove verse marking'),
          ),
      ],
    );
    if (choice == null || !mounted) return;
    if (choice == '__note__') {
      setState(() => _editingNote = verse.verse);
    } else if (choice == '__share__') {
      await showDialog<void>(
        context: context,
        builder: (BuildContext context) =>
            _ScriptureShareDialog(state: state, initialVerse: verse.verse),
      );
    } else if (choice == '__none__') {
      await state.removeWholeVerseMarking(verse.verse);
    } else if (choice == '__groups__') {
      final String? groupId = await _showMarkingGroupPicker(context, state);
      if (groupId != null) {
        await state.markWholeVerse(verse, reference, groupId);
      }
    } else {
      await state.markWholeVerse(verse, reference, choice);
    }
  }

  Future<String?> _showMarkingGroupPicker(
    BuildContext context,
    AppState state,
  ) => showDialog<String>(
    context: context,
    builder: (BuildContext context) =>
        _MarkingGroupPicker(groups: state.groups),
  );

  Future<void> _showSearch(BuildContext context, AppState state) async {
    await showDialog<void>(
      context: context,
      builder: (BuildContext context) => _SearchDialog(
        state: state,
        onOpen: (SearchVerse result) async {
          Navigator.of(context).pop();
          await state.loadPassage(
            Passage(
              translation: state.passage.translation,
              book: result.book,
              chapter: result.chapter,
              verse: result.verse,
            ),
          );
          await _scrollToVerse(result.verse);
        },
      ),
    );
  }
}

class _ReaderAppBar extends StatelessWidget implements PreferredSizeWidget {
  const _ReaderAppBar({
    required this.state,
    required this.onMenu,
    required this.onStudy,
    required this.onSearch,
    required this.onHome,
    required this.onTurn,
    required this.onMarkdown,
  });

  final AppState state;
  final VoidCallback onMenu;
  final VoidCallback onStudy;
  final VoidCallback onSearch;
  final VoidCallback onHome;
  final ValueChanged<int> onTurn;
  final VoidCallback onMarkdown;

  @override
  Size get preferredSize => const Size.fromHeight(62);

  @override
  Widget build(BuildContext context) {
    final bool compact = MediaQuery.sizeOf(context).width < 720;
    return AppBar(
      toolbarHeight: 62,
      leading: IconButton(
        tooltip: state.ui('openBibleNavigation'),
        onPressed: onMenu,
        icon: const Icon(Icons.menu),
      ),
      titleSpacing: 4,
      title: Row(
        children: <Widget>[
          Image.asset(
            'assets/branding/getbible_app_icon.png',
            width: 24,
            height: 24,
          ),
          const SizedBox(width: 8),
          InkWell(
            onTap: onHome,
            borderRadius: BorderRadius.circular(6),
            child: const Padding(
              padding: EdgeInsets.symmetric(horizontal: 2, vertical: 8),
              child: Text(
                'getBible.Life',
                style: TextStyle(fontWeight: FontWeight.w700, fontSize: 20),
              ),
            ),
          ),
          if (!compact) ...<Widget>[
            const SizedBox(width: 18),
            Expanded(
              child: InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: onSearch,
                child: IgnorePointer(
                  child: TextField(
                    decoration: const InputDecoration(
                      hintText: 'Search',
                      prefixIcon: Icon(Icons.search),
                      isDense: true,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
      actions: <Widget>[
        if (compact)
          IconButton(
            tooltip: state.ui('searchThisTranslation'),
            onPressed: onSearch,
            icon: const Icon(Icons.search),
          ),
        IconButton(
          tooltip: state.ui('previousChapter'),
          onPressed: state.canGoPrevious ? () => onTurn(-1) : null,
          icon: const Icon(Icons.chevron_left),
        ),
        IconButton(
          tooltip: state.ui('nextChapter'),
          onPressed: state.canGoNext ? () => onTurn(1) : null,
          icon: const Icon(Icons.chevron_right),
        ),
        IconButton(
          tooltip: state.ui('openAsMarkdown'),
          onPressed: state.current?.verses.isNotEmpty == true
              ? onMarkdown
              : null,
          icon: const Icon(Icons.menu_book_outlined),
        ),
        Padding(
          padding: const EdgeInsetsDirectional.only(end: 10),
          child: OutlinedButton(
            onPressed: onStudy,
            child: Text(state.ui('study')),
          ),
        ),
      ],
    );
  }
}

class _ChapterHeading extends StatelessWidget {
  const _ChapterHeading({required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    final BibleChapter chapter = state.current!;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 8),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              chapter.name,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
          const SizedBox(width: 12),
          Text(
            chapter.abbreviation.toUpperCase(),
            style: Theme.of(context).textTheme.labelSmall,
          ),
          const SizedBox(width: 12),
          ScriptureVerificationBadge(
            freshness: state.freshness ?? CacheFreshness.cachedUnverified,
          ),
        ],
      ),
    );
  }
}

class _ReaderBody extends StatelessWidget {
  const _ReaderBody({
    required this.state,
    required this.controller,
    required this.verseKeys,
    required this.editingNote,
    required this.onEditNote,
    required this.onOpenVerseMenu,
  });

  final AppState state;
  final ScrollController controller;
  final Map<int, GlobalKey> verseKeys;
  final int? editingNote;
  final ValueChanged<int?> onEditNote;
  final Future<void> Function(BuildContext, Verse, String) onOpenVerseMenu;

  @override
  Widget build(BuildContext context) {
    final BibleChapter chapter = state.current!;
    final double maximumWidth =
        state.preferences.readingWidth == ReadingWidth.constrained
        ? 920
        : double.infinity;
    if (state.preferences.layout == ReaderLayout.paragraph) {
      return Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maximumWidth),
          child: _ParagraphReader(
            state: state,
            controller: controller,
            verseKeys: verseKeys,
            onOpenVerseMenu: onOpenVerseMenu,
          ),
        ),
      );
    }
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maximumWidth),
        child: ListView.builder(
          controller: controller,
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(20, 10, 20, 32),
          itemCount: chapter.verses.length + 1,
          itemBuilder: (BuildContext context, int index) {
            if (index == chapter.verses.length) {
              return _ChapterFooter(state: state);
            }
            final Verse verse = chapter.verses[index];
            final GlobalKey key = verseKeys.putIfAbsent(
              verse.verse,
              GlobalKey.new,
            );
            final String reference =
                '${chapter.bookName} ${chapter.chapter}:${verse.verse}';
            final VerseNote? note = state.notes
                .where((VerseNote item) => item.verse == verse.verse)
                .firstOrNull;
            return _VerseLine(
              key: key,
              state: state,
              verse: verse,
              reference: reference,
              note: note,
              editing: editingNote == verse.verse,
              onEditNote: onEditNote,
              onOpenMenu: onOpenVerseMenu,
            );
          },
        ),
      ),
    );
  }
}

class _ParagraphReader extends StatelessWidget {
  const _ParagraphReader({
    required this.state,
    required this.controller,
    required this.verseKeys,
    required this.onOpenVerseMenu,
  });

  final AppState state;
  final ScrollController controller;
  final Map<int, GlobalKey> verseKeys;
  final Future<void> Function(BuildContext, Verse, String) onOpenVerseMenu;

  @override
  Widget build(BuildContext context) {
    final BibleChapter chapter = state.current!;
    final List<InlineSpan> content = <InlineSpan>[];
    for (final Verse verse in chapter.verses) {
      final String reference =
          '${chapter.bookName} ${chapter.chapter}:${verse.verse}';
      final Marking? whole = state.markings
          .where(
            (Marking item) => item.verse == verse.verse && item.isWholeVerse,
          )
          .firstOrNull;
      final MarkingGroup? group = whole == null
          ? null
          : state.groups
                .where((MarkingGroup item) => item.id == whole.groupId)
                .firstOrNull;
      content
        ..add(
          WidgetSpan(
            alignment: PlaceholderAlignment.middle,
            child: Builder(
              key: verseKeys.putIfAbsent(verse.verse, GlobalKey.new),
              builder: (BuildContext anchor) => InkWell(
                onTap: () => onOpenVerseMenu(anchor, verse, reference),
                child: Padding(
                  padding: const EdgeInsetsDirectional.only(
                    end: 6,
                    top: 5,
                    bottom: 5,
                  ),
                  child: Text(
                    '${verse.verse}',
                    style: TextStyle(
                      fontSize: state.preferences.textSize * .55,
                      fontWeight: FontWeight.bold,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                  ),
                ),
              ),
            ),
          ),
        )
        ..add(
          TextSpan(
            text: '${verse.text} ',
            style: TextStyle(
              backgroundColor: group == null
                  ? null
                  : _hexColor(group.color).withAlpha(45),
            ),
          ),
        );
    }
    return ListView(
      controller: controller,
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
      children: <Widget>[
        SelectableText.rich(
          TextSpan(
            style: TextStyle(
              fontFamily: _fontFamily(state.preferences.readerFont),
              fontSize: state.preferences.textSize,
              height: 1.55,
              color: Theme.of(context).colorScheme.onSurface,
            ),
            children: content,
          ),
        ),
        for (final VerseNote note in state.notes)
          _SavedNote(note: note, onTap: () {}),
        _ChapterFooter(state: state),
      ],
    );
  }
}

class _VerseLine extends StatelessWidget {
  const _VerseLine({
    super.key,
    required this.state,
    required this.verse,
    required this.reference,
    required this.note,
    required this.editing,
    required this.onEditNote,
    required this.onOpenMenu,
  });

  final AppState state;
  final Verse verse;
  final String reference;
  final VerseNote? note;
  final bool editing;
  final ValueChanged<int?> onEditNote;
  final Future<void> Function(BuildContext, Verse, String) onOpenMenu;

  @override
  Widget build(BuildContext context) {
    final Marking? whole = state.markings
        .where((Marking item) => item.verse == verse.verse && item.isWholeVerse)
        .firstOrNull;
    final MarkingGroup? wholeGroup = whole == null
        ? null
        : state.groups
              .where((MarkingGroup item) => item.id == whole.groupId)
              .firstOrNull;
    final Color? wholeColor = wholeGroup == null
        ? null
        : _hexColor(wholeGroup.color).withAlpha(45);
    return Semantics(
      label: '$reference. ${verse.text}',
      child: ColoredBox(
        color: wholeColor ?? Colors.transparent,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Builder(
                    builder: (BuildContext anchorContext) => InkWell(
                      onTap: () => onOpenMenu(anchorContext, verse, reference),
                      borderRadius: BorderRadius.circular(20),
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(
                          minWidth: 40,
                          minHeight: 36,
                        ),
                        child: Center(
                          child: Text(
                            '${verse.verse}',
                            style: TextStyle(
                              fontSize: state.preferences.textSize * 0.58,
                              fontWeight: FontWeight.bold,
                              color: Theme.of(context).colorScheme.primary,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  Expanded(
                    child: _SelectableMarkedVerse(
                      state: state,
                      verse: verse,
                      reference: reference,
                    ),
                  ),
                ],
              ),
              if (editing)
                _InlineNoteEditor(
                  state: state,
                  verse: verse.verse,
                  reference: reference,
                  note: note,
                  onClose: () => onEditNote(null),
                )
              else if (note != null)
                _SavedNote(note: note!, onTap: () => onEditNote(verse.verse)),
            ],
          ),
        ),
      ),
    );
  }
}

class _SelectableMarkedVerse extends StatelessWidget {
  const _SelectableMarkedVerse({
    required this.state,
    required this.verse,
    required this.reference,
  });

  final AppState state;
  final Verse verse;
  final String reference;

  @override
  Widget build(BuildContext context) {
    return SelectableText.rich(
      _markedText(context),
      contextMenuBuilder:
          (BuildContext context, EditableTextState editableTextState) {
            final TextSelection selection =
                editableTextState.textEditingValue.selection;
            final bool valid =
                selection.isValid &&
                !selection.isCollapsed &&
                selection.start >= 0 &&
                selection.end <= verse.text.length;
            final List<ContextMenuButtonItem> buttons = <ContextMenuButtonItem>[
              ...editableTextState.contextMenuButtonItems,
              if (valid && state.activeGroup != null)
                ContextMenuButtonItem(
                  label: 'Mark: ${state.activeGroup!.name}',
                  onPressed: () {
                    editableTextState.hideToolbar();
                    unawaited(
                      state.markSelectedText(
                        verse,
                        selection.start,
                        selection.end,
                        reference,
                        state.activeGroup!.id,
                      ),
                    );
                  },
                ),
              if (valid && state.groups.length > 1)
                ContextMenuButtonItem(
                  label: 'More marking groups…',
                  onPressed: () async {
                    editableTextState.hideToolbar();
                    final String? groupId = await showDialog<String>(
                      context: context,
                      builder: (BuildContext context) =>
                          _MarkingGroupPicker(groups: state.groups),
                    );
                    if (!context.mounted) return;
                    if (groupId != null) {
                      await state.markSelectedText(
                        verse,
                        selection.start,
                        selection.end,
                        reference,
                        groupId,
                      );
                    }
                  },
                ),
              if (valid &&
                  state.selectionHasMarking(
                    verse.verse,
                    selection.start,
                    selection.end,
                  ))
                ContextMenuButtonItem(
                  label: 'Remove highlighting',
                  onPressed: () {
                    editableTextState.hideToolbar();
                    unawaited(
                      state.removeSelectionMarkings(
                        verse.verse,
                        selection.start,
                        selection.end,
                      ),
                    );
                  },
                ),
            ];
            return AdaptiveTextSelectionToolbar.buttonItems(
              anchors: editableTextState.contextMenuAnchors,
              buttonItems: buttons,
            );
          },
    );
  }

  TextSpan _markedText(BuildContext context) {
    final List<Marking> ranged =
        state.markings
            .where(
              (Marking item) =>
                  item.verse == verse.verse &&
                  !item.isWholeVerse &&
                  item.start! >= 0 &&
                  item.end! <= verse.text.length,
            )
            .toList()
          ..sort(
            (Marking left, Marking right) =>
                left.start!.compareTo(right.start!),
          );
    final Set<int> boundaries = <int>{0, verse.text.length};
    for (final Marking marking in ranged) {
      boundaries.add(marking.start!);
      boundaries.add(marking.end!);
    }
    final List<int> offsets = boundaries.toList()..sort();
    final List<InlineSpan> spans = <InlineSpan>[];
    for (int index = 0; index < offsets.length - 1; index++) {
      final int start = offsets[index];
      final int end = offsets[index + 1];
      final Marking? marking = ranged.reversed
          .where((Marking item) => item.start! <= start && item.end! >= end)
          .firstOrNull;
      final MarkingGroup? group = marking == null
          ? null
          : state.groups
                .where((MarkingGroup item) => item.id == marking.groupId)
                .firstOrNull;
      spans.add(
        TextSpan(
          text: verse.text.substring(start, end),
          style: TextStyle(
            backgroundColor: group == null ? null : _hexColor(group.color),
          ),
        ),
      );
    }
    return TextSpan(
      style: TextStyle(
        fontFamily: _fontFamily(state.preferences.readerFont),
        fontSize: state.preferences.textSize,
        height: 1.38,
        color: Theme.of(context).colorScheme.onSurface,
      ),
      children: spans,
    );
  }
}

class _InlineNoteEditor extends StatefulWidget {
  const _InlineNoteEditor({
    required this.state,
    required this.verse,
    required this.reference,
    required this.note,
    required this.onClose,
  });

  final AppState state;
  final int verse;
  final String reference;
  final VerseNote? note;
  final VoidCallback onClose;

  @override
  State<_InlineNoteEditor> createState() => _InlineNoteEditorState();
}

class _InlineNoteEditorState extends State<_InlineNoteEditor> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.note?.text ?? '',
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsetsDirectional.fromSTEB(44, 8, 0, 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    widget.reference,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
                IconButton(
                  tooltip: 'Close note editor',
                  onPressed: widget.onClose,
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
            TextField(
              controller: _controller,
              autofocus: true,
              minLines: 3,
              maxLines: 8,
              decoration: const InputDecoration(hintText: 'Write your note…'),
              onSubmitted: (_) => _save(),
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: <Widget>[
                if (widget.note != null)
                  IconButton(
                    tooltip: 'Delete note',
                    onPressed: () async {
                      await widget.state.deleteVerseNote(widget.verse);
                      widget.onClose();
                    },
                    icon: const Icon(Icons.delete_outline),
                  ),
                FilledButton.icon(
                  onPressed: _save,
                  icon: const Icon(Icons.check),
                  label: const Text('Save note'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _save() async {
    if (_controller.text.trim().isEmpty) return;
    await widget.state.saveVerseNote(
      widget.verse,
      widget.reference,
      _controller.text,
    );
    widget.onClose();
  }
}

class _SavedNote extends StatelessWidget {
  const _SavedNote({required this.note, required this.onTap});

  final VerseNote note;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsetsDirectional.fromSTEB(44, 4, 0, 4),
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('NOTE', style: Theme.of(context).textTheme.labelSmall),
            const SizedBox(height: 3),
            Text(note.text, maxLines: 3, overflow: TextOverflow.ellipsis),
          ],
        ),
      ),
    ),
  );
}

class _StudyDrawer extends StatefulWidget {
  const _StudyDrawer({required this.state, required this.onOpenPassage});

  final AppState state;
  final ValueChanged<Passage> onOpenPassage;

  @override
  State<_StudyDrawer> createState() => _StudyDrawerState();
}

class _StudyDrawerState extends State<_StudyDrawer> {
  int _tab = 0;
  String? _selectedGroup;
  String _groupQuery = '';

  @override
  Widget build(BuildContext context) {
    final AppState state = widget.state;
    final double screenWidth = MediaQuery.sizeOf(context).width;
    final double drawerWidth = screenWidth <= 720
        ? (screenWidth - 24).clamp(300, 480).toDouble()
        : (screenWidth * 0.48).clamp(430, 680).toDouble();
    return Drawer(
      width: drawerWidth,
      child: SafeArea(
        child: Column(
          children: <Widget>[
            ListTile(
              title: const Text(
                'Study tools',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
              trailing: IconButton(
                tooltip: 'Close Study tools',
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.close),
              ),
            ),
            SegmentedButton<int>(
              segments: const <ButtonSegment<int>>[
                ButtonSegment<int>(value: 0, label: Text('Markings')),
                ButtonSegment<int>(value: 1, label: Text('Notes')),
              ],
              selected: <int>{_tab},
              onSelectionChanged: (Set<int> value) =>
                  setState(() => _tab = value.first),
            ),
            const Divider(),
            Expanded(child: _tab == 0 ? _markings(state) : _notes(state)),
            if (_tab == 0)
              Padding(
                padding: const EdgeInsets.all(12),
                child: OutlinedButton.icon(
                  onPressed: () => showDialog<void>(
                    context: context,
                    builder: (BuildContext context) =>
                        _ManageGroupsDialog(state: state),
                  ),
                  icon: const Icon(Icons.palette_outlined),
                  label: const Text('Manage groups'),
                ),
              ),
          ],
        ),
      ),
    );
  }

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
      return Column(
        children: <Widget>[
          ListTile(
            leading: const Icon(Icons.arrow_back),
            title: Text(group?.name ?? 'Markings'),
            onTap: () => setState(() => _selectedGroup = null),
          ),
          Expanded(
            child: items.isEmpty
                ? const Center(child: Text('No markings in this group yet.'))
                : ListView.builder(
                    itemCount: items.length,
                    itemBuilder: (BuildContext context, int index) {
                      final Marking marking = items[index];
                      return ListTile(
                        title: Text(marking.reference),
                        subtitle: Text(
                          marking.quote,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        onTap: () => widget.onOpenPassage(
                          Passage(
                            translation: state.passage.translation,
                            book: marking.passage.book,
                            chapter: marking.passage.chapter,
                            verse: marking.verse,
                          ),
                        ),
                        trailing: Wrap(
                          spacing: 0,
                          children: <Widget>[
                            IconButton(
                              tooltip: 'Open ${marking.reference}',
                              icon: const Icon(Icons.open_in_new, size: 20),
                              onPressed: () => widget.onOpenPassage(
                                Passage(
                                  translation: state.passage.translation,
                                  book: marking.passage.book,
                                  chapter: marking.passage.chapter,
                                  verse: marking.verse,
                                ),
                              ),
                            ),
                            IconButton(
                              tooltip: 'Delete marking at ${marking.reference}',
                              icon: const Icon(Icons.delete_outline, size: 20),
                              onPressed: () => _deleteMarking(state, marking),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
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
    return Column(
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
          child: TextField(
            decoration: const InputDecoration(
              hintText: 'Find a marking group',
              prefixIcon: Icon(Icons.search),
              isDense: true,
            ),
            onChanged: (String value) => setState(() => _groupQuery = value),
          ),
        ),
        Expanded(
          child: GridView.builder(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 220,
              mainAxisExtent: 82,
              crossAxisSpacing: 10,
              mainAxisSpacing: 10,
            ),
            itemCount: visible.length,
            itemBuilder: (BuildContext context, int index) {
              final MarkingGroup group = visible[index];
              final int count = state.savedMarkings
                  .where((Marking item) => item.groupId == group.id)
                  .length;
              final bool selected =
                  state.preferences.activeMarkingGroupId == group.id;
              return Card(
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
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              Text(
                                group.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              Text(
                                '$count ${count == 1 ? 'marking' : 'markings'}',
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                            ],
                          ),
                        ),
                        if (selected) const Icon(Icons.check_circle, size: 18),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Future<void> _deleteMarking(AppState state, Marking marking) async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
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
      return const Center(
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

  @override
  void dispose() {
    _name.dispose();
    _color.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Marking groups'),
      content: SizedBox(
        width: 520,
        height: MediaQuery.sizeOf(context).height * 0.7,
        child: Column(
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(
                  child: TextField(
                    controller: _name,
                    decoration: const InputDecoration(labelText: 'Group name'),
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 116,
                  child: TextField(
                    controller: _color,
                    decoration: const InputDecoration(labelText: 'Color'),
                  ),
                ),
                IconButton(
                  tooltip: _editingId == null ? 'Add group' : 'Save group',
                  onPressed: _save,
                  icon: Icon(_editingId == null ? Icons.add : Icons.check),
                ),
              ],
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            const Divider(height: 24),
            Expanded(
              child: AnimatedBuilder(
                animation: widget.state,
                builder: (BuildContext context, Widget? child) =>
                    ListView.builder(
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
                          onTap: () => setState(() {
                            _editingId = group.id;
                            _name.text = group.name;
                            _color.text = group.color;
                            _error = null;
                          }),
                          trailing: IconButton(
                            tooltip: 'Delete ${group.name}',
                            onPressed: widget.state.groups.length <= 1
                                ? null
                                : () => _delete(group),
                            icon: const Icon(Icons.delete_outline),
                          ),
                        );
                      },
                    ),
              ),
            ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }

  Future<void> _save() async {
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
    } on FormatException catch (error) {
      setState(() => _error = error.toString());
    }
  }

  Future<void> _delete(MarkingGroup group) async {
    final int count = widget.state.savedMarkings
        .where((Marking item) => item.groupId == group.id)
        .length;
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
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

class _SearchDialog extends StatefulWidget {
  const _SearchDialog({required this.state, required this.onOpen});

  final AppState state;
  final ValueChanged<SearchVerse> onOpen;

  @override
  State<_SearchDialog> createState() => _SearchDialogState();
}

class _SearchDialogState extends State<_SearchDialog> {
  final TextEditingController _query = TextEditingController();
  SearchWordMode _words = SearchWordMode.all;
  SearchMatchMode _match = SearchMatchMode.exact;
  SearchScope _scope = const SearchScope.all();
  bool _caseSensitive = false;
  bool _hasSearched = false;

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Dialog.fullscreen(
      child: SafeArea(
        child: Column(
          children: <Widget>[
            AppBar(
              leading: IconButton(
                tooltip: 'Close search',
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.close),
              ),
              title: Text(
                'Search ${widget.state.current?.abbreviation.toUpperCase() ?? ''}',
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: <Widget>[
                  TextField(
                    controller: _query,
                    autofocus: true,
                    textInputAction: TextInputAction.search,
                    decoration: InputDecoration(
                      hintText: 'Search the Bible',
                      suffixIcon: IconButton(
                        tooltip: 'Search',
                        onPressed: _search,
                        icon: const Icon(Icons.search),
                      ),
                    ),
                    onSubmitted: (_) => _search(),
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: <Widget>[
                      DropdownButton<SearchWordMode>(
                        value: _words,
                        items: const <DropdownMenuItem<SearchWordMode>>[
                          DropdownMenuItem(
                            value: SearchWordMode.all,
                            child: Text('All words'),
                          ),
                          DropdownMenuItem(
                            value: SearchWordMode.any,
                            child: Text('Any word'),
                          ),
                          DropdownMenuItem(
                            value: SearchWordMode.phrase,
                            child: Text('Exact phrase'),
                          ),
                        ],
                        onChanged: (SearchWordMode? value) =>
                            setState(() => _words = value ?? _words),
                      ),
                      DropdownButton<SearchMatchMode>(
                        value: _match,
                        items: const <DropdownMenuItem<SearchMatchMode>>[
                          DropdownMenuItem(
                            value: SearchMatchMode.exact,
                            child: Text('Exact word'),
                          ),
                          DropdownMenuItem(
                            value: SearchMatchMode.partial,
                            child: Text('Partial word'),
                          ),
                        ],
                        onChanged: (SearchMatchMode? value) =>
                            setState(() => _match = value ?? _match),
                      ),
                      DropdownButton<SearchScope>(
                        value: _scope,
                        items: <DropdownMenuItem<SearchScope>>[
                          const DropdownMenuItem(
                            value: SearchScope.all(),
                            child: Text('Whole Bible'),
                          ),
                          const DropdownMenuItem(
                            value: SearchScope.oldTestament(),
                            child: Text('Old Testament'),
                          ),
                          const DropdownMenuItem(
                            value: SearchScope.newTestament(),
                            child: Text('New Testament'),
                          ),
                          for (final BibleBook book in widget.state.books)
                            DropdownMenuItem(
                              value: SearchScope.book(book.number),
                              child: Text(book.name),
                            ),
                        ],
                        onChanged: (SearchScope? value) =>
                            setState(() => _scope = value ?? _scope),
                      ),
                      FilterChip(
                        label: const Text('Case sensitive'),
                        selected: _caseSensitive,
                        onSelected: (bool value) =>
                            setState(() => _caseSensitive = value),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            Expanded(
              child: AnimatedBuilder(
                animation: widget.state,
                builder: (BuildContext context, Widget? child) {
                  if (widget.state.searchLoading) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  if (widget.state.searchError != null) {
                    return Center(child: Text(widget.state.searchError!));
                  }
                  if (_hasSearched && widget.state.searchResultCount == 0) {
                    return const Center(
                      child: Text('0 results. Try a different search.'),
                    );
                  }
                  if (widget.state.searchResults.isEmpty) {
                    return const Center(child: Text('Enter a search above.'));
                  }
                  return Column(
                    children: <Widget>[
                      Padding(
                        padding: const EdgeInsets.fromLTRB(18, 4, 18, 8),
                        child: Align(
                          alignment: AlignmentDirectional.centerStart,
                          child: Text(
                            '${widget.state.searchResultCount} ${widget.state.searchResultCount == 1 ? 'result' : 'results'}',
                            style: Theme.of(context).textTheme.labelLarge,
                          ),
                        ),
                      ),
                      Expanded(
                        child: NotificationListener<ScrollNotification>(
                          onNotification: (ScrollNotification notice) {
                            if (notice.metrics.extentAfter < 240) {
                              widget.state.loadMoreSearchResults();
                            }
                            return false;
                          },
                          child: ListView.builder(
                            itemCount:
                                widget.state.searchResults.length +
                                (widget.state.searchComplete ? 0 : 1),
                            itemBuilder: (BuildContext context, int index) {
                              if (index == widget.state.searchResults.length) {
                                return const Padding(
                                  padding: EdgeInsets.all(20),
                                  child: Center(
                                    child: CircularProgressIndicator(),
                                  ),
                                );
                              }
                              final SearchVerse result =
                                  widget.state.searchResults[index];
                              return ListTile(
                                title: Text(result.reference),
                                subtitle: Text(result.text),
                                onTap: () => widget.onOpen(result),
                              );
                            },
                          ),
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _search() {
    if (_query.text.trim().isEmpty) return;
    setState(() => _hasSearched = true);
    unawaited(
      widget.state.search(
        _query.text,
        SearchOptions(
          words: _words,
          match: _match,
          caseSensitive: _caseSensitive,
          scope: _scope,
          locale: widget.state.currentTranslation?.lang ?? 'und',
        ),
      ),
    );
  }
}

class _ReaderDrawer extends StatelessWidget {
  const _ReaderDrawer({required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) => Drawer(
    child: SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          Text(
            state.ui('readerOptions'),
            style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 18),
          ReaderTranslationField(
            value: state.passage.translation,
            translations: state.translations,
            onChanged: (String? value) {
              if (value != null) {
                unawaited(
                  state.loadPassage(
                    Passage(
                      translation: value,
                      book: state.passage.book,
                      chapter: state.passage.chapter,
                    ),
                  ),
                );
              }
            },
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<int>(
            key: ValueKey<int>(state.passage.book),
            initialValue: state.passage.book,
            decoration: InputDecoration(labelText: state.ui('book')),
            items: state.books
                .map(
                  (BibleBook item) => DropdownMenuItem(
                    value: item.number,
                    child: Text(item.name),
                  ),
                )
                .toList(),
            onChanged: (int? value) {
              if (value != null) unawaited(state.openBook(value));
            },
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<int>(
            key: ValueKey<String>(
              'chapter-${state.passage.book}-${state.passage.chapter}',
            ),
            initialValue: state.passage.chapter,
            decoration: InputDecoration(labelText: state.ui('chapter')),
            items: state.chapters
                .map(
                  (ChapterInfo item) => DropdownMenuItem(
                    value: item.chapter,
                    child: Text(
                      item.isIntroduction ? 'Introduction' : '${item.chapter}',
                    ),
                  ),
                )
                .toList(),
            onChanged: (int? value) {
              if (value != null) {
                unawaited(
                  state.loadPassage(
                    state.passage.copyWith(chapter: value, clearVerse: true),
                  ),
                );
              }
            },
          ),
          const Divider(height: 32),
          const Text(
            'Appearance',
            style: TextStyle(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          SegmentedButton<AppearanceMode>(
            segments: AppearanceMode.values
                .map(
                  (AppearanceMode value) =>
                      ButtonSegment(value: value, label: Text(value.name)),
                )
                .toList(),
            selected: <AppearanceMode>{state.preferences.appearanceMode},
            onSelectionChanged: (Set<AppearanceMode> value) =>
                unawaited(state.setAppearance(value.first)),
          ),
          const SizedBox(height: 16),
          Text(state.ui('textSize')),
          Slider(
            min: 16,
            max: 36,
            divisions: 20,
            value: state.preferences.textSize,
            label: '${state.preferences.textSize.round()}',
            onChanged: (double value) => unawaited(state.setTextSize(value)),
          ),
          SegmentedButton<ReaderLayout>(
            segments: <ButtonSegment<ReaderLayout>>[
              ButtonSegment(
                value: ReaderLayout.lines,
                label: Text(state.ui('oneVersePerLine')),
              ),
              ButtonSegment(
                value: ReaderLayout.paragraph,
                label: Text(state.ui('continuousParagraph')),
              ),
            ],
            selected: <ReaderLayout>{state.preferences.layout},
            onSelectionChanged: (Set<ReaderLayout> value) =>
                unawaited(state.setLayout(value.first)),
          ),
          const SizedBox(height: 16),
          DropdownButtonFormField<String>(
            key: ValueKey<String>('light-${state.preferences.lightPalette}'),
            initialValue: state.preferences.lightPalette,
            decoration: const InputDecoration(
              labelText: 'Light reading palette',
            ),
            items: const <DropdownMenuItem<String>>[
              DropdownMenuItem(value: 'white', child: Text('Pure white')),
              DropdownMenuItem(value: 'paper', child: Text('Warm paper')),
              DropdownMenuItem(value: 'ivory', child: Text('Soft ivory')),
              DropdownMenuItem(value: 'mist', child: Text('Cool mist')),
            ],
            onChanged: (String? value) {
              if (value != null) unawaited(state.setLightPalette(value));
            },
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            key: ValueKey<String>('dark-${state.preferences.darkPalette}'),
            initialValue: state.preferences.darkPalette,
            decoration: const InputDecoration(
              labelText: 'Dark reading palette',
            ),
            items: const <DropdownMenuItem<String>>[
              DropdownMenuItem(value: 'black', child: Text('Pure black')),
              DropdownMenuItem(value: 'brown', child: Text('Warm brown')),
              DropdownMenuItem(value: 'charcoal', child: Text('Soft charcoal')),
              DropdownMenuItem(value: 'navy', child: Text('Midnight blue')),
            ],
            onChanged: (String? value) {
              if (value != null) unawaited(state.setDarkPalette(value));
            },
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            key: ValueKey<String>('font-${state.preferences.readerFont}'),
            initialValue: state.preferences.readerFont,
            decoration: InputDecoration(labelText: state.ui('readingFont')),
            items: const <DropdownMenuItem<String>>[
              DropdownMenuItem(value: 'serif', child: Text('Classic serif')),
              DropdownMenuItem(value: 'book', child: Text('Book serif')),
              DropdownMenuItem(
                value: 'baskerville',
                child: Text('Baskerville'),
              ),
              DropdownMenuItem(value: 'garamond', child: Text('Garamond')),
              DropdownMenuItem(value: 'charter', child: Text('Charter')),
              DropdownMenuItem(value: 'cambria', child: Text('Cambria')),
              DropdownMenuItem(value: 'times', child: Text('Times New Roman')),
              DropdownMenuItem(value: 'sans', child: Text('Clean sans')),
              DropdownMenuItem(value: 'system', child: Text('System sans')),
            ],
            onChanged: (String? value) {
              if (value != null) unawaited(state.setReaderFont(value));
            },
          ),
          const SizedBox(height: 12),
          SegmentedButton<ReadingWidth>(
            segments: <ButtonSegment<ReadingWidth>>[
              ButtonSegment(
                value: ReadingWidth.full,
                label: Text(state.ui('fullScreenWidth')),
              ),
              ButtonSegment(
                value: ReadingWidth.constrained,
                label: Text(state.ui('page')),
              ),
            ],
            selected: <ReadingWidth>{state.preferences.readingWidth},
            onSelectionChanged: (Set<ReadingWidth> value) =>
                unawaited(state.setReadingWidth(value.first)),
          ),
        ],
      ),
    ),
  );
}

class _MobileChapterNavigation extends StatelessWidget {
  const _MobileChapterNavigation({required this.state, required this.onTurn});

  final AppState state;
  final Future<void> Function(AppState, int) onTurn;

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.sizeOf(context).width > 720) return const SizedBox.shrink();
    return Material(
      elevation: 3,
      child: Row(
        children: <Widget>[
          Expanded(
            child: TextButton(
              onPressed: state.canGoPrevious ? () => onTurn(state, -1) : null,
              child: const Text('Previous'),
            ),
          ),
          Expanded(
            child: Text(
              state.current?.name ?? '',
              textAlign: TextAlign.center,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Expanded(
            child: TextButton(
              onPressed: state.canGoNext ? () => onTurn(state, 1) : null,
              child: const Text('Next'),
            ),
          ),
        ],
      ),
    );
  }
}

class _EdgeChapterNavigation extends StatelessWidget {
  const _EdgeChapterNavigation({required this.state, required this.onTurn});

  final AppState state;
  final Future<void> Function(AppState, int) onTurn;

  @override
  Widget build(BuildContext context) => Positioned.fill(
    child: IgnorePointer(
      ignoring: false,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: <Widget>[
          _EdgeButton(
            tooltip: state.ui('previousChapter'),
            icon: Icons.chevron_left,
            enabled: state.canGoPrevious,
            onPressed: () => onTurn(state, -1),
          ),
          _EdgeButton(
            tooltip: state.ui('nextChapter'),
            icon: Icons.chevron_right,
            enabled: state.canGoNext,
            onPressed: () => onTurn(state, 1),
          ),
        ],
      ),
    ),
  );
}

class _EdgeButton extends StatelessWidget {
  const _EdgeButton({
    required this.tooltip,
    required this.icon,
    required this.enabled,
    required this.onPressed,
  });

  final String tooltip;
  final IconData icon;
  final bool enabled;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.center,
    child: Material(
      color: Theme.of(context).colorScheme.surface.withAlpha(205),
      borderRadius: BorderRadius.circular(6),
      child: IconButton(
        tooltip: tooltip,
        onPressed: enabled ? onPressed : null,
        icon: Icon(icon),
      ),
    ),
  );
}

class _ChapterFooter extends StatelessWidget {
  const _ChapterFooter({required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    final Translation? translation = state.currentTranslation;
    return Padding(
      padding: const EdgeInsets.only(top: 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Divider(),
          TextButton.icon(
            style: TextButton.styleFrom(padding: EdgeInsets.zero),
            onPressed: translation == null
                ? null
                : () => _showTranslationDetails(context, translation),
            icon: const Icon(Icons.menu_book_outlined, size: 18),
            label: Text(
              translation?.translation ?? state.current?.translation ?? '',
            ),
          ),
          const SizedBox(height: 18),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: <Widget>[
              Expanded(
                child: TextButton(
                  style: TextButton.styleFrom(
                    alignment: AlignmentDirectional.centerStart,
                    padding: EdgeInsets.zero,
                  ),
                  onPressed: () =>
                      launchUrl(Uri.parse('https://getbible.life')),
                  child: Text(
                    'getBible.Life — ${state.ui('wordsOfEternalLife')}',
                  ),
                ),
              ),
              Expanded(
                child: TextButton(
                  style: TextButton.styleFrom(
                    alignment: AlignmentDirectional.centerEnd,
                    padding: EdgeInsets.zero,
                  ),
                  onPressed: () => launchUrl(
                    Uri.parse('https://wiki.crosswire.org/Frontends:getBible'),
                  ),
                  child: Text(
                    '${state.ui('lovinglyMaintainedBy')} Vast Development Method ♥',
                    textAlign: TextAlign.end,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ScriptureShareDialog extends StatefulWidget {
  const _ScriptureShareDialog({
    required this.state,
    required this.initialVerse,
  });

  final AppState state;
  final int? initialVerse;

  @override
  State<_ScriptureShareDialog> createState() => _ScriptureShareDialogState();
}

class _ScriptureShareDialogState extends State<_ScriptureShareDialog> {
  late int _first;
  late int _last;
  bool _markdown = false;
  bool _copied = false;

  BibleChapter get _chapter => widget.state.current!;
  Translation get _translation => widget.state.currentTranslation!;

  @override
  void initState() {
    super.initState();
    final int selected = widget.initialVerse == null
        ? 0
        : _chapter.verses.indexWhere(
            (Verse verse) => verse.verse == widget.initialVerse,
          );
    _first = selected < 0 ? 0 : selected;
    _last = widget.initialVerse == null ? _chapter.verses.length - 1 : _first;
  }

  String get _plainText {
    final List<Verse> verses = _chapter.verses.sublist(_first, _last + 1);
    final String reference = verses.length == 1
        ? '${_chapter.bookName} ${_chapter.chapter}:${verses.first.verse}'
        : '${_chapter.bookName} ${_chapter.chapter}:${verses.first.verse}\u2013${verses.last.verse}';
    return '${verses.map((Verse verse) => '${verse.verse}. ${verse.text}').join('\n')}\n\n$reference \u2014 ${_translation.translation}\nhttps://getbible.life/${_translation.abbreviation.toUpperCase()}/${Uri.encodeComponent(_chapter.bookName)}/${_chapter.chapter}?verse=${verses.first.verse}';
  }

  String get _value => _markdown
      ? scriptureMarkdown(_chapter, _translation, _first, _last)
      : _plainText;

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(
      widget.initialVerse == null
          ? widget.state.ui('openAsMarkdown')
          : 'Copy or share Scripture',
    ),
    content: SizedBox(
      width: 640,
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            SegmentedButton<bool>(
              segments: const <ButtonSegment<bool>>[
                ButtonSegment(value: false, label: Text('Share text')),
                ButtonSegment(value: true, label: Text('Markdown')),
              ],
              selected: <bool>{_markdown},
              onSelectionChanged: (Set<bool> value) =>
                  setState(() => _markdown = value.first),
            ),
            const SizedBox(height: 14),
            if (_chapter.verses.length > 1) ...<Widget>[
              Text(
                'Verses ${_chapter.verses[_first].verse}\u2013${_chapter.verses[_last].verse}',
                textAlign: TextAlign.center,
              ),
              RangeSlider(
                min: 0,
                max: (_chapter.verses.length - 1).toDouble(),
                divisions: _chapter.verses.length - 1,
                labels: RangeLabels(
                  '${_chapter.verses[_first].verse}',
                  '${_chapter.verses[_last].verse}',
                ),
                values: RangeValues(_first.toDouble(), _last.toDouble()),
                onChanged: (RangeValues value) => setState(() {
                  _first = value.start.round();
                  _last = value.end.round();
                  _copied = false;
                }),
              ),
            ],
            Container(
              constraints: const BoxConstraints(maxHeight: 330),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                border: Border.all(
                  color: Theme.of(context).colorScheme.outlineVariant,
                ),
                borderRadius: BorderRadius.circular(8),
              ),
              child: SingleChildScrollView(child: SelectableText(_value)),
            ),
            if (_copied)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text('Copied to clipboard.', textAlign: TextAlign.end),
              ),
          ],
        ),
      ),
    ),
    actions: <Widget>[
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: Text(widget.state.ui('cancel')),
      ),
      FilledButton.icon(
        onPressed: () async {
          await Clipboard.setData(ClipboardData(text: _value));
          if (mounted) setState(() => _copied = true);
        },
        icon: const Icon(Icons.copy),
        label: Text(widget.state.ui('copy')),
      ),
    ],
  );
}

Future<void> _showTranslationDetails(
  BuildContext context,
  Translation translation,
) {
  final List<(String, String)> details = <(String, String)>[
    ('Language', translation.resolvedLanguage),
    ('Abbreviation', translation.abbreviation.toUpperCase()),
    ('Version', translation.distributionVersion),
    ('Version date', translation.distributionVersionDate),
    ('Description', translation.description),
    ('About', translation.distributionAbout),
    ('License and copyright', translation.distributionLicense),
    ('Source type', translation.distributionSourceType),
    ('Source', translation.distributionSource),
    ('Versification', translation.distributionVersification),
    ('Catalog subject', translation.distributionLcsh),
    for (final MapEntry<String, String> item
        in translation.distributionHistory.entries)
      ('History — ${item.key}', item.value),
  ].where(((String, String) item) => item.$2.trim().isNotEmpty).toList();
  return showDialog<void>(
    context: context,
    builder: (BuildContext context) => AlertDialog(
      title: Text(translation.translation),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 620),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              for (final (String label, String value) in details) ...<Widget>[
                Text(label, style: Theme.of(context).textTheme.labelLarge),
                const SizedBox(height: 3),
                SelectableText(value),
                const SizedBox(height: 16),
              ],
            ],
          ),
        ),
      ),
      actions: <Widget>[
        if (translation.url.trim().isNotEmpty)
          TextButton.icon(
            onPressed: () => unawaited(launchUrl(Uri.parse(translation.url))),
            icon: const Icon(Icons.open_in_new),
            label: const Text('Translation source'),
          ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    ),
  );
}

class _MarkingGroupPicker extends StatefulWidget {
  const _MarkingGroupPicker({required this.groups});

  final List<MarkingGroup> groups;

  @override
  State<_MarkingGroupPicker> createState() => _MarkingGroupPickerState();
}

class _MarkingGroupPickerState extends State<_MarkingGroupPicker> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final String query = _query.trim().toLowerCase();
    final List<MarkingGroup> groups = widget.groups
        .where(
          (MarkingGroup group) =>
              query.isEmpty || group.name.toLowerCase().contains(query),
        )
        .toList(growable: false);
    return AlertDialog(
      title: const Text('Choose a marking'),
      content: SizedBox(
        width: 560,
        height: (MediaQuery.sizeOf(context).height * 0.65)
            .clamp(320, 560)
            .toDouble(),
        child: Column(
          children: <Widget>[
            TextField(
              autofocus: true,
              decoration: const InputDecoration(
                hintText: 'Find a marking group',
                prefixIcon: Icon(Icons.search),
              ),
              onChanged: (String value) => setState(() => _query = value),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: GridView.builder(
                gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: 190,
                  mainAxisExtent: 58,
                  crossAxisSpacing: 8,
                  mainAxisSpacing: 8,
                ),
                itemCount: groups.length,
                itemBuilder: (BuildContext context, int index) {
                  final MarkingGroup group = groups[index];
                  return Material(
                    color: Theme.of(
                      context,
                    ).colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(8),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(8),
                      onTap: () => Navigator.of(context).pop(group.id),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        child: _GroupChoice(group: group),
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
      ],
    );
  }
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          const Icon(Icons.cloud_off, size: 48),
          const SizedBox(height: 16),
          Text(state.error!, textAlign: TextAlign.center),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: () => state.loadPassage(state.passage),
            child: const Text('Retry'),
          ),
        ],
      ),
    ),
  );
}

class _GroupChoice extends StatelessWidget {
  const _GroupChoice({required this.group});

  final MarkingGroup group;

  @override
  Widget build(BuildContext context) => Row(
    children: <Widget>[
      Container(
        width: 18,
        height: 18,
        decoration: BoxDecoration(
          color: _hexColor(group.color),
          shape: BoxShape.circle,
        ),
      ),
      const SizedBox(width: 10),
      Expanded(child: Text(group.name)),
    ],
  );
}

class CacheStatusNotice extends StatelessWidget {
  const CacheStatusNotice({required this.freshness, super.key})
    : assert(freshness != CacheFreshness.fresh);

  final CacheFreshness freshness;

  @override
  Widget build(BuildContext context) {
    final bool verified = freshness == CacheFreshness.cachedVerified;
    final String message = verified
        ? 'Verified cached Scripture'
        : 'Offline cached Scripture — verification unavailable';
    final ColorScheme colors = Theme.of(context).colorScheme;
    return Semantics(
      container: true,
      liveRegion: true,
      label: message,
      child: ColoredBox(
        color: colors.surfaceContainerHighest,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: <Widget>[
              Container(
                width: 4,
                height: 22,
                decoration: BoxDecoration(
                  color: verified ? colors.primary : colors.error,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  message,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

Color _hexColor(String value) {
  final String normalized = value.replaceFirst('#', '');
  return Color(int.parse('FF$normalized', radix: 16));
}

String? _fontFamily(String value) => switch (value) {
  'serif' => 'serif',
  'book' => 'Georgia',
  'baskerville' => 'Baskerville',
  'garamond' => 'Garamond',
  'charter' => 'Charter',
  'cambria' => 'Cambria',
  'times' => 'Times New Roman',
  'sans' => 'Arial',
  _ => null,
};
