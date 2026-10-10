import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../core/errors.dart';
import '../core/ui_strings.dart';
import '../data/api/api_configuration.dart';
import '../data/api/getbible_api_client.dart';
import '../data/api/query_api_client.dart';
import '../data/database/local_database.dart';
import '../data/offline/bible_resource_installer.dart';
import '../data/offline/study_resource_installer.dart';
import '../data/repositories/api_query_repository.dart';
import '../data/repositories/api_search_repository.dart';
import '../data/repositories/cached_bible_repository.dart';
import '../data/repositories/installed_bible_repository.dart';
import '../data/repositories/installed_query_repository.dart';
import '../data/repositories/installed_search_repository.dart';
import '../data/repositories/sql_annotation_repository.dart';
import '../data/repositories/sql_private_data_repository.dart';
import '../data/repositories/sql_settings_repository.dart';
import '../data/repositories/sql_unified_bookmarks_repository.dart';
import '../domain/models/annotations.dart';
import '../domain/models/bible.dart';
import '../domain/models/cache.dart';
import '../domain/models/offline_resource.dart';
import '../domain/models/online_search.dart';
import '../domain/models/passage.dart';
import '../domain/models/preferences.dart';
import '../domain/models/search.dart';
import '../domain/repositories/notebook_repository.dart';
import '../services/daily_scripture_service.dart';
import '../services/scripture_text.dart';
import 'daily_scripture_resolver.dart';
import 'grouped_reference_lookup.dart';
import 'offline_controller.dart';
import 'online_search_controller.dart';
import 'portability_controller.dart';
import 'study_services.dart';
import 'unified_bookmarks_controller.dart';

export '../domain/models/preferences.dart'
    show AppearanceMode, ReaderLayout, ReadingWidth;

final class AppState extends ChangeNotifier {
  AppState._(
    this.database,
    this.bibles,
    this.annotations,
    this.settings,
    this.referenceLookup,
    this._api,
    this.onlineSearch,
    this.study,
    this.offline,
  ) {
    bookmarks = UnifiedBookmarksController(
      storage: SqlUnifiedBookmarksRepository(database),
      publicTopics: study.topics.repository,
      onChanged: () async {
        preferences = await settings.getPreferences();
        await refreshAnnotations();
      },
    );
    onlineSearch.addListener(_searchChanged);
    offline.addListener(_offlineChanged);
    portability = PortabilityController(
      repository: SqlPrivateDataRepository(database),
      beforeSnapshot: _flushPrivateDrafts,
      afterImport: _refreshImportedData,
    );
  }

  /// Compose persistent reader and preview operations with one injectable HTTP
  /// boundary. Tests use the same composition as the app's startup.
  factory AppState.fromDatabase(
    LocalDatabase database, {
    GetBibleApiClient? api,
    NotebookRepository? notebookRepository,
  }) {
    final GetBibleApiClient client = api ?? GetBibleApiClient();
    final SqlOfflineResourceStore offlineStore = SqlOfflineResourceStore(
      database,
    );
    final InstalledBibleRepository installed = InstalledBibleRepository(
      offlineStore,
      sourceUri: client.transport.configuration
          .endpoint(ApiService.bible)
          .baseUri,
    );
    final CachedBibleRepository repository = CachedBibleRepository(
      database,
      client,
      installed: installed,
    );
    final InstalledQueryRepository query = InstalledQueryRepository(
      installed: installed,
      online: ApiQueryRepository(QueryApiClient(transport: client.transport)),
    );
    final offline = OfflineController(
      store: offlineStore,
      freshness: SqlOfflineFreshnessStore(database),
      clearPublicCaches: () async {
        await repository.clearPublicCache();
        client.transport.clearCache();
      },
      installers: [
        BibleResourceInstaller(client.transport),
        for (final kind in [
          OfflineResourceKind.dictionary,
          OfflineResourceKind.commentary,
          OfflineResourceKind.bookmarks,
        ])
          StudyResourceInstaller(client.transport, kind),
      ],
    );
    return AppState._(
      database,
      repository,
      SqlAnnotationRepository(database),
      SqlSettingsRepository(database),
      GroupedReferenceLookup(
        bibleRepository: repository,
        queryRepository: query,
      ),
      client,
      OnlineSearchController(
        repository: ApiSearchRepository(client.transport),
        isTranslationInstalled: (translation) => offline.installed.any(
          (item) =>
              item.resource.kind == OfflineResourceKind.bible &&
              item.resource.id == translation.toLowerCase() &&
              item.resource.sourceUri == installed.sourceUri,
        ),
        installedRepository: InstalledSearchRepository(
          installed: installed,
          query: query,
        ),
      ),
      StudyServices(
        database: database,
        transport: client.transport,
        notebookRepository: notebookRepository,
        offlineStore: offlineStore,
        captureResourceUse: (kind) {
          final epoch = offline.contentEpoch;
          return (id) => unawaited(
            offline.ensureAvailable(kind, id, expectedEpoch: epoch),
          );
        },
      ),
      offline,
    );
  }

