import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../application/app_state.dart';
import '../application/reference_preview_controller.dart';
import '../domain/models/annotations.dart';
import '../domain/models/bible.dart';
import '../domain/models/cache.dart';
import '../domain/models/online_search.dart';
import '../domain/models/passage.dart';
import '../domain/models/reference.dart';
import '../domain/models/search.dart';
import '../domain/models/study_context.dart';
import '../services/markdown_service.dart';
import '../services/scripture_layout.dart';
import '../services/scripture_text.dart';
import '../services/search_match_emphasis.dart';
import 'boundary_turn_controller.dart';
import 'widgets/commentary_panel.dart';
import 'widgets/dictionary_panel.dart';
import 'widgets/my_annotations_panel.dart';
import 'widgets/native_scripture_text.dart';
import 'widgets/notes_panel.dart';
import 'widgets/reader_translation_field.dart';
import 'widgets/reference_preview.dart';
import 'widgets/scripture_editorial.dart';
import 'widgets/scripture_paragraph_selection.dart';
import 'widgets/scripture_study_actions.dart';
import 'widgets/scripture_verification_badge.dart';
import 'widgets/scripture_verse_text.dart';
import 'widgets/search_panel.dart';
import 'widgets/study_workspace.dart';
import 'widgets/topics_panel.dart';

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
  bool _openingDaily = false;
  bool _previewOpen = false;
  BibleChapter? _arrivalChapter;
  int? _arrivalVerse;
  List<ScriptureTextEmphasis> _arrivalEmphasis =
      const <ScriptureTextEmphasis>[];
  StudyContext? _studyContext;
  StudyTab _studyTab = StudyTab.markings;
  bool _studyModal = false;
  bool _compactStudyScheduled = false;
  FocusNode? _readerFocusBeforeStudy;

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
    return PopScope<void>(
      canPop: _studyContext == null || _studyModal,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop && _studyContext != null && !_studyModal) _closeStudy();
      },
      child: Scaffold(
        key: _scaffoldKey,
        drawer: _ReaderDrawer(
          state: state,
          onReferencePreview: _showReferencePreview,
          navigationEnabled: _editingNote == null && !_openingDaily,
        ),

        appBar: _showChrome
            ? _ReaderAppBar(
                state: state,
                onMenu: () => _scaffoldKey.currentState?.openDrawer(),
                onStudy: () => _openStudy(),
                onSearch: () => _showSearch(context, state),
                onHome: () => unawaited(_openDaily(state)),
                onTurn: (int direction) => unawaited(_turn(state, direction)),
                onMarkdown: () => _showMarkdown(context, state),
              )
            : null,
        body: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final bool wide = constraints.maxWidth >= 1100;
              if (!wide &&
                  _studyContext != null &&
                  !_studyModal &&
                  !_compactStudyScheduled) {
                _compactStudyScheduled = true;
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  _compactStudyScheduled = false;
                  if (mounted &&
                      _studyContext != null &&
                      !_studyModal &&
                      MediaQuery.sizeOf(context).width < 1100) {
                    unawaited(_showCompactStudy());
                  }
                });
              }
              return Row(
                children: [
                  Expanded(child: _body(context, state)),
                  if (wide && _studyContext != null && !_studyModal) ...[
                    const VerticalDivider(width: 1),
                    SizedBox(
                      width: (constraints.maxWidth * .42).clamp(420, 560),
                      child: _studyWorkspace(state),
                    ),
                  ],
                ],
              );
            },
          ),
        ),
      ),
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
              if (_showChrome)
                _ChapterHeading(
                  state: state,
                  onPreview: () => _showReferencePreview(),
                ),
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
                        child: ScriptureStudyActions(
                          emphasisFor: (verse) =>
                              identical(state.current, _arrivalChapter) &&
                                  verse.verse == _arrivalVerse
                              ? _arrivalEmphasis
                              : const <ScriptureTextEmphasis>[],
                          onWord: (verse, range) => _openStudy(
                            verse: verse,
                            range: range,
                            tab: StudyTab.dictionary,
                          ),
                          onSearch: (text) => unawaited(
                            _showSearch(
                              context,
                              state,
                              initialQuery: text,
                              phrase: true,
                            ),
                          ),
                          onNote: (verse) => _editVerseNote(verse.verse),
                          child: _ReaderBody(
                            state: state,
                            controller: _scrollController,
                            verseKeys: _verseKeys,
                            editingNote: _editingNote,
                            onEditNote: _editVerseNote,
                            onOpenVerseMenu: _showVerseMenu,
                          ),
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
    if (_studyContext != null ||
        _previewOpen ||
        _openingDaily ||
        state.loading ||
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

  Future<void> _openDaily(AppState state) async {
    if (_openingDaily) return;
    if (_editingNote != null) {
      _noteNavigationNotice();
      return;
    }
    // Daily reference discovery happens before AppState's chapter load. Own
    // that interval too, so a new inline draft cannot be rebound by its result.
    setState(() => _openingDaily = true);
    try {
      await state.openDailyScripture();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('The daily passage could not be opened. $error'),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _openingDaily = false);
    }
  }

  void _editVerseNote(int? verse) {
    if (verse != null && (_openingDaily || context.read<AppState>().loading)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Wait for the passage to finish opening before editing a verse note.',
          ),
        ),
      );
      return;
    }
    if (_editingNote != null && verse != null && verse != _editingNote) {
      _noteNavigationNotice();
      return;
    }
    setState(() => _editingNote = verse);
  }

  void _noteNavigationNotice() => ScaffoldMessenger.of(context).showSnackBar(
    const SnackBar(
      content: Text(
        'Save or close the verse note before opening another passage.',
      ),
    ),
  );

  Future<void> _showMarkdown(BuildContext context, AppState state) =>
      showDialog<void>(
        context: context,
        builder: (BuildContext context) =>
            _ScriptureShareDialog(state: state, initialVerse: null),
      );

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

  Future<void> _showReferencePreview([ReferenceRequest? request]) async {
    if (_previewOpen) return;
    final AppState state = context.read<AppState>();
    final FocusNode? previousFocus = FocusManager.instance.primaryFocus;
    final ReferencePreviewController controller = ReferencePreviewController(
      lookup: state.referenceLookup,
    );
    final String previewTranslation =
        request?.translation ?? state.passage.translation;
    final Translation? previewBible = state.translations
        .where((item) => item.abbreviation == previewTranslation)
        .firstOrNull;
    _previewOpen = true;
    _boundaryTurns.clear();
    try {
      await showAdaptiveReferencePreview(
        context: context,
        controller: controller,
        selectedTranslation: previewTranslation,
        translationName: request?.translationName ?? previewBible?.translation,
        selectedTranslationDirection:
            request?.translationDirection ?? previewBible?.direction ?? 'LTR',
        showSourceStyles: state.preferences.showSourceStyles,
        initialRequest: request,
        labels: ReferencePreviewLabels(copy: state.ui('copy')),
        onOpenInReader: (Passage selected) async {
          if (_editingNote != null) {
            throw const ReferenceLookupException(
              'Save or close the note editor before opening another reference.',
            );
          }
          final ReferenceResult? citation = controller.result;
          bool ownsNavigation() =>
              controller.isVisible && identical(controller.result, citation);
          await state.loadPassage(selected, ownsRequest: ownsNavigation);
          if (!mounted || !ownsNavigation()) return;
          if (state.error != null || state.passage != selected) {
            throw StateError(
              state.error ?? 'The selected verse could not be opened.',
            );
          }
          await _scrollToVerse(selected.verse);
          if (!ownsNavigation() || state.passage != selected) return;
        },
      );
    } finally {
      controller.dispose();
      _previewOpen = false;
      if (mounted && previousFocus?.context != null) {
        previousFocus!.requestFocus();
      }
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
        const PopupMenuItem<String>(
          value: '__preview__',
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.find_in_page_outlined),
            title: Text('Reference preview'),
          ),
        ),
        for (final (String value, String label) in <(String, String)>[
          ('__commentary__', 'Verse commentary'),
          ('__topics__', 'Verse topics'),
        ])
          PopupMenuItem<String>(value: value, child: Text(label)),
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
    if (choice == '__preview__') {
      await _showReferencePreview(
        StructuredReferenceRequest(
          translation: state.passage.translation,
          translationName: state.currentTranslation?.translation,
          sourceLabel: reference,
          translationDirection:
              state.current?.direction ?? state.currentTranslation?.direction,
          selections: <ReferenceSelection>[
            ReferenceSelection.verse(
              state.passage.copyWith(verse: verse.verse),
            ),
          ],
        ),
      );
    } else if (choice == '__commentary__' || choice == '__topics__') {
      _openStudy(
        verse: verse,
        tab: choice == '__commentary__' ? StudyTab.commentary : StudyTab.topics,
      );
    } else if (choice == '__note__') {
      _editVerseNote(verse.verse);
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

  Future<void> _showSearch(
    BuildContext context,
    AppState state, {
    String initialQuery = '',
    bool phrase = false,
    StudyContext? sourceContext,
  }) async {
    final FocusNode? previousFocus = FocusManager.instance.primaryFocus;
    final String translation =
        sourceContext?.translation ?? state.passage.translation;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => Dialog.fullscreen(
        child: SafeArea(
          child: Column(
            children: [
              AppBar(
                title: Text('Search ${translation.toUpperCase()}'),
                leading: IconButton(
                  tooltip: 'Close search',
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.of(dialogContext).pop(),
                ),
              ),
              Expanded(
                child: SearchPanel(
                  controller: state.onlineSearch,
                  translation: translation,
                  books: sourceContext?.availableBooks ?? state.books,
                  initialQuery: initialQuery,
                  initialPhrase: phrase,
                  direction:
                      sourceContext?.direction ??
                      state.current?.direction ??
                      'LTR',
                  showSourceStyles: state.preferences.showSourceStyles,
                  onOpen: (OnlineSearchHit hit) async {
                    if (_editingNote != null) {
                      throw const ReferenceLookupException(
                        'Save or close the verse note before opening another passage.',
                      );
                    }
                    final Passage target = Passage(
                      translation: hit.translation,
                      book: hit.book,
                      chapter: hit.chapter,
                      verse: hit.verse.verse,
                    );
                    final OnlineSearchRequest? searchOperation =
                        state.onlineSearch.request;
                    bool ownsNavigation() =>
                        mounted &&
                        dialogContext.mounted &&
                        identical(
                          state.onlineSearch.request,
                          searchOperation,
                        ) &&
                        ModalRoute.of(dialogContext)?.isCurrent == true;
                    await state.loadPassage(
                      target,
                      ownsRequest: ownsNavigation,
                    );
                    if (!ownsNavigation()) return;
                    if (state.passage != target || state.error != null) {
                      throw ReferenceLookupException(
                        state.error ??
                            'This search result is unavailable in the selected Bible.',
                      );
                    }
                    final criteria = state.onlineSearch.request?.criteria;
                    setState(() {
                      _arrivalChapter = state.current;
                      _arrivalVerse = hit.verse.verse;
                      _arrivalEmphasis = searchMatchEmphasis(
                        hit.verse,
                        hit.terms,
                        caseSensitive: criteria?.caseSensitive ?? false,
                        match: criteria?.match ?? SearchMatchMode.partial,
                      );
                    });
                    await _scrollToVerse(target.verse);
                    if (!ownsNavigation() || !dialogContext.mounted) return;
                    Navigator.of(dialogContext).pop();
                    if (_studyContext != null) _closeStudy();
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
    state.onlineSearch.cancel();
    if (mounted && previousFocus?.context != null) {
      previousFocus!.requestFocus();
    }
  }

  StudyContext _captureStudy(
    AppState state, {
    Verse? verse,
    ScriptureTextRange? range,
  }) => StudyContext(
    passage: verse == null
        ? state.passage.copyWith(clearVerse: true)
        : state.passage.copyWith(verse: verse.verse),
    bookName: state.current?.bookName ?? '',
    language: state.currentTranslation?.lang ?? 'en',
    translationName: state.currentTranslation?.translation,
    direction:
        state.current?.direction ??
        state.currentTranslation?.direction ??
        'LTR',
    verse: verse,
    selectionStart: range?.start,
    selectionEnd: range?.end,
    availableBooks: List<BibleBook>.unmodifiable(state.books),
  );

  void _openStudy({
    Verse? verse,
    ScriptureTextRange? range,
    StudyTab tab = StudyTab.markings,
  }) {
    if (_previewOpen || _studyModal) return;
    final AppState state = context.read<AppState>();
    _readerFocusBeforeStudy ??= FocusManager.instance.primaryFocus;
    _boundaryTurns.clear();
    setState(() {
      _studyContext = _captureStudy(state, verse: verse, range: range);
      _studyTab = tab;
    });
    if (MediaQuery.sizeOf(context).width < 1100) unawaited(_showCompactStudy());
  }

  Future<void> _showCompactStudy() async {
    if (!mounted || _studyContext == null || _studyModal) return;
    _studyModal = true;
    try {
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        showDragHandle: true,
        builder: (sheetContext) => Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.viewInsetsOf(sheetContext).bottom,
          ),
          child: SizedBox(
            height: MediaQuery.sizeOf(sheetContext).height * .92,
            child: _studyWorkspace(context.read<AppState>()),
          ),
        ),
      );
    } finally {
      _studyModal = false;
      if (mounted) _finishStudy();
    }
  }

  void _closeStudy() {
    if (_studyModal) {
      Navigator.of(context).pop();
    } else {
      _finishStudy();
    }
  }

  void _finishStudy() {
    // Private notebook drafts belong to their controller, so closing this
    // surface cannot discard edits. Resource requests are cancelled separately.
    context.read<AppState>().study.dismissResources();
    unawaited(context.read<AppState>().study.notebooks.flush());
    setState(() => _studyContext = null);
    final FocusNode? focus = _readerFocusBeforeStudy;
    _readerFocusBeforeStudy = null;
    if (focus?.context != null) focus!.requestFocus();
  }

  Future<void> _openStudyPassage(Passage passage) async {
    final AppState state = context.read<AppState>();
    if (_editingNote != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Save or close the verse note before opening another passage.',
          ),
        ),
      );
      return;
    }
    if (_studyContext != null) _closeStudy();
    await state.loadPassage(passage);
    if (!mounted) return;
    if (state.passage != passage || state.error != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            state.error ?? 'This passage is unavailable in the selected Bible.',
          ),
        ),
      );
      return;
    }
    await _scrollToVerse(passage.verse);
  }

  Widget _studyWorkspace(AppState state) {
    final StudyContext captured = _studyContext!;
    return StudyWorkspace(
      context: captured,
      initialTab: _studyTab,
      onClose: _closeStudy,
      onSearchSelection: captured.selectedText == null
          ? null
          : () => unawaited(
              _showSearch(
                context,
                state,
                initialQuery: captured.selectedText!,
                phrase: true,
                sourceContext: captured,
              ),
            ),
      panelBuilder: (context, tab) => _studyPanel(state, captured, tab),
    );
  }

  Widget _studyPanel(AppState state, StudyContext captured, StudyTab tab) =>
      switch (tab) {
        StudyTab.markings => MyAnnotationsPanel(
          state: state,
          onOpenPassage: (passage) => unawaited(_openStudyPassage(passage)),
        ),
        StudyTab.verseNotes => MyAnnotationsPanel(
          state: state,
          showNotes: true,
          onOpenPassage: (passage) => unawaited(_openStudyPassage(passage)),
        ),
        StudyTab.dictionary => DictionaryPanel(
          controller: state.study.dictionary,
          context: captured,
          onPreviewReference: _showReferencePreview,
        ),
        StudyTab.commentary => CommentaryPanel(
          controller: state.study.commentary,
          context: captured,
          onPreviewReference: _showReferencePreview,
        ),
        StudyTab.topics => TopicsPanel(
          controller: state.study.topics,
          context: captured,
          onPreviewReference: _showReferencePreview,
          onPrivateCopyCommitted: state.refreshAnnotations,
        ),
        StudyTab.notes => NotesPanel(
          controller: state.study.notebooks,
          context: captured,
          onPreviewReference: _showReferencePreview,
          onOpenPassage: _openStudyPassage,
        ),
      };
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
    final bool compact = MediaQuery.sizeOf(context).width <= 720;
    return AppBar(
      toolbarHeight: 62,
      leading: IconButton(
        constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
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
          Flexible(
            child: InkWell(
              onTap: onHome,
              borderRadius: BorderRadius.circular(6),
              child: const Padding(
                padding: EdgeInsets.symmetric(horizontal: 2, vertical: 8),
                child: Text(
                  'getBible.Life',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontWeight: FontWeight.w700, fontSize: 20),
                ),
              ),
            ),
          ),
          if (!compact) ...<Widget>[
            const SizedBox(width: 18),
            Expanded(
              flex: 2,
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
            constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
            tooltip: state.ui('searchThisTranslation'),
            onPressed: onSearch,
            icon: const Icon(Icons.search),
          ),
        // Compact readers already have the persistent chapter navigation row.
        // Keep this toolbar's actions reachable without duplicating its arrows.
        if (!compact) ...<Widget>[
          IconButton(
            constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
            tooltip: state.ui('previousChapter'),
            onPressed: state.canGoPrevious ? () => onTurn(-1) : null,
            icon: const Icon(Icons.chevron_left),
          ),
          IconButton(
            constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
            tooltip: state.ui('nextChapter'),
            onPressed: state.canGoNext ? () => onTurn(1) : null,
            icon: const Icon(Icons.chevron_right),
          ),
        ],
        IconButton(
          constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
          tooltip: state.ui('openAsMarkdown'),
          onPressed: state.current?.verses.isNotEmpty == true
              ? onMarkdown
              : null,
          icon: const Icon(Icons.menu_book_outlined),
        ),
        Padding(
          padding: const EdgeInsetsDirectional.only(end: 10),
          child: compact
              ? IconButton(
                  constraints: const BoxConstraints(
                    minWidth: 48,
                    minHeight: 48,
                  ),
                  tooltip: state.ui('study'),
                  onPressed: onStudy,
                  icon: const Icon(Icons.school_outlined),
                )
              : OutlinedButton(
                  onPressed: onStudy,
                  child: Text(state.ui('study')),
                ),
        ),
      ],
    );
  }
}

