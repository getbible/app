import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../application/app_state.dart';
import '../application/reference_preview_controller.dart';
import '../core/ui_strings.dart';
import '../data/platform/platform_text_file_service.dart';
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
import '../services/source_annotations.dart';
import 'boundary_turn_controller.dart';
import 'widgets/bookmark_assignment_menu.dart';
import 'widgets/commentary_panel.dart';
import 'widgets/dictionary_panel.dart';
import 'widgets/keyboard_inset_padding.dart';
import 'widgets/my_annotations_panel.dart';
import 'widgets/native_scripture_text.dart';
import 'widgets/notes_panel.dart';
import 'widgets/offline_setup_panel.dart';
import 'widgets/portability_panel.dart';
import 'widgets/reader_translation_field.dart';
import 'widgets/reference_preview.dart';
import 'widgets/scripture_editorial.dart';
import 'widgets/scripture_paragraph_selection.dart';
import 'widgets/scripture_study_actions.dart';
import 'widgets/scripture_verification_badge.dart';
import 'widgets/scripture_verse_text.dart';
import 'widgets/search_panel.dart';
import 'widgets/source_annotations.dart';
import 'widgets/study_workspace.dart';
import 'widgets/text_export_actions.dart';
import 'widgets/topics_panel.dart';

class ReaderScreen extends StatefulWidget {
  const ReaderScreen({super.key});

  @override
  State<ReaderScreen> createState() => _ReaderScreenState();
}