  static Future<AppState> create({bool initialize = true}) async {
    final database = await LocalDatabase.open();
    AppState? state;
    try {
      state = AppState.fromDatabase(database);
      if (initialize) await state.initialize();
      return state;
    } catch (_) {
      try {
        if (state == null) {
          await database.close();
        } else {
          await state.close();
        }
      } catch (_) {
        /* Preserve the original startup failure. */
      }
      rethrow;
    }
  }

  final StudyServices study;
  late final UnifiedBookmarksController bookmarks;
  final OfflineController offline;
  late final PortabilityController portability;
  final OnlineSearchController onlineSearch;
  final GroupedReferenceLookup referenceLookup;
  final GetBibleApiClient _api;

  final LocalDatabase database;
  final CachedBibleRepository bibles;
  final SqlAnnotationRepository annotations;
  final SqlSettingsRepository settings;

  ReaderPreferences preferences = const ReaderPreferences();
  Passage passage = const Passage(translation: 'kjv', book: 49, chapter: 5);
  List<Translation> translations = const [];
  List<BibleBook> books = const [];
  List<ChapterInfo> chapters = const [];
  BibleChapter? current;
  CacheFreshness? freshness;
  bool legacyScripture = false;
  List<MarkingGroup> groups = const [];
  List<Marking> markings = const [];
  List<VerseNote> notes = const [];
  List<Marking> savedMarkings = const [];
  List<VerseNote> savedNotes = const [];
  UiStrings ui = UiStrings.english;
  bool loading = true;
  String? error;
  List<int> _dailyVerses = const <int>[];

  /// The complete temporary daily selection; never stored as private markings.
  List<int> get dailyVerses => _dailyVerses;
  int _passageRequest = 0;
  int _passageContentEpoch = 0;
  int _beginPassageRequest() {
    _passageContentEpoch = offline.contentEpoch;
    return ++_passageRequest;
  }

  int? _dailyRequest;
  Future<void>? _closeFuture;
  bool _closing = false;
  String _installedSignature = '';
  Future<void>? _resourceRefresh;
  String? resourceChoicesError;
  Uri? _failedLink;
  bool readerNavigationBlocked = false;
  Future<void>? _positionWrite;

  bool get searchLoading => onlineSearch.isLoading;
  String? get searchError => onlineSearch.error?.toString();
  List<SearchVerse> get searchResults => onlineSearch.results
      .map((OnlineSearchHit hit) => hit.toSearchVerse())
      .toList(growable: false);
  bool get searchComplete => !onlineSearch.canLoadMore;
  void _searchChanged() => notifyListeners();

  void _offlineChanged() {
    if (_closing) return;
    final signature = offline.installed
        .map((item) => '${item.resource.key}:${item.generation}')
        .join('\n');
    if (signature == _installedSignature) return;
    _installedSignature = signature;
    // A download may finish after its setup route closes. Refresh only local
    // discovery and status; never reset an open Study entry or start HTTP.
    unawaited(refreshInstalledResourceChoices().catchError((Object _) {}));
  }

  Translation? get currentTranslation => translations
      .where((Translation item) => item.abbreviation == passage.translation)
      .firstOrNull;

  bool get isUiRtl => currentTranslation?.isRtl ?? false;

  int get searchResultCount => onlineSearch.total;

  MarkingGroup? get activeGroup => groups
      .where((MarkingGroup item) => item.id == preferences.activeMarkingGroupId)
      .firstOrNull;