class _ChapterHeading extends StatelessWidget {
  const _ChapterHeading({required this.state, required this.onPreview});

  final AppState state;
  final VoidCallback onPreview;

  @override
  Widget build(BuildContext context) {
    final BibleChapter chapter = state.current!;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 8),
      child: Row(
        children: <Widget>[
          Expanded(
            child: TextButton(
              style: TextButton.styleFrom(
                alignment: AlignmentDirectional.centerStart,
              ),
              onPressed: onPreview,
              child: Text(
                chapter.name,
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
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
    final ScriptureChapterLayout layout = ScriptureChapterLayout(chapter);
    final List<(EditorialHeading?, Verse?)> rows =
        <(EditorialHeading?, Verse?)>[
          for (final ScriptureReadingBlock block in layout.blocks)
            if (block is ScriptureHeadingBlock)
              (block.heading, null)
            else if (block is ScriptureParagraphBlock)
              for (final Verse verse in block.verses) (null, verse),
        ];
    final double maximumWidth =
        state.preferences.readingWidth == ReadingWidth.constrained
        ? 920
        : double.infinity;
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maximumWidth),
        child: state.preferences.layout == ReaderLayout.paragraph
            ? _ParagraphReader(
                state: state,
                controller: controller,
                verseKeys: verseKeys,
                editingNote: editingNote,
                onEditNote: onEditNote,
                onOpenVerseMenu: onOpenVerseMenu,
              )
            : ListView.builder(
                controller: controller,
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(20, 10, 20, 32),
                itemCount: rows.length + 2,
                itemBuilder: (BuildContext context, int index) {
                  if (index == 0) return _ChapterIntroductions(state: state);
                  if (index == rows.length + 1) {
                    return _ChapterFooter(state: state);
                  }
                  final (EditorialHeading? heading, Verse? verse) =
                      rows[index - 1];
                  if (heading != null) {
                    return ScriptureEditorialHeading(
                      heading: heading,
                      textStyle: _scriptureStyle(context, state),
                    );
                  }
                  final Verse selected = verse!;
                  final String reference =
                      '${chapter.bookName} ${chapter.chapter}:${selected.verse}';
                  final VerseNote? note = state.notes
                      .where((VerseNote item) => item.verse == selected.verse)
                      .firstOrNull;
                  return _VerseLine(
                    key: verseKeys.putIfAbsent(selected.verse, GlobalKey.new),
                    state: state,
                    verse: selected,
                    reference: reference,
                    note: note,
                    editing: editingNote == selected.verse,
                    onEditNote: onEditNote,
                    onOpenMenu: onOpenVerseMenu,
                  );
                },
              ),
      ),
    );
  }
}

TextStyle _scriptureStyle(BuildContext context, AppState state) => TextStyle(
  fontFamily: _fontFamily(state.preferences.readerFont),
  fontSize: state.preferences.textSize,
  height: 1.55,
  color: Theme.of(context).colorScheme.onSurface,
);

class _ChapterIntroductions extends StatelessWidget {
  const _ChapterIntroductions({required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    final BibleChapter chapter = state.current!;
    final bool firstChapter =
        state.chapters.firstOrNull?.chapter == chapter.chapter;
    final BibleBook? book = state.books
        .where((BibleBook item) => item.number == chapter.bookNumber)
        .firstOrNull;
    final Translation? translation = state.currentTranslation;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (firstChapter &&
            state.books.firstOrNull?.number == chapter.bookNumber &&
            translation != null)
          ScriptureIntroductionSection(
            titles: translation.titles,
            introduction: translation.introduction,
            textStyle: _scriptureStyle(context, state),
          ),
        if (firstChapter && book != null && !chapter.isIntroduction)
          ScriptureIntroductionSection(
            titles: book.titles,
            introduction: book.introduction,
            textStyle: _scriptureStyle(context, state),
          ),
        ScriptureIntroductionSection(
          titles: chapter.titles,
          introduction: chapter.introduction,
          textStyle: _scriptureStyle(context, state),
        ),
      ],
    );
  }
}