class _ReaderScreenState extends State<ReaderScreen> {
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  final GlobalKey _viewportKey = GlobalKey();
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
  ModalRoute<void>? _compactStudyRoute;
  bool _compactStudyScheduled = false;
  FocusNode? _readerFocusBeforeStudy;
  final FocusNode _readerFocus = FocusNode(debugLabel: 'Scripture reader');
  final ValueNotifier<int> _studyRevision = ValueNotifier(0);
  AppState? _owner;
  Passage? _restoredPassage;
  BibleChapter? _restoredChapter;
  Timer? _positionTimer;
  bool _userScrolled = false;
  _InlineNoteSession? _noteSession;
  String? _bookmarkGroup;

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
    _positionTimer?.cancel();
    _owner?.readerNavigationBlocked = false;
    _noteSession?.controller.dispose();
    _readerFocus.dispose();
    _studyRevision.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final AppState state = context.watch<AppState>();
    _owner = state;
    if (state.current != null &&
        !state.loading &&
        (_restoredPassage != state.passage ||
            !identical(_restoredChapter, state.current))) {
      _restoredPassage = state.passage;
      _restoredChapter = state.current;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && state.passage == _restoredPassage) {
          unawaited(_scrollToVerse(state.passage.verse));
        }
      });
    }
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
          onPortability: _showPortability,
          onOffline: _showOffline,
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
                      child: _studyWorkspace(state, _studyContext!),
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
                Padding(
                  padding: EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                  child: Text(
                    UiStrings.of(context).text(
                      'Saved legacy Scripture (API v2). Connect to refresh this passage from v3.',
                    ),
                  ),
                ),
              if (state.error != null)
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 8,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        state.error!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                      Align(
                        alignment: AlignmentDirectional.centerStart,
                        child: TextButton(
                          onPressed:
                              state.readerNavigationBlocked || state.loading
                              ? null
                              : () => unawaited(state.retryReading()),
                          child: Text(UiStrings.of(context).text('Retry')),
                        ),
                      ),
                    ],
                  ),
                ),
              Expanded(
                child: GestureDetector(
                  key: _viewportKey,
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
                      focusNode: _readerFocus,
                      child: NotificationListener<ScrollNotification>(
                        onNotification: (ScrollNotification notice) =>
                            _onScrollNotification(notice, state),
                        child: ScriptureStudyActions(
                          emphasisFor: (verse) =>
                              identical(state.current, _arrivalChapter) &&
                                  verse.verse == _arrivalVerse
                              ? _arrivalEmphasis
                              : (state.dailyVerses.contains(verse.verse) ||
                                        state.passage.verse == verse.verse) &&
                                    verse.text.isNotEmpty
                              ? <ScriptureTextEmphasis>[
                                  ScriptureTextEmphasis(
                                    range: ScriptureTextRange(
                                      0,
                                      verse.text.length,
                                    ),
                                    quote: verse.text,
                                  ),
                                ]
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
                          onBookmarks: _openBookmarks,
                          onReference: (reference) => unawaited(
                            _showReferencePreview(
                              TextReferenceRequest(
                                translation: state.passage.translation,
                                reference: reference,
                                translationName:
                                    state.currentTranslation?.translation,
                                translationDirection: state.current?.direction,
                              ),
                            ),
                          ),
                          child: _InlineNoteSessionScope(
                            session: _noteSession,
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
    if (notice is UserScrollNotification &&
        notice.direction != ScrollDirection.idle) {
      _userScrolled = true;
    }
    if (notice is ScrollEndNotification && !state.loading && _userScrolled) {
      _userScrolled = false;
      _positionTimer?.cancel();
      _positionTimer = Timer(const Duration(milliseconds: 250), () {
        if (!mounted || state.loading) return;
        final viewport = _viewportKey.currentContext?.findRenderObject();
        if (viewport is! RenderBox || !viewport.attached) return;
        final bounds = viewport.localToGlobal(Offset.zero) & viewport.size;
        for (final verse in state.current?.verses ?? const <Verse>[]) {
          final target = _verseKeys[verse.verse]?.currentContext;
          final render = target?.findRenderObject();
          if (render is! RenderBox || !render.attached) continue;
          final y = render.localToGlobal(Offset.zero).dy;
          if (y + render.size.height > bounds.top && y < bounds.bottom) {
            unawaited(
              state
                  .recordReadingPosition(verse.verse)
                  .catchError((Object _) {}),
            );
            break;
          }
        }
      });
    }
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
            content: Text(
              UiStrings.of(context).text(
                'The daily passage could not be opened. {error}',
                {'error': error},
              ),
            ),
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
        SnackBar(
          content: Text(
            UiStrings.of(context).text(
              'Wait for the passage to finish opening before editing a verse note.',
            ),
          ),
        ),
      );
      return;
    }
    if (_editingNote != null && verse != null && verse != _editingNote) {
      _noteNavigationNotice();
      return;
    }
    if (verse != _editingNote) {
      _noteSession?.controller.dispose();
      _noteSession = null;
      if (verse != null) {
        final state = context.read<AppState>();
        final note = state.notes
            .where((item) => item.verse == verse)
            .firstOrNull;
        _noteSession = _InlineNoteSession(
          state.passage.canonicalKey,
          verse,
          '${state.current!.bookName} ${state.current!.chapter}:$verse',
          note,
        );
      }
    }
    setState(() => _editingNote = verse);
    context.read<AppState>().readerNavigationBlocked = verse != null;
  }

  void _noteNavigationNotice() => ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(
        UiStrings.of(
          context,
        ).text('Save or close the verse note before opening another passage.'),
      ),
    ),
  );

  Future<void> _showMarkdown(BuildContext context, AppState state) =>
      showDialog<void>(
        context: context,
        builder: (BuildContext context) =>
            _ScriptureShareDialog(state: state, initialVerse: null),
      );

  Future<void> _showPortability() async {
    if (_editingNote != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            UiStrings.of(context).text(
              'Save or close the verse note before backing up or importing private data.',
            ),
          ),
        ),
      );
      return;
    }
    final AppState state = context.read<AppState>();
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (context) => AnimatedBuilder(
          animation: state.portability,
          builder: (context, _) => PopScope<void>(
            canPop: !state.portability.busy,
            child: Scaffold(
              appBar: AppBar(
                title: Text(UiStrings.of(context).text('Backup and restore')),
                automaticallyImplyLeading: !state.portability.busy,
              ),
              body: SafeArea(
                child: PortabilityPanel(
                  controller: state.portability,
                  files: PlatformTextFileService(
                    textFilesLabel: UiStrings.of(
                      context,
                    ).text('Text and JSON files'),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    if (mounted && state.portability.importResult != null) {
      await _refreshVisibleStudy(state);
    }
  }

  Future<void> _showOffline() async {
    final AppState state = context.read<AppState>();
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (context) => Scaffold(
          body: OfflineSetupPanel(
            controller: state.offline,
            onClose: () => Navigator.of(context).pop(),
          ),
        ),
      ),
    );
    if (!mounted) return;
    try {
      await state.refreshInstalledResourceChoices();
      if (mounted) await _refreshVisibleStudy(state);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              UiStrings.of(context).text(
                'Resource choices could not refresh. Reopen the reader to retry.',
              ),
            ),
          ),
        );
      }
    }
  }

  Future<void> _refreshVisibleStudy(AppState state) async {
    final StudyContext? captured = _studyContext;
    if (captured == null) return;
    switch (_studyTab) {
      case StudyTab.dictionary:
        await state.study.dictionary.open(captured);
      case StudyTab.commentary:
        await state.study.commentary.open(captured);
      case StudyTab.topics:
        await state.study.topics.initialize(captured);
      default:
        break;
    }
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
            throw ReferenceLookupException(
              UiStrings.of(context).text(
                'Save or close the note editor before opening another reference.',
              ),
            );
          }
          final ReferenceResult? citation = controller.result;
          bool ownsNavigation() =>
              controller.isVisible && identical(controller.result, citation);
          await state.loadPassage(selected, ownsRequest: ownsNavigation);
          if (!mounted || !ownsNavigation()) return;
          if (state.error != null || state.passage != selected) {
            throw StateError(
              state.error ??
                  UiStrings.of(
                    context,
                  ).text('The selected verse could not be opened.'),
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
    final Passage origin = state.passage;
    final BibleChapter? originChapter = state.current;
    bool ownsVerse() =>
        mounted &&
        state.passage == origin &&
        identical(state.current, originChapter);
    final RenderBox button = anchorContext.findRenderObject()! as RenderBox;
    final RenderBox overlay =
        Overlay.of(context).context.findRenderObject()! as RenderBox;
    final Offset topLeft = button.localToGlobal(Offset.zero, ancestor: overlay);
    final Rect target = topLeft & button.size;
    final MarkingGroup? active = state.activeGroup ?? state.groups.firstOrNull;
    final String? choice = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(target, Offset.zero & overlay.size),
      semanticLabel: UiStrings.of(
        context,
      ).text('Choose marking for {reference}', {'reference': reference}),
      items: <PopupMenuEntry<String>>[
        if (active != null)
          PopupMenuItem<String>(
            // Imported group IDs are data, never reserved menu commands.
            value: '__group__:${active.id}',
            child: _GroupChoice(group: active),
          ),
        if (state.groups.length > 1)
          PopupMenuItem<String>(
            value: '__groups__',
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.palette_outlined),
              title: Text(UiStrings.of(context).text('More marking groups…')),
            ),
          ),
        PopupMenuItem<String>(
          value: '__bookmarks__',
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.bookmarks_outlined),
            title: Text(UiStrings.of(context).text('Bookmark topics')),
          ),
        ),
        PopupMenuItem<String>(
          value: '__preview__',
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.find_in_page_outlined),
            title: Text(UiStrings.of(context).text('Reference preview')),
          ),
        ),
        for (final (String value, String label) in <(String, String)>[
          ('__commentary__', UiStrings.of(context).text('Verse commentary')),
          ('__topics__', UiStrings.of(context).text('Verse topics')),
        ])
          PopupMenuItem<String>(value: value, child: Text(label)),
        const PopupMenuDivider(),
        PopupMenuItem<String>(
          value: '__note__',
          child: Text(
            state.notes.any((VerseNote note) => note.verse == verse.verse)
                ? UiStrings.of(context).text('Edit note')
                : UiStrings.of(context).text('Add note'),
          ),
        ),
        PopupMenuItem<String>(
          value: '__share__',
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.share_outlined),
            title: Text(UiStrings.of(context).text('Copy or share Scripture')),
          ),
        ),
        for (final MarkingGroup group in state.groups.where(
          (MarkingGroup group) => state.markings.any(
            (Marking marking) =>
                marking.verse == verse.verse &&
                marking.isWholeVerse &&
                !marking.isSharedBookmark &&
                marking.groupId == group.id,
          ),
        ))
          PopupMenuItem<String>(
            value: '__remove__:${group.id}',
            child: Text(
              UiStrings.of(
                context,
              ).text('Remove from {name}', {'name': group.name}),
            ),
          ),
        if (state.markings
                .where(
                  (Marking marking) =>
                      marking.verse == verse.verse &&
                      marking.isWholeVerse &&
                      !marking.isSharedBookmark,
                )
                .map((Marking marking) => marking.groupId)
                .toSet()
                .length >
            1)
          PopupMenuItem<String>(
            value: '__none__',
            child: Text(
              UiStrings.of(context).text('Remove all personal verse markings'),
            ),
          ),
      ],
    );
    if (choice == null || !mounted || !ownsVerse()) return;
    if (choice == '__bookmarks__') {
      if (!anchorContext.mounted) return;
      await _showBookmarkAssignments(
        anchorContext,
        state,
        verse,
        reference,
        onOpenTopic: _openBookmarks,
      );
    } else if (choice == '__preview__') {
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
    } else if (choice.startsWith('__remove__:')) {
      await state.removeWholeVerseMarking(
        verse.verse,
        groupId: choice.substring('__remove__:'.length),
      );
    } else if (choice == '__groups__') {
      final String? groupId = await _showMarkingGroupPicker(context, state);
      if (groupId != null && ownsVerse()) {
        await state.markWholeVerse(verse, reference, groupId);
      }
    } else if (choice.startsWith('__group__:')) {
      await state.markWholeVerse(
        verse,
        reference,
        choice.substring('__group__:'.length),
      );
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
                title: Text(
                  UiStrings.of(context).text('Search {toUpperCase}', {
                    'toUpperCase': translation.toUpperCase(),
                  }),
                ),
                leading: IconButton(
                  tooltip: UiStrings.of(context).text('Close search'),
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
                      throw ReferenceLookupException(
                        UiStrings.of(context).text(
                          'Save or close the verse note before opening another passage.',
                        ),
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
                      if (!context.mounted) return;
                      throw ReferenceLookupException(
                        state.error ??
                            UiStrings.of(context).text(
                              'This search result is unavailable in the selected Bible.',
                            ),
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
    final captured = _studyContext;
    if (!mounted || captured == null || _studyModal) return;
    final state = context.read<AppState>();
    ModalRoute<void>? route;
    _studyModal = true;
    try {
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        showDragHandle: true,
        builder: (sheetContext) {
          route = ModalRoute.of<void>(sheetContext);
          _compactStudyRoute = route;
          return KeyboardInsetPadding(
            child: SizedBox(
              height: MediaQuery.sizeOf(sheetContext).height * .92,
              child: AnimatedBuilder(
                animation: Listenable.merge([state, _studyRevision]),
                builder: (context, _) => _studyWorkspace(state, captured),
              ),
            ),
          );
        },
      );
    } finally {
      // The pop Future completes before the reverse transition. The outgoing
      // sheet can still rebuild on keyboard metrics or storage notifications;
      // retain its captured context and controller ownership until removal.
      await route?.completed;
      _compactStudyRoute = null;
      _studyModal = false;
      if (mounted && identical(_studyContext, captured)) _finishStudy();
    }
  }

  void _closeStudy() {
    if (_studyModal) {
      // A repeated Close during the reverse animation must not pop the reader
      // or a different modal after this sheet has already been popped.
      final route = _compactStudyRoute;
      if (route?.isCurrent ?? false) route!.navigator?.pop();
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
    if (focus?.context != null) {
      focus!.requestFocus();
    } else {
      _readerFocus.requestFocus();
    }
  }

  Future<void> _openStudyPassage(Passage passage) async {
    final AppState state = context.read<AppState>();
    if (_editingNote != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            UiStrings.of(context).text(
              'Save or close the verse note before opening another passage.',
            ),
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
            state.error ??
                UiStrings.of(
                  context,
                ).text('This passage is unavailable in the selected Bible.'),
          ),
        ),
      );
      return;
    }
    await _scrollToVerse(passage.verse);
  }

  Widget _studyWorkspace(AppState state, StudyContext captured) {
    return StudyWorkspace(
      context: captured,
      initialTab: _studyTab,
      onTabChanged: (tab) => _studyTab = tab,
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
          initialGroupId: _bookmarkGroup,
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
          onSetUpOffline: () => unawaited(_showOffline()),
        ),
        StudyTab.commentary => CommentaryPanel(
          controller: state.study.commentary,
          context: captured,
          onPreviewReference: _showReferencePreview,
          onSetUpOffline: () => unawaited(_showOffline()),
        ),
        StudyTab.topics => TopicsPanel(
          controller: state.study.topics,
          bookmarks: state.bookmarks,
          onOpenBookmarks: (topicId) {
            final group = state.groups
                .where(
                  (group) =>
                      group.source?.topicId == topicId &&
                      group.source?.effectiveScope ==
                          state.bookmarks.publicTopics.sourceScope,
                )
                .firstOrNull;
            setState(() {
              _bookmarkGroup = group?.id;
              _studyTab = StudyTab.markings;
            });
            _studyRevision.value++;
          },
          context: captured,
          onPreviewReference: _showReferencePreview,
          onPrivateCopyCommitted: state.refreshAnnotations,
          onSetUpOffline: () => unawaited(_showOffline()),
        ),
        StudyTab.notes => NotesPanel(
          controller: state.study.notebooks,
          context: captured,
          onPreviewReference: _showReferencePreview,
          onOpenPassage: _openStudyPassage,
        ),
      };

  void _openBookmarks(String? groupId) {
    _bookmarkGroup = groupId;
    _openStudy(tab: StudyTab.markings);
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
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: 2, vertical: 8),
                child: Text(
                  UiStrings.of(context).text('getBible'),
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
                    decoration: InputDecoration(
                      hintText: UiStrings.of(context).text('Search'),
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
              child: _paragraphWithNotes(context, block.verses),
            ),
        _ChapterFooter(state: state),
      ],
    );
  }

  Widget _paragraphWithNotes(BuildContext context, List<Verse> verses) {
    final children = <Widget>[];
    var pending = <Verse>[];
    for (final verse in verses) {
      pending.add(verse);
      final note = state.notes
          .where((item) => item.verse == verse.verse)
          .firstOrNull;
      final editing = editingNote == verse.verse;
      final hasAnnotations = verseSourceAnnotations(verse).isNotEmpty;
      if (note == null && !editing && !hasAnnotations) continue;
      children.add(_paragraph(context, pending));
      pending = [];
      if (hasAnnotations) {
        children.add(
          ScriptureSourceAnnotations(
            verse: verse,
            onReference: ScriptureStudyActions.maybeOf(context)?.onReference,
          ),
        );
      }
      if (editing) {
        children.add(
          _InlineNoteEditor(
            state: state,
            verse: verse.verse,
            reference:
                '${state.current!.bookName} ${state.current!.chapter}:${verse.verse}',
            note: note,
            onClose: () => onEditNote(null),
          ),
        );
      } else if (note != null) {
        children.add(
          _SavedNote(note: note, onTap: () => onEditNote(verse.verse)),
        );
      }
    }
    if (pending.isNotEmpty) children.add(_paragraph(context, pending));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
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
              child: ConstrainedBox(
                constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                child: Center(
                  widthFactor: 1,
                  heightFactor: 1,
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
    return Semantics(
      container: true,
      label: verses
          .map(
            (verse) =>
                '$bookName ${origin.chapter}:${verse.verse}. ${verse.text}',
          )
          .join('\n'),
      child: ScriptureParagraphSelection(
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
                                    (ScriptureVerseSelection item) =>
                                        item.quote,
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
                    label: UiStrings.of(context).text('Search selected phrase'),
                    onPressed: () {
                      editable.hideToolbar();
                      ScriptureStudyActions.maybeOf(
                        context,
                      )?.onSearch(ranges.map((item) => item.quote).join(' '));
                    },
                  ),
                  ContextMenuButtonItem(
                    label: UiStrings.of(context).text('Study selected word'),
                    onPressed: () {
                      editable.hideToolbar();
                      final selected = ranges.first;
                      ScriptureStudyActions.maybeOf(
                        context,
                      )?.onWord(selected.verse, selected.range);
                    },
                  ),
                  ContextMenuButtonItem(
                    label: UiStrings.of(context).text('Add or edit verse note'),
                    onPressed: () {
                      editable.hideToolbar();
                      ScriptureStudyActions.maybeOf(
                        context,
                      )?.onNote(ranges.first.verse);
                    },
                  ),
                ],
                if (ranges.isNotEmpty)
                  ContextMenuButtonItem(
                    label: UiStrings.of(context).text('Bookmark topics'),
                    onPressed: () {
                      editable.hideToolbar();
                      final selected = ranges.first;
                      unawaited(
                        _showBookmarkAssignments(
                          context,
                          state,
                          selected.verse,
                          '$bookName ${origin.chapter}:${selected.verse.verse}',
                          selections: ranges,
                          onOpenTopic: ScriptureStudyActions.maybeOf(
                            context,
                          )?.onBookmarks,
                        ),
                      );
                    },
                  ),
                if (ranges.isNotEmpty && state.activeGroup != null)
                  ContextMenuButtonItem(
                    label: UiStrings.of(
                      context,
                    ).text('Mark: {name}', {'name': state.activeGroup!.name}),
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
                    label: UiStrings.of(context).text('More marking groups…'),
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
                    label: UiStrings.of(context).text('Remove highlighting'),
                    onPressed: () {
                      editable.hideToolbar();
                      unawaited(state.removeTextSelections(origin, ranges));
                    },
                  ),
              ],
            );
          },
        ),
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
    final Marking? whole = preferredWholeVerseMarking(
      state.markings.where((Marking item) => item.verse == verse.verse),
    );
    final MarkingGroup? wholeGroup = whole == null
        ? null
        : state.groups
              .where((MarkingGroup item) => item.id == whole.groupId)
              .firstOrNull;
    final Color? wholeColor = wholeGroup == null
        ? null
        : _hexColor(wholeGroup.color).withAlpha(45);
    return Semantics(
      // The web engine may expose a read-only selectable document only after
      // focus. Keep Scripture available to readers before selection begins.
      label: '$reference. ${verse.text}',
      container: true,
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
                          minWidth: 48,
                          minHeight: 48,
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
              ScriptureSourceAnnotations(
                verse: verse,
                onReference: ScriptureStudyActions.maybeOf(
                  context,
                )?.onReference,
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
                  label: UiStrings.of(context).text('Search selected phrase'),
                  onPressed: () {
                    editableTextState.hideToolbar();
                    ScriptureStudyActions.maybeOf(context)?.onSearch(
                      verse.text.substring(selection.start, selection.end),
                    );
                  },
                ),
                ContextMenuButtonItem(
                  label: UiStrings.of(context).text('Study selected word'),
                  onPressed: () {
                    editableTextState.hideToolbar();
                    ScriptureStudyActions.maybeOf(context)?.onWord(
                      verse,
                      ScriptureTextRange(selection.start, selection.end),
                    );
                  },
                ),
                ContextMenuButtonItem(
                  label: UiStrings.of(context).text('Add or edit verse note'),
                  onPressed: () {
                    editableTextState.hideToolbar();
                    ScriptureStudyActions.maybeOf(context)?.onNote(verse);
                  },
                ),
              ],
              if (valid)
                ContextMenuButtonItem(
                  label: UiStrings.of(context).text('Bookmark topics'),
                  onPressed: () {
                    editableTextState.hideToolbar();
                    unawaited(
                      _showBookmarkAssignments(
                        context,
                        state,
                        verse,
                        reference,
                        selections: [
                          ScriptureVerseSelection(
                            verse: verse,
                            range: ScriptureTextRange(
                              selection.start,
                              selection.end,
                            ),
                          ),
                        ],
                        onOpenTopic: ScriptureStudyActions.maybeOf(
                          context,
                        )?.onBookmarks,
                      ),
                    );
                  },
                ),
              if (valid && state.activeGroup != null)
                ContextMenuButtonItem(
                  label: UiStrings.of(
                    context,
                  ).text('Mark: {name}', {'name': state.activeGroup!.name}),
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
                  label: UiStrings.of(context).text('More marking groups…'),
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
                  label: UiStrings.of(context).text('Remove highlighting'),
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

final class _InlineNoteSession {
  _InlineNoteSession(
    this.canonicalKey,
    this.verse,
    this.reference,
    VerseNote? note,
  ) : hadNote = note != null,
      controller = TextEditingController(text: note?.text ?? '');
  final String canonicalKey;
  final int verse;
  final String reference;
  final bool hadNote;
  final TextEditingController controller;
}

class _InlineNoteSessionScope extends InheritedWidget {
  const _InlineNoteSessionScope({required this.session, required super.child});
  final _InlineNoteSession? session;
  @override
  bool updateShouldNotify(_InlineNoteSessionScope oldWidget) =>
      session != oldWidget.session;
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
  bool _initialized = false;
  bool _ownsController = false;
  bool _saving = false;
  String? _error;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initialized) return;
    _initialized = true;
    final session = context
        .dependOnInheritedWidgetOfExactType<_InlineNoteSessionScope>()
        ?.session;
    _ownsController = session == null;
    _controller =
        session?.controller ??
        TextEditingController(text: widget.note?.text ?? '');
    _canonicalKey = session?.canonicalKey ?? widget.state.passage.canonicalKey;
    _reference = session?.reference ?? widget.reference;
    _sourceVerse = session?.verse ?? widget.verse;
    _hadNote = session?.hadNote ?? widget.note != null;
  }

  @override
  void dispose() {
    if (_ownsController) _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.enter, control: true): () =>
            unawaited(_save()),
        const SingleActivator(LogicalKeyboardKey.enter, meta: true): () =>
            unawaited(_save()),
      },
      child: Card(
        margin: EdgeInsetsDirectional.fromSTEB(
          MediaQuery.sizeOf(context).width < 480 ? 0 : 44,
          8,
          0,
          8,
        ),
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
                    tooltip: UiStrings.of(context).text('Close note editor'),
                    onPressed: _saving ? null : widget.onClose,
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              TextField(
                controller: _controller,
                autofocus: true,
                minLines: 3,
                maxLines: 8,
                decoration: InputDecoration(
                  hintText: UiStrings.of(context).text('Write your note…'),
                ),
                onSubmitted: (_) => _save(),
              ),
              const SizedBox(height: 8),
              if (_error != null)
                Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              Wrap(
                alignment: WrapAlignment.end,
                spacing: 8,
                runSpacing: 8,
                children: <Widget>[
                  if (_hadNote)
                    IconButton(
                      tooltip: UiStrings.of(context).text('Delete note'),
                      onPressed: () async {
                        if (!_canWriteToSource()) return;
                        await widget.state.deleteVerseNote(_sourceVerse);
                        if (mounted) widget.onClose();
                      },
                      icon: const Icon(Icons.delete_outline),
                    ),
                  FilledButton.icon(
                    onPressed: _saving ? null : _save,
                    icon: const Icon(Icons.check),
                    label: Text(UiStrings.of(context).text('Save note')),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _save() async {
    if (_saving) return;
    if (_controller.text.trim().isEmpty) return;
    if (!_canWriteToSource()) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.state.saveVerseNote(
        _sourceVerse,
        _reference,
        _controller.text,
      );
      if (mounted) widget.onClose();
    } catch (error) {
      if (mounted) {
        setState(
          () => _error = UiStrings.of(context).text(
            'The note could not be saved. Your draft is kept. {error}',
            {'error': error},
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// The visible draft belongs to its original canonical passage, even if an
  /// external navigation updates this editor's inherited reader state.
  bool _canWriteToSource() {
    if (widget.state.passage.canonicalKey != _canonicalKey ||
        widget.verse != _sourceVerse) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            UiStrings.of(context).text(
              'Return to {reference} before changing this retained verse-note draft.',
              {'reference': _reference},
            ),
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
            Text(
              UiStrings.of(context).text('NOTE'),
              style: Theme.of(context).textTheme.labelSmall,
            ),
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
    required this.onPortability,
    required this.onOffline,
  });

  final AppState state;
  final Future<void> Function() onReferencePreview;
  final bool navigationEnabled;
  final Future<void> Function() onPortability;
  final Future<void> Function() onOffline;

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
            Padding(
              padding: EdgeInsets.only(bottom: 12),
              child: Text(
                UiStrings.of(context).text(
                  'Save or close the verse note before changing the passage. Passage controls are temporarily unavailable.',
                ),
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
                      item.isIntroduction
                          ? UiStrings.of(context).text('Introduction')
                          : '${item.chapter}',
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
            title: Text(UiStrings.of(context).text('Reference preview')),
            onTap: () {
              Navigator.of(context).pop();
              unawaited(onReferencePreview());
            },
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.backup_outlined),
            title: Text(UiStrings.of(context).text('Backup and restore')),
            onTap: navigationEnabled
                ? () {
                    Navigator.of(context).pop();
                    unawaited(onPortability());
                  }
                : null,
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.download_for_offline_outlined),
            title: Text(UiStrings.of(context).text('Set up offline use')),
            onTap: () {
              Navigator.of(context).pop();
              unawaited(onOffline());
            },
          ),
          if (state.resourceChoicesError != null)
            Text(state.resourceChoicesError!),
          const Divider(height: 32),
          Text(
            UiStrings.of(context).text('Appearance'),
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
            decoration: InputDecoration(
              labelText: UiStrings.of(context).text('Light reading palette'),
            ),
            items: <DropdownMenuItem<String>>[
              DropdownMenuItem(
                value: 'white',
                child: Text(UiStrings.of(context).text('Pure white')),
              ),
              DropdownMenuItem(
                value: 'paper',
                child: Text(UiStrings.of(context).text('Warm paper')),
              ),
              DropdownMenuItem(
                value: 'ivory',
                child: Text(UiStrings.of(context).text('Soft ivory')),
              ),
              DropdownMenuItem(
                value: 'mist',
                child: Text(UiStrings.of(context).text('Cool mist')),
              ),
            ],
            onChanged: (String? value) {
              if (value != null) unawaited(state.setLightPalette(value));
            },
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            key: ValueKey<String>('dark-${state.preferences.darkPalette}'),
            initialValue: state.preferences.darkPalette,
            decoration: InputDecoration(
              labelText: UiStrings.of(context).text('Dark reading palette'),
            ),
            items: <DropdownMenuItem<String>>[
              DropdownMenuItem(
                value: 'black',
                child: Text(UiStrings.of(context).text('Pure black')),
              ),
              DropdownMenuItem(
                value: 'brown',
                child: Text(UiStrings.of(context).text('Warm brown')),
              ),
              DropdownMenuItem(
                value: 'charcoal',
                child: Text(UiStrings.of(context).text('Soft charcoal')),
              ),
              DropdownMenuItem(
                value: 'navy',
                child: Text(UiStrings.of(context).text('Midnight blue')),
              ),
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
            items: <DropdownMenuItem<String>>[
              DropdownMenuItem(
                value: 'serif',
                child: Text(UiStrings.of(context).text('Classic serif')),
              ),
              DropdownMenuItem(
                value: 'book',
                child: Text(UiStrings.of(context).text('Book serif')),
              ),
              DropdownMenuItem(
                value: 'baskerville',
                child: Text(UiStrings.of(context).text('Baskerville')),
              ),
              DropdownMenuItem(
                value: 'garamond',
                child: Text(UiStrings.of(context).text('Garamond')),
              ),
              DropdownMenuItem(
                value: 'charter',
                child: Text(UiStrings.of(context).text('Charter')),
              ),
              DropdownMenuItem(
                value: 'cambria',
                child: Text(UiStrings.of(context).text('Cambria')),
              ),
              DropdownMenuItem(
                value: 'times',
                child: Text(UiStrings.of(context).text('Times New Roman')),
              ),
              DropdownMenuItem(
                value: 'sans',
                child: Text(UiStrings.of(context).text('Clean sans')),
              ),
              DropdownMenuItem(
                value: 'system',
                child: Text(UiStrings.of(context).text('System sans')),
              ),
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
            title: Text(UiStrings.of(context).text('Source text styles')),
            subtitle: Text(
              UiStrings.of(
                context,
              ).text('Show emphasis provided by this Bible edition'),
            ),
            value: state.preferences.showSourceStyles,
            onChanged: (bool value) => unawaited(state.setSourceStyles(value)),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(UiStrings.of(context).text('Reduce motion')),
            value: state.preferences.reduceMotion,
            onChanged: (value) =>
                unawaited(state.setAccessibility(reduceMotion: value)),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(UiStrings.of(context).text('High contrast')),
            value: state.preferences.highContrast,
            onChanged: (value) =>
                unawaited(state.setAccessibility(highContrast: value)),
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
              child: Text(UiStrings.of(context).text('Previous')),
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
              child: Text(UiStrings.of(context).text('Next')),
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
                      launchUrl(Uri.parse('https://app.getbible.life')),
                  child: Text(
                    UiStrings.of(context).text(
                      'getBible — {wordsOfEternalLife}',
                      {'wordsOfEternalLife': state.ui('wordsOfEternalLife')},
                    ),
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
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: <Widget>[
                      Flexible(
                        child: Text(
                          UiStrings.of(context).text(
                            '{lovinglyMaintainedBy} Vast Development Method',
                            {
                              'lovinglyMaintainedBy': state.ui(
                                'lovinglyMaintainedBy',
                              ),
                            },
                          ),
                          textAlign: TextAlign.end,
                        ),
                      ),
                      const SizedBox(width: 4),
                      // Use the bundled icon font instead of a remote Unicode
                      // fallback for this decorative heart on Flutter Web.
                      const ExcludeSemantics(
                        child: Icon(Icons.favorite, size: 14),
                      ),
                    ],
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
    return '${verses.map((Verse verse) => '${verse.verse}. ${verse.text}').join('\n')}\n\n$reference \u2014 ${_translation.translation}\nhttps://app.getbible.life/${_translation.abbreviation.toUpperCase()}/${Uri.encodeComponent(_chapter.bookName)}/${_chapter.chapter}?verse=${verses.first.verse}';
  }

  String get _value => _markdown
      ? scriptureMarkdown(_chapter, _translation, _first, _last)
      : _plainText;

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(
      widget.initialVerse == null
          ? widget.state.ui('openAsMarkdown')
          : UiStrings.of(context).text('Copy or share Scripture'),
    ),
    content: SizedBox(
      width: 640,
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            SegmentedButton<bool>(
              segments: <ButtonSegment<bool>>[
                ButtonSegment(
                  value: false,
                  label: Text(UiStrings.of(context).text('Share text')),
                ),
                ButtonSegment(
                  value: true,
                  label: Text(UiStrings.of(context).text('Markdown')),
                ),
              ],
              selected: <bool>{_markdown},
              onSelectionChanged: (Set<bool> value) =>
                  setState(() => _markdown = value.first),
            ),
            const SizedBox(height: 14),
            if (_chapter.verses.length > 1) ...<Widget>[
              Text(
                UiStrings.of(context).text('Verses {firstVerse}–{lastVerse}', {
                  'firstVerse': _chapter.verses[_first].verse,
                  'lastVerse': _chapter.verses[_last].verse,
                }),
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
            const SizedBox(height: 12),
            TextExportActions(
              text: _value,
              filename:
                  'getbible-${_translation.abbreviation}-${_chapter.bookNumber}-${_chapter.chapter}.${_markdown ? 'md' : 'txt'}',
              mimeType: _markdown ? 'text/markdown' : 'text/plain',
              subject: '${_chapter.bookName} ${_chapter.chapter}',
              files: PlatformTextFileService(
                textFilesLabel: UiStrings.of(
                  context,
                ).text('Text and JSON files'),
              ),
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
    ],
  );
}

Future<void> _showTranslationDetails(
  BuildContext context,
  Translation translation,
) {
  final List<(String, String)> details = <(String, String)>[
    (UiStrings.of(context).text('Language'), translation.resolvedLanguage),
    (
      UiStrings.of(context).text('Abbreviation'),
      translation.abbreviation.toUpperCase(),
    ),
    (UiStrings.of(context).text('Version'), translation.distributionVersion),
    (
      UiStrings.of(context).text('Version date'),
      translation.distributionVersionDate,
    ),
    (UiStrings.of(context).text('Description'), translation.description),
    (UiStrings.of(context).text('About'), translation.distributionAbout),
    (
      UiStrings.of(context).text('License and copyright'),
      translation.distributionLicense,
    ),
    (
      UiStrings.of(context).text('Source type'),
      translation.distributionSourceType,
    ),
    (UiStrings.of(context).text('Source'), translation.distributionSource),
    (
      UiStrings.of(context).text('Versification'),
      translation.distributionVersification,
    ),
    (
      UiStrings.of(context).text('Catalog subject'),
      translation.distributionLcsh,
    ),
    for (final MapEntry<String, String> item
        in translation.distributionHistory.entries)
      (
        UiStrings.of(context).text('History — {key}', {'key': item.key}),
        item.value,
      ),
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
            label: Text(UiStrings.of(context).text('Translation source')),
          ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(UiStrings.of(context).text('Close')),
        ),
      ],
    ),
  );
}

/// Constrain the assignment surface beside its originating verse/selection.
/// It is a route so native Escape/back, keyboard traversal and focus restoration
/// work consistently; tall topic lists scroll within the available safe area.
Future<void> _showBookmarkAssignments(
  BuildContext anchor,
  AppState state,
  Verse verse,
  String reference, {
  List<ScriptureVerseSelection>? selections,
  ValueChanged<String?>? onOpenTopic,
}) async {
  final origin = state.passage;
  final chapter = state.current;
  final previousFocus = FocusManager.instance.primaryFocus;
  final render = anchor.findRenderObject();
  final anchorPoint = render is RenderBox
      ? render.localToGlobal(Offset.zero)
      : Offset.zero;
  final selected = selections?.firstOrNull;
  var openTopic = false;
  String? selectedGroup;
  bool ownsVerse() =>
      state.passage == origin && identical(state.current, chapter);
  await showDialog<void>(
    context: anchor,
    builder: (dialogContext) => SafeArea(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = (constraints.maxWidth - 24).clamp(0.0, 480.0);
          final height = (constraints.maxHeight - 24).clamp(0.0, 620.0);
          final left = anchorPoint.dx.clamp(
            12.0,
            (constraints.maxWidth - width - 12).clamp(12.0, double.infinity),
          );
          final top = anchorPoint.dy.clamp(
            12.0,
            (constraints.maxHeight - height - 12).clamp(12.0, double.infinity),
          );
          return Stack(
            children: [
              Positioned(
                left: left,
                top: top,
                width: width,
                height: height,
                child: Material(
                  elevation: 12,
                  borderRadius: BorderRadius.circular(16),
                  clipBehavior: Clip.antiAlias,
                  child: BookmarkAssignmentMenu(
                    selections: selections,
                    state: state,
                    passage: origin,
                    verse: verse.verse,
                    quote: selected?.quote ?? verse.text,
                    reference: reference,
                    start: selected?.range.start,
                    end: selected?.range.end,
                    onAdd: (groupId) async {
                      if (!ownsVerse()) {
                        throw StateError(
                          UiStrings.of(context).text(
                            'This passage changed. Reopen its bookmark menu.',
                          ),
                        );
                      }
                      if (selections != null) {
                        await state.markTextSelections(
                          origin,
                          selections,
                          chapter!.bookName,
                          groupId,
                        );
                      } else {
                        await state.markWholeVerse(verse, reference, groupId);
                      }
                    },
                    onOpenTopic: (id) {
                      openTopic = true;
                      selectedGroup = id;
                      Navigator.of(dialogContext).pop();
                    },
                    onClose: () => Navigator.of(dialogContext).pop(),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    ),
  );
  if (!anchor.mounted || !ownsVerse()) return;
  if (previousFocus?.context != null) previousFocus!.requestFocus();
  if (openTopic) onOpenTopic?.call(selectedGroup);
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
      title: Text(UiStrings.of(context).text('Choose a marking')),
      content: SizedBox(
        width: 560,
        height: (MediaQuery.sizeOf(context).height * 0.65)
            .clamp(320, 560)
            .toDouble(),
        child: Column(
          children: <Widget>[
            TextField(
              autofocus: true,
              decoration: InputDecoration(
                hintText: UiStrings.of(context).text('Find a marking group'),
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
          child: Text(UiStrings.of(context).text('Cancel')),
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
            onPressed: state.retryReading,
            child: Text(UiStrings.of(context).text('Retry')),
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
        ? UiStrings.of(context).text('Verified cached Scripture')
        : UiStrings.of(
            context,
          ).text('Offline cached Scripture — verification unavailable');
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