  bool get canGoPrevious {
    final int bookIndex = books.indexWhere(
      (BibleBook item) => item.number == passage.book,
    );
    final int chapterIndex = chapters.indexWhere(
      (ChapterInfo item) => item.chapter == passage.chapter,
    );
    return chapterIndex > 0 || bookIndex > 0;
  }

  bool get canGoNext {
    final int bookIndex = books.indexWhere(
      (BibleBook item) => item.number == passage.book,
    );
    final int chapterIndex = chapters.indexWhere(
      (ChapterInfo item) => item.chapter == passage.chapter,
    );
    return chapterIndex >= 0 &&
        (chapterIndex < chapters.length - 1 ||
            (bookIndex >= 0 && bookIndex < books.length - 1));
  }

  Future<void> initialize({Uri? initialUri}) async {
    try {
      // Recover local generations first. The offline coordinator schedules
      // background Study downloads and due checks without blocking the reader.
      await offline.initialize();
      await _resourceRefresh;
      preferences = await settings.getPreferences();
      final LastReadingPosition? last = await settings.getLastReadingPosition();
      groups = await annotations.getGroups();
      if (initialUri != null && initialUri.toString() != '/') {
        await openPassageLink(initialUri);
      } else if (last != null) {
        passage = last.passage.copyWith(
          verse: last.verse > 0 ? last.verse : null,
        );
        await loadPassage(passage);
      } else {
        await openDailyScripture();
      }
    } catch (exception) {
      error = exception.toString();
      loading = false;
      notifyListeners();
    }
  }

  /// Retrying a failed daily lookup must not open the initial reader default.
  Future<void> retryReading() => _failedLink != null
      ? openPassageLink(_failedLink!)
      : _dailyRequest == _passageRequest
      ? openDailyScripture()
      : loadPassage(passage);

  /// Resolve published friendly names against this Bible's own catalogue.
  /// An invalid, missing or ambiguous source never becomes the default passage.
  Future<void> openPassageLink(Uri uri) async {
    if (_closing) return;
    if (readerNavigationBlocked) {
      _failedLink = uri;
      error = 'Save or close the verse note before opening another passage.';
      notifyListeners();
      return;
    }
    final request = _beginPassageRequest();
    _failedLink = uri;
    loading = true;
    error = null;
    notifyListeners();
    try {
      final link = parsePassageLink(uri);
      if (link == null) {
        throw const FormatException('This Scripture link is invalid.');
      }
      final result = await bibles.getBooks(link.translation);
      if (request != _passageRequest) return;
      final matches = result.data
          .where((book) => bookMatchesSlug(book.name, link.bookSlug))
          .toList();
      if (matches.length != 1) {
        throw const FormatException(
          'The linked book is unavailable or ambiguous in this Bible.',
        );
      }
      await _loadPassage(
        Passage(
          translation: link.translation,
          book: matches.single.number,
          chapter: link.chapter,
          verse: link.verse,
        ),
        request,
      );
      if (request == _passageRequest && error == null) _failedLink = null;
    } catch (exception) {
      if (request == _passageRequest) error = exception.toString();
    } finally {
      if (request == _passageRequest) {
        loading = false;
        notifyListeners();
      }
    }
  }

  /// Save the first visible source verse without changing the selected passage
  /// or browser history. Serialized writes cannot restore an older chapter over
  /// a later navigation, including when SQLite is temporarily slow.
  Future<void> recordReadingPosition(int verse) {
    if (_closing ||
        loading ||
        current == null ||
        !current!.verses.any((item) => item.verse == verse)) {
      return Future.value();
    }
    return _savePosition(passage, verse);
  }

  Future<void> _savePosition(Passage source, int verse) {
    final previous = _positionWrite;
    late final Future<void> next;
    next =
        () async {
          if (previous != null) {
            try {
              await previous;
            } catch (_) {}
          }
          await settings.saveLastReadingPosition(
            LastReadingPosition(
              passage: source,
              verse: verse,
              updatedAt: DateTime.now().toUtc(),
            ),
          );
        }().whenComplete(() {
          // Retain only in-flight work. Completed futures may belong to a caller's
          // scheduling zone, and shutdown should not depend on that zone staying
          // alive after its reader surface has been disposed.
          if (identical(_positionWrite, next)) _positionWrite = null;
        });
    _positionWrite = next;
    return next;
  }