class _ParagraphReader extends StatelessWidget {
  const _ParagraphReader({
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
    final ScriptureChapterLayout layout = ScriptureChapterLayout(chapter);
    return ListView(
      controller: controller,
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
      children: <Widget>[
        _ChapterIntroductions(state: state),
        for (final ScriptureReadingBlock block in layout.blocks)
          if (block is ScriptureHeadingBlock)
            ScriptureEditorialHeading(
              heading: block.heading,
              textStyle: _scriptureStyle(context, state),
            )
          else if (block is ScriptureParagraphBlock)
            Padding(
              padding: const EdgeInsets.only(bottom: 14),
              child: _paragraph(context, block.verses),
            ),
        for (final VerseNote note in state.notes)
          if (editingNote == note.verse)
            _InlineNoteEditor(
              state: state,
              verse: note.verse,
              reference: note.reference,
              note: note,
              onClose: () => onEditNote(null),
            )
          else
            _SavedNote(note: note, onTap: () => onEditNote(note.verse)),
        if (editingNote != null &&
            !state.notes.any((VerseNote note) => note.verse == editingNote))
          _InlineNoteEditor(
            state: state,
            verse: editingNote!,
            reference: '${chapter.bookName} ${chapter.chapter}:$editingNote',
            note: null,
            onClose: () => onEditNote(null),
          ),
        _ChapterFooter(state: state),
      ],
    );
  }

  Widget _paragraph(BuildContext context, List<Verse> verses) {
    final Passage origin = state.passage;
    final String bookName = state.current!.bookName;
    final ScriptureParagraphTextMap mapping = ScriptureParagraphTextMap(
      verses,
      versePrefix: (_) => '\uFFFC',
    );
    final List<InlineSpan> content = <InlineSpan>[];
    for (int index = 0; index < verses.length; index++) {
      final Verse verse = verses[index];
      final String reference =
          '${state.current!.bookName} ${state.current!.chapter}:${verse.verse}';
      if (index > 0) content.add(const TextSpan(text: ' '));
      content.add(
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
      );
      content.add(
        scriptureVerseSpan(
          context: context,
          verse: verse,
          style: _scriptureStyle(context, state),
          passage: state.passage,
          markings: state.markings,
          groups: state.groups,
          showSourceStyles: state.preferences.showSourceStyles,
          emphasis:
              ScriptureStudyActions.maybeOf(
                context,
              )?.emphasisFor?.call(verse) ??
              const <ScriptureTextEmphasis>[],
        ),
      );
    }
    return ScriptureParagraphSelection(
      mapping: mapping,
      child: NativeScriptureText(
        span: TextSpan(
          style: _scriptureStyle(context, state),
          children: content,
        ),
        mapping: mapping,
        onWordTap: ScriptureStudyActions.maybeOf(context)?.onWord,
        contextMenuBuilder: (BuildContext context, EditableTextState editable) {
          final TextSelection selection = editable.textEditingValue.selection;
          final List<ScriptureVerseSelection> ranges = mapping.selections(
            selection.start,
            selection.end,
          );
          return AdaptiveTextSelectionToolbar.buttonItems(
            anchors: editable.contextMenuAnchors,
            buttonItems: <ContextMenuButtonItem>[
              for (final ContextMenuButtonItem button
                  in editable.contextMenuButtonItems)
                if (button.type == ContextMenuButtonType.copy &&
                    ranges.isNotEmpty)
                  ContextMenuButtonItem(
                    type: ContextMenuButtonType.copy,
                    onPressed: () {
                      editable.hideToolbar();
                      unawaited(
                        Clipboard.setData(
                          ClipboardData(
                            text: ranges
                                .map(
                                  (ScriptureVerseSelection item) => item.quote,
                                )
                                .join(' '),
                          ),
                        ),
                      );
                    },
                  )
                else
                  button,
              if (ranges.isNotEmpty) ...[
                ContextMenuButtonItem(
                  label: 'Search selected phrase',
                  onPressed: () {
                    editable.hideToolbar();
                    ScriptureStudyActions.maybeOf(
                      context,
                    )?.onSearch(ranges.map((item) => item.quote).join(' '));
                  },
                ),
                ContextMenuButtonItem(
                  label: 'Study selected word',
                  onPressed: () {
                    editable.hideToolbar();
                    final selected = ranges.first;
                    ScriptureStudyActions.maybeOf(
                      context,
                    )?.onWord(selected.verse, selected.range);
                  },
                ),
                ContextMenuButtonItem(
                  label: 'Add or edit verse note',
                  onPressed: () {
                    editable.hideToolbar();
                    ScriptureStudyActions.maybeOf(
                      context,
                    )?.onNote(ranges.first.verse);
                  },
                ),
              ],
              if (ranges.isNotEmpty && state.activeGroup != null)
                ContextMenuButtonItem(
                  label: 'Mark: ${state.activeGroup!.name}',
                  onPressed: () {
                    editable.hideToolbar();
                    unawaited(
                      state.markTextSelections(
                        origin,
                        ranges,
                        bookName,
                        state.activeGroup!.id,
                      ),
                    );
                  },
                ),
              if (ranges.isNotEmpty && state.groups.length > 1)
                ContextMenuButtonItem(
                  label: 'More marking groups…',
                  onPressed: () async {
                    editable.hideToolbar();
                    final String? groupId = await showDialog<String>(
                      context: context,
                      builder: (BuildContext context) =>
                          _MarkingGroupPicker(groups: state.groups),
                    );
                    if (context.mounted && groupId != null) {
                      await state.markTextSelections(
                        origin,
                        ranges,
                        bookName,
                        groupId,
                      );
                    }
                  },
                ),
              if (ranges.any(
                (ScriptureVerseSelection item) => state.selectionHasMarking(
                  item.verse.verse,
                  item.range.start,
                  item.range.end,
                ),
              ))
                ContextMenuButtonItem(
                  label: 'Remove highlighting',
                  onPressed: () {
                    editable.hideToolbar();
                    unawaited(state.removeTextSelections(origin, ranges));
                  },
                ),
            ],
          );
        },
      ),
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
    return ScriptureVerseText(
      verse: verse,
      style: _scriptureStyle(context, state).copyWith(height: 1.38),
      passage: state.passage,
      markings: state.markings,
      groups: state.groups,
      showSourceStyles: state.preferences.showSourceStyles,
      emphasis:
          ScriptureStudyActions.maybeOf(context)?.emphasisFor?.call(verse) ??
          const <ScriptureTextEmphasis>[],
      includeWholeVerse: false,
      onWordTap: ScriptureStudyActions.maybeOf(context)?.onWord,
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
              if (valid) ...[
                ContextMenuButtonItem(
                  label: 'Search selected phrase',
                  onPressed: () {
                    editableTextState.hideToolbar();
                    ScriptureStudyActions.maybeOf(context)?.onSearch(
                      verse.text.substring(selection.start, selection.end),
                    );
                  },
                ),
                ContextMenuButtonItem(
                  label: 'Study selected word',
                  onPressed: () {
                    editableTextState.hideToolbar();
                    ScriptureStudyActions.maybeOf(context)?.onWord(
                      verse,
                      ScriptureTextRange(selection.start, selection.end),
                    );
                  },
                ),
                ContextMenuButtonItem(
                  label: 'Add or edit verse note',
                  onPressed: () {
                    editableTextState.hideToolbar();
                    ScriptureStudyActions.maybeOf(context)?.onNote(verse);
                  },
                ),
              ],
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
  late final TextEditingController _controller;
  late final String _canonicalKey;
  late final String _reference;
  late final int _sourceVerse;
  late final bool _hadNote;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.note?.text ?? '');
    _canonicalKey = widget.state.passage.canonicalKey;
    _reference = widget.reference;
    _sourceVerse = widget.verse;
    _hadNote = widget.note != null;
  }

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
                    _reference,
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
                if (_hadNote)
                  IconButton(
                    tooltip: 'Delete note',
                    onPressed: () async {
                      if (!_canWriteToSource()) return;
                      await widget.state.deleteVerseNote(_sourceVerse);
                      if (mounted) widget.onClose();
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
    if (!_canWriteToSource()) return;
    await widget.state.saveVerseNote(
      _sourceVerse,
      _reference,
      _controller.text,
    );
    if (mounted) widget.onClose();
  }

  /// The visible draft belongs to its original canonical passage, even if an
  /// external navigation updates this editor's inherited reader state.
  bool _canWriteToSource() {
    if (widget.state.passage.canonicalKey != _canonicalKey ||
        widget.verse != _sourceVerse) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Return to $_reference before changing this retained verse-note draft.',
          ),
        ),
      );
      return false;
    }
    return true;
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

class _ReaderDrawer extends StatelessWidget {
  const _ReaderDrawer({
    required this.state,
    required this.onReferencePreview,
    required this.navigationEnabled,
  });