  Future<void> openDailyScripture() async {
    if (_closing) return;
    _failedLink = null;
    final int request = _beginPassageRequest();
    _dailyRequest = request;
    loading = true;
    error = null;
    notifyListeners();
    try {
      final DateTime now = DateTime.now();
      DailyScriptureCache? daily;
      try {
        daily = await settings.getDailyScripture();
      } catch (_) {
        // A corrupt or unreadable public cache is a cache miss, not a reason
        // to redirect the reader to a different passage.
      }
      if (request != _passageRequest) return;
      if (daily == null ||
          !daily.isCurrent(now) ||
          !daily.hasCompleteSelection) {
        daily = parseDailyScripture(await bibles.getDailyScripture(), now);
        if (request != _passageRequest) return;
        try {
          await settings.saveDailyScripture(daily);
        } catch (_) {
          // Reading a valid public feed does not depend on cache persistence.
        }
      }
      if (request != _passageRequest) return;
      final RepositoryResult<List<BibleBook>> bookResult = await bibles
          .getBooks('kjv');
      if (request != _passageRequest) return;
      final Passage target = await DailyScriptureResolver(
        referenceLookup,
      ).resolve(daily, bookResult.data);
      if (request != _passageRequest) return;
      await _loadPassage(target, request, dailyVerses: daily.verses);
    } catch (exception) {
      if (request == _passageRequest) error = exception.toString();
    } finally {
      if (request == _passageRequest && loading) {
        loading = false;
        notifyListeners();
      }
    }
  }

  Future<void> loadPassage(Passage next, {bool Function()? ownsRequest}) {
    if (_closing) return Future<void>.value();
    _failedLink = null;
    return _loadPassage(next, _beginPassageRequest(), ownsRequest: ownsRequest);
  }

  Future<void> _loadPassage(
    Passage next,
    int request, {
    bool Function()? ownsRequest,
    List<int> dailyVerses = const <int>[],
  }) async {
    final contentEpoch = _passageContentEpoch;
    loading = true;
    error = null;
    notifyListeners();
    try {
      final RepositoryResult<List<Translation>> translationResult = await bibles
          .getTranslations();
      final RepositoryResult<List<BibleBook>> bookResult = await bibles
          .getBooks(next.translation);
      if (request != _passageRequest || ownsRequest?.call() == false) return;
      if (!bookResult.data.any((BibleBook item) => item.number == next.book)) {
        throw const FormatException(
          'That book is not available in this translation.',
        );
      }
      final RepositoryResult<List<ChapterInfo>> chapterIndexResult =
          await bibles.getChapters(next.translation, next.book);
      if (request != _passageRequest || ownsRequest?.call() == false) return;
      if (!chapterIndexResult.data.any(
        (ChapterInfo item) => item.chapter == next.chapter,
      )) {
        throw const FormatException(
          'That chapter is not available in this translation.',
        );
      }
      final RepositoryResult<BibleChapter> chapterResult = await bibles
          .getChapter(next.translation, next.book, next.chapter);
      if (request != _passageRequest || ownsRequest?.call() == false) return;
      if (next.verse != null &&
          !chapterResult.data.verses.any(
            (Verse item) => item.verse == next.verse,
          )) {
        throw const FormatException(
          'That verse is not available in this translation.',
        );
      }
      if (dailyVerses.any(
        (int verse) =>
            !chapterResult.data.verses.any((Verse item) => item.verse == verse),
      )) {
        throw const FormatException(
          'Some daily Scripture verses are unavailable in KJV. '
          'Your reading position has been kept.',
        );
      }
      final List<Marking> nextMarkings = await annotations
          .getMarkingsForPassage(next);
      final List<VerseNote> nextNotes = await annotations.getNotesForPassage(
        next,
      );
      final List<Marking> nextSavedMarkings = await annotations.getMarkings();
      final List<VerseNote> nextSavedNotes = await annotations.getNotes();
      final String? language = translationResult.data
          .where((Translation item) => item.abbreviation == next.translation)
          .firstOrNull
          ?.lang;
      final UiStrings nextUi = await UiStrings.load(language);
      if (request != _passageRequest || ownsRequest?.call() == false) return;
      translations = translationResult.data;
      books = bookResult.data;
      chapters = chapterIndexResult.data;
      if (passage.translation != next.translation) onlineSearch.clear();
      passage = next;
      current = chapterResult.data;
      _dailyVerses = List<int>.unmodifiable(dailyVerses);
      ui = nextUi;
      freshness = chapterResult.freshness;
      legacyScripture = chapterResult.isLegacy;
      markings = nextMarkings;
      notes = nextNotes;
      savedMarkings = nextSavedMarkings;
      savedNotes = nextSavedNotes;
      // Only an activated reader passage selects a Bible for offline use.
      // Preview lookups and stale navigation must never download other Bibles.
      unawaited(
        offline.ensureAvailable(
          OfflineResourceKind.bible,
          next.translation,
          expectedEpoch: contentEpoch,
        ),
      );
      await _savePosition(
        next,
        next.verse ?? chapterResult.data.verses.firstOrNull?.verse ?? 0,
      );
    } catch (exception) {
      if (request == _passageRequest && ownsRequest?.call() != false) {
        error = exception.toString();
      }
    } finally {
      if (request == _passageRequest) {
        loading = false;
        notifyListeners();
      }
    }
  }

  /// A book opens at its discovered first chapter or its introduction node.
  Future<void> openBook(int book, {bool atEnd = false}) async {
    if (_closing) return;
    _failedLink = null;
    final int request = _beginPassageRequest();
    final String translation = passage.translation;
    loading = true;
    error = null;
    notifyListeners();
    try {
      final RepositoryResult<List<ChapterInfo>> result = await bibles
          .getChapters(translation, book);
      if (request != _passageRequest) return;
      if (result.data.isEmpty) {
        throw const FormatException(
          'This book has no published chapters or introduction.',
        );
      }
      await _loadPassage(
        Passage(
          translation: translation,
          book: book,
          chapter: (atEnd ? result.data.last : result.data.first).chapter,
        ),
        request,
      );
    } catch (exception) {
      if (request == _passageRequest) error = exception.toString();
    } finally {
      if (request == _passageRequest && loading) {
        loading = false;
        notifyListeners();
      }
    }
  }

  Future<void> turnChapter(int direction) async {
    if (direction == 0 || loading) return;
    final int chapterIndex = chapters.indexWhere(
      (ChapterInfo item) => item.chapter == passage.chapter,
    );
    final int bookIndex = books.indexWhere(
      (BibleBook item) => item.number == passage.book,
    );
    if (chapterIndex < 0 || bookIndex < 0) return;
    if (direction < 0) {
      if (chapterIndex > 0) {
        await loadPassage(
          passage.copyWith(
            chapter: chapters[chapterIndex - 1].chapter,
            clearVerse: true,
          ),
        );
      } else if (bookIndex > 0) {
        await openBook(books[bookIndex - 1].number, atEnd: true);
      }
      return;
    }
    if (chapterIndex < chapters.length - 1) {
      await loadPassage(
        passage.copyWith(
          chapter: chapters[chapterIndex + 1].chapter,
          clearVerse: true,
        ),
      );
    } else if (bookIndex < books.length - 1) {
      await openBook(books[bookIndex + 1].number);
    }
  }

  Future<void> selectActiveGroup(String groupId) async {
    await bookmarks.rememberGroup(groupId);
    preferences = preferences.copyWith(activeMarkingGroupId: groupId);
    await settings.savePreferences(preferences);
    notifyListeners();
  }

  Future<void> saveMarkingGroup({
    String? id,
    required String name,
    required String color,
  }) async {
    final String normalizedName = name.trim();
    final String normalizedColor = color.trim().toUpperCase();
    if (normalizedName.isEmpty ||
        !RegExp(r'^#[0-9A-F]{6}$').hasMatch(normalizedColor)) {
      throw const FormatException(
        'Enter a group name and a six-digit hex color.',
      );
    }
    final MarkingGroup? existing = id == null
        ? null
        : groups.where((MarkingGroup item) => item.id == id).firstOrNull;
    final MarkingGroup group = MarkingGroup(
      id: existing?.id ?? const Uuid().v4(),
      name: normalizedName,
      color: normalizedColor,
      sortOrder: existing?.sortOrder ?? groups.length,
      isStarter: existing?.isStarter ?? false,
      updatedAt: DateTime.now().toUtc(),
      source: existing?.source,
    );
    await annotations.saveGroup(group);
    groups = await annotations.getGroups();
    notifyListeners();
  }