  final AppState state;
  final Future<void> Function() onReferencePreview;
  final bool navigationEnabled;

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
          if (!navigationEnabled)
            const Padding(
              padding: EdgeInsets.only(bottom: 12),
              child: Text(
                'Save or close the verse note before changing the passage. Passage controls are temporarily unavailable.',
              ),
            ),
          ReaderTranslationField(
            value: state.passage.translation,
            translations: state.translations,
            onChanged: navigationEnabled
                ? (String? value) {
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
                  }
                : null,
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
            onChanged: navigationEnabled
                ? (int? value) {
                    if (value != null) unawaited(state.openBook(value));
                  }
                : null,
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
            onChanged: navigationEnabled
                ? (int? value) {
                    if (value != null) {
                      unawaited(
                        state.loadPassage(
                          state.passage.copyWith(
                            chapter: value,
                            clearVerse: true,
                          ),
                        ),
                      );
                    }
                  }
                : null,
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.find_in_page_outlined),
            title: const Text('Reference preview'),
            onTap: () {
              Navigator.of(context).pop();
              unawaited(onReferencePreview());
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
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Source text styles'),
            subtitle: const Text(
              'Show emphasis provided by this Bible edition',
            ),
            value: state.preferences.showSourceStyles,
            onChanged: (bool value) => unawaited(state.setSourceStyles(value)),
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