  Future<void> deleteMarkingGroup(String groupId) async {
    if (groups.length <= 1) return;
    await annotations.deleteGroup(groupId);
    groups = await annotations.getGroups();
    markings = await annotations.getMarkingsForPassage(passage);
    savedMarkings = await annotations.getMarkings();
    if (!groups.any(
      (MarkingGroup item) => item.id == preferences.activeMarkingGroupId,
    )) {
      await selectActiveGroup(groups.first.id);
    }
    notifyListeners();
  }

  Future<void> markWholeVerse(
    Verse verse,
    String reference,
    String groupId,
  ) async {
    // A verse can belong to several topics and can independently retain a
    // public membership in the same group. Adding a personal membership must
    // never recolor by deleting other topic associations or private copies.
    final Marking add = Marking(
      id: const Uuid().v4(),
      passage: passage,
      verse: verse.verse,
      start: null,
      end: null,
      quote: verse.text,
      reference: reference,
      groupId: groupId,
      createdAt: DateTime.now().toUtc(),
    );
    await annotations.addMarkingMemberships(<Marking>[add]);
    await selectActiveGroup(groupId);
    await _refreshVisibleMarkings();
    savedMarkings = await annotations.getMarkings();
    notifyListeners();
  }

  Future<void> markSelectedText(
    Verse verse,
    int start,
    int end,
    String reference,
    String groupId,
  ) async {
    if (start < 0 || end <= start || end > verse.text.length) return;
    await annotations.addMarkingMemberships(<Marking>[
      Marking(
        id: const Uuid().v4(),
        passage: passage,
        verse: verse.verse,
        start: start,
        end: end,
        quote: verse.text.substring(start, end),
        reference: reference,
        groupId: groupId,
        createdAt: DateTime.now().toUtc(),
      ),
    ]);
    await selectActiveGroup(groupId);
    await _refreshVisibleMarkings();
    savedMarkings = await annotations.getMarkings();
    notifyListeners();
  }

  /// A native paragraph selection is saved as one transaction in its original
  /// passage. Presentation-generated separators never enter stored ranges.
  Future<void> markTextSelections(
    Passage origin,
    List<ScriptureVerseSelection> selections,
    String bookName,
    String groupId,
  ) async {
    if (origin != passage || selections.isEmpty) return;
    final List<Marking> additions = <Marking>[];
    for (final ScriptureVerseSelection selection in selections) {
      final Verse? currentVerse = current?.verses
          .where((Verse item) => item.verse == selection.verse.verse)
          .firstOrNull;
      if (currentVerse?.text != selection.verse.text ||
          !ScriptureTextMap(
            selection.verse.text,
          ).isValidRange(selection.range)) {
        return;
      }
      additions.add(
        Marking(
          id: const Uuid().v4(),
          passage: origin,
          verse: selection.verse.verse,
          start: selection.range.start,
          end: selection.range.end,
          quote: selection.quote,
          reference: '$bookName ${origin.chapter}:${selection.verse.verse}',
          groupId: groupId,
          createdAt: DateTime.now().toUtc(),
        ),
      );
    }
    await annotations.addMarkingMemberships(additions);
    await selectActiveGroup(groupId);
    await _refreshVisibleMarkings();
    savedMarkings = await annotations.getMarkings();
    notifyListeners();
  }

  Future<void> removeTextSelections(
    Passage origin,
    List<ScriptureVerseSelection> selections,
  ) async {
    if (origin != passage || selections.isEmpty) return;
    final List<Marking> remove = markings
        .where(
          (Marking marking) =>
              !marking.isWholeVerse &&
              marking.matchesPassage(origin) &&
              selections.any(
                (ScriptureVerseSelection selection) =>
                    marking.verse == selection.verse.verse &&
                    marking.start! < selection.range.end &&
                    marking.end! > selection.range.start,
              ),
        )
        .toList(growable: false);
    await annotations.replaceMarkings(remove, const <Marking>[]);
    await _refreshVisibleMarkings();
    savedMarkings = await annotations.getMarkings();
    notifyListeners();
  }

  Future<void> _refreshVisibleMarkings() async {
    final Passage origin = passage;
    final int request = _passageRequest;
    final List<Marking> visible = await annotations.getMarkingsForPassage(
      origin,
    );
    if (request == _passageRequest && passage == origin) markings = visible;
  }

  /// Removes only personal memberships, optionally in one chosen topic. A
  /// public association is removable explicitly from the saved-markings list.
  Future<void> removeWholeVerseMarking(int verse, {String? groupId}) async {
    final List<Marking> remove = markings
        .where(
          (Marking item) =>
              item.verse == verse &&
              item.isWholeVerse &&
              !item.isSharedBookmark &&
              (groupId == null || item.groupId == groupId),
        )
        .toList();
    await annotations.replaceMarkings(remove, const <Marking>[]);
    await _refreshVisibleMarkings();
    savedMarkings = await annotations.getMarkings();
    notifyListeners();
  }

  Future<void> deleteSavedMarking(String id) async {
    await annotations.deleteMarking(id);
    markings = await annotations.getMarkingsForPassage(passage);
    savedMarkings = await annotations.getMarkings();
    notifyListeners();
  }

  bool selectionHasMarking(int verse, int start, int end) => markings.any(
    (Marking item) =>
        item.verse == verse &&
        !item.isWholeVerse &&
        item.start! < end &&
        item.end! > start,
  );

  Future<void> removeSelectionMarkings(int verse, int start, int end) async {
    final List<Marking> remove = markings
        .where(
          (Marking item) =>
              item.verse == verse &&
              !item.isWholeVerse &&
              item.start! < end &&
              item.end! > start,
        )
        .toList();
    await annotations.replaceMarkings(remove, const <Marking>[]);
    markings = await annotations.getMarkingsForPassage(passage);
    savedMarkings = await annotations.getMarkings();
    notifyListeners();
  }

  Future<void> saveVerseNote(int verse, String reference, String text) async {
    final String value = text.trim();
    if (value.isEmpty) return;
    final VerseNote? existing = notes
        .where((VerseNote item) => item.verse == verse)
        .firstOrNull;
    final DateTime now = DateTime.now().toUtc();
    await annotations.saveNote(
      VerseNote(
        id: existing?.id ?? const Uuid().v4(),
        passage: passage,
        verse: verse,
        reference: reference,
        text: value,
        createdAt: existing?.createdAt ?? now,
        updatedAt: now,
      ),
    );
    notes = await annotations.getNotesForPassage(passage);
    savedNotes = await annotations.getNotes();
    notifyListeners();
  }

  Future<void> deleteVerseNote(int verse) async {
    await annotations.deleteNote('${passage.canonicalKey}/$verse');
    notes = await annotations.getNotesForPassage(passage);
    savedNotes = await annotations.getNotes();
    notifyListeners();
  }

  /// Legacy callers share the native Search UI's installed-first source choice.
  Future<void> search(String query, SearchOptions options) =>
      onlineSearch.search(
        passage.translation,
        query,
        criteria: OnlineSearchCriteria.fromOptions(
          options,
          diacritics:
              onlineSearch.defaultModeFor(passage.translation) ==
                  SearchExecutionMode.installed
              ? SearchDiacritics.exact
              : SearchDiacritics.fold,
        ),
        direction: current?.direction ?? currentTranslation?.direction ?? 'LTR',
      );

  Future<void> loadMoreSearchResults() => onlineSearch.loadMore();

  /// Explicit public-topic copying is followed by a fresh private annotation
  /// snapshot. Merely browsing/following a topic never calls this operation.
  Future<void> refreshAnnotations() async {
    groups = await annotations.getGroups();
    markings = await annotations.getMarkingsForPassage(passage);
    savedMarkings = await annotations.getMarkings();
    notes = await annotations.getNotesForPassage(passage);
    savedNotes = await annotations.getNotes();
    notifyListeners();
  }

  Future<void> setAppearance(AppearanceMode mode) async {
    preferences = preferences.copyWith(appearanceMode: mode);
    notifyListeners();
    await settings.savePreferences(preferences);
  }

  Future<void> setLayout(ReaderLayout layout) async {
    preferences = preferences.copyWith(layout: layout);
    notifyListeners();
    await settings.savePreferences(preferences);
  }

  Future<void> setSourceStyles(bool enabled) async {
    preferences = preferences.copyWith(showSourceStyles: enabled);
    notifyListeners();
    await settings.savePreferences(preferences);
  }

  Future<void> setAccessibility({
    bool? reduceMotion,
    bool? highContrast,
  }) async {
    preferences = preferences.copyWith(
      reduceMotion: reduceMotion,
      highContrast: highContrast,
    );
    notifyListeners();
    await settings.savePreferences(preferences);
  }

  Future<void> setTextSize(double size) async {
    preferences = preferences.copyWith(textSize: size);
    notifyListeners();
    await settings.savePreferences(preferences);
  }

  Future<void> setLightPalette(String palette) async {
    preferences = preferences.copyWith(lightPalette: palette);
    notifyListeners();
    await settings.savePreferences(preferences);
  }

  Future<void> setDarkPalette(String palette) async {
    preferences = preferences.copyWith(darkPalette: palette);
    notifyListeners();
    await settings.savePreferences(preferences);
  }

  Future<void> setReaderFont(String font) async {
    preferences = preferences.copyWith(readerFont: font);
    notifyListeners();
    await settings.savePreferences(preferences);
  }

  Future<void> setReadingWidth(ReadingWidth width) async {
    preferences = preferences.copyWith(readingWidth: width);
    notifyListeners();
    await settings.savePreferences(preferences);
  }

  /// Every caller awaits the same shutdown, including pending private writes.
  Future<void> close() =>
      _closeFuture ??= _close().catchError((Object error, StackTrace stack) {
        _closeFuture = null;
        _closing = false;
        portability.resume();
        offline.resume();
        bookmarks.resume();
        _offlineChanged();
        Error.throwWithStackTrace(error, stack);
      });

  Future<void> _close() async {
    _closing = true;
    onlineSearch.cancel(notify: false);
    await portability.close();
    await offline.close();
    await bookmarks.close();
    await _resourceRefresh;
    // Private durability is the reversible shutdown gate. If it fails, the
    // existing reader request and its loading state must remain usable.
    await _ensurePrivateDraftsDurable(
      ui.text(
        'The latest notebook changes could not be saved. Return to Notebooks and retry before closing.',
      ),
    );
    // Once that gate succeeds, cancel network activation before capturing the
    // final position-write drain. New navigation is blocked while _closing.
    _passageRequest++;
    loading = false;
    await _positionWrite;
    await study.close();
    onlineSearch.removeListener(_searchChanged);
    offline.removeListener(_offlineChanged);
    onlineSearch.dispose();
    portability.dispose();
    offline.dispose();
    bookmarks.dispose();
    _api.close();
    await database.close();
  }

  Future<void> _flushPrivateDrafts() => _ensurePrivateDraftsDurable(
    ui.text(
      'The notebook could not be saved or loaded. Your open draft is retained. {error}',
      {'error': ''},
    ).trim(),
  );

  Future<void> _ensurePrivateDraftsDurable(String failureMessage) async {
    await study.notebooks.flush();
    if (study.notebooks.hasUndurableDrafts) {
      throw StorageException(failureMessage);
    }
  }

  Future<void> _refreshImportedData() async {
    preferences = await settings.getPreferences();
    await study.notebooks.reloadAfterImport();
    study.reloadImportedPreferences();
    await bookmarks.reload();
  }

  /// Refresh visible choices after explicit setup without an online catalogue
  /// request. Existing online choices remain selectable when a download is
  /// removed; installation state is owned exclusively by the offline manager.
  Future<void> refreshInstalledResourceChoices() {
    if (_closing) return Future<void>.value();
    Future<void> refreshChoices() async {
      if (_closing) return;
      final installed = await bibles.installed!.getTranslations();
      if (_closing) return;
      translations = {
        for (final item in translations) item.abbreviation: item,
        for (final item in installed.data) item.abbreviation: item,
      }.values.toList()..sort((a, b) => a.translation.compareTo(b.translation));
      await study.refreshInstallationStatus();
      resourceChoicesError = null;
      if (!_closing) notifyListeners();
    }

    final previous = _resourceRefresh;
    final refresh = previous == null
        ? refreshChoices()
        : previous.then((_) => refreshChoices());
    _resourceRefresh = refresh.catchError((Object _) {
      resourceChoicesError =
          'Installed resource choices could not refresh. Open Offline resources to retry.';
      if (!_closing) notifyListeners();
    });
    return refresh;
  }
}
