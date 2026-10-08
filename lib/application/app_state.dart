import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../core/ui_strings.dart';
import '../data/api/getbible_api_client.dart';
import '../data/api/query_api_client.dart';
import '../data/database/local_database.dart';
import '../data/repositories/api_query_repository.dart';
import '../data/repositories/cached_bible_repository.dart';
import '../data/repositories/sql_annotation_repository.dart';
import '../data/repositories/sql_settings_repository.dart';
import '../domain/models/annotations.dart';
import '../domain/models/bible.dart';
import '../domain/models/cache.dart';
import '../domain/models/passage.dart';
import '../domain/models/preferences.dart';
import '../domain/models/search.dart';
import '../services/daily_scripture_service.dart';
import '../services/scripture_text.dart';
import '../services/search_service.dart';
import 'grouped_reference_lookup.dart';

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
  );

  /// Compose persistent reader and preview operations with one injectable HTTP
  /// boundary. Tests use the same composition as the app's startup.
  factory AppState.fromDatabase(
    LocalDatabase database, {
    GetBibleApiClient? api,
  }) {
    final GetBibleApiClient client = api ?? GetBibleApiClient();
    final CachedBibleRepository repository = CachedBibleRepository(
      database,
      client,
    );
    return AppState._(
      database,
      repository,
      SqlAnnotationRepository(database),
      SqlSettingsRepository(database),
      GroupedReferenceLookup(
        bibleRepository: repository,
        queryRepository: ApiQueryRepository(
          QueryApiClient(transport: client.transport),
        ),
      ),
      client,
    );
  }

  static Future<AppState> create({bool initialize = true}) async {
    final AppState state = AppState.fromDatabase(await LocalDatabase.open());
    if (initialize) await state.initialize();
    return state;
  }

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
  bool searchLoading = false;
  String? searchError;
  List<SearchVerse> searchResults = const [];
  List<SearchVerse> _allSearchResults = const [];
  bool searchComplete = true;
  int _passageRequest = 0;
  int _searchRequest = 0;

  Translation? get currentTranslation => translations
      .where((Translation item) => item.abbreviation == passage.translation)
      .firstOrNull;

  bool get isUiRtl => currentTranslation?.isRtl ?? false;

  int get searchResultCount => _allSearchResults.length;

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

  Future<void> initialize() async {
    try {
      preferences = await settings.getPreferences();
      final LastReadingPosition? last = await settings.getLastReadingPosition();
      groups = await annotations.getGroups();
      if (last != null) {
        passage = last.passage;
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

  Future<void> openDailyScripture() async {
    final DateTime now = DateTime.now();
    DailyScriptureCache? daily = await settings.getDailyScripture();
    if (daily == null || !daily.isCurrent(now)) {
      try {
        daily = parseDailyScripture(await bibles.getDailyScripture(), now);
        await settings.saveDailyScripture(daily);
      } catch (_) {
        if (daily == null) {
          await loadPassage(
            const Passage(translation: 'kjv', book: 49, chapter: 5),
          );
          return;
        }
      }
    }
    final DailyScriptureCache resolvedDaily = daily;
    final RepositoryResult<List<BibleBook>> bookResult = await bibles.getBooks(
      'kjv',
    );
    final String dailyBookName = resolvedDaily.bookName;
    final BibleBook? book = bookResult.data
        .where((BibleBook item) => bookMatchesSlug(item.name, dailyBookName))
        .firstOrNull;
    if (book == null) {
      await loadPassage(
        const Passage(translation: 'kjv', book: 49, chapter: 5),
      );
      return;
    }
    await loadPassage(
      Passage(
        translation: 'kjv',
        book: book.number,
        chapter: resolvedDaily.chapter,
        verse: resolvedDaily.verse,
      ),
    );
  }

  Future<void> loadPassage(Passage next, {bool Function()? ownsRequest}) =>
      _loadPassage(next, ++_passageRequest, ownsRequest: ownsRequest);

  Future<void> _loadPassage(
    Passage next,
    int request, {
    bool Function()? ownsRequest,
  }) async {
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
      passage = next;
      current = chapterResult.data;
      ui = nextUi;
      freshness = chapterResult.freshness;
      legacyScripture = chapterResult.isLegacy;
      markings = nextMarkings;
      notes = nextNotes;
      savedMarkings = nextSavedMarkings;
      savedNotes = nextSavedNotes;
      await settings.saveLastReadingPosition(
        LastReadingPosition(
          passage: next,
          verse:
              next.verse ?? chapterResult.data.verses.firstOrNull?.verse ?? 0,
          updatedAt: DateTime.now().toUtc(),
        ),
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
    final int request = ++_passageRequest;
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
    final List<Marking> remove = markings
        .where((Marking item) => item.verse == verse.verse && item.isWholeVerse)
        .toList();
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
    await annotations.replaceMarkings(remove, <Marking>[add]);
    await selectActiveGroup(groupId);
    markings = await annotations.getMarkingsForPassage(passage);
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
    await annotations.saveMarking(
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
    );
    await selectActiveGroup(groupId);
    markings = await annotations.getMarkingsForPassage(passage);
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
    await annotations.replaceMarkings(const <Marking>[], additions);
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

  Future<void> removeWholeVerseMarking(int verse) async {
    final List<Marking> remove = markings
        .where((Marking item) => item.verse == verse && item.isWholeVerse)
        .toList();
    await annotations.replaceMarkings(remove, const <Marking>[]);
    markings = await annotations.getMarkingsForPassage(passage);
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

  Future<void> search(String query, SearchOptions options) async {
    final int request = ++_searchRequest;
    searchLoading = true;
    searchError = null;
    searchResults = const <SearchVerse>[];
    _allSearchResults = const <SearchVerse>[];
    searchComplete = false;
    notifyListeners();
    try {
      final Translation? translation = currentTranslation;
      if (translation == null) {
        throw StateError('The selected translation is unavailable.');
      }
      final RepositoryResult<WholeTranslation> corpus = await bibles
          .getWholeTranslation(translation);
      final List<SearchVerse> results = await searchTranslation(
        corpus.data,
        query,
        options,
      );
      if (request != _searchRequest) return;
      _allSearchResults = results;
      searchResults = results.take(20).toList(growable: false);
      searchComplete = searchResults.length >= results.length;
    } catch (exception) {
      if (request == _searchRequest) searchError = exception.toString();
    } finally {
      if (request == _searchRequest) {
        searchLoading = false;
        notifyListeners();
      }
    }
  }

  void loadMoreSearchResults() {
    if (searchLoading || searchComplete) return;
    final int requested = searchResults.length + 20;
    final int nextLength = requested > _allSearchResults.length
        ? _allSearchResults.length
        : requested;
    searchResults = _allSearchResults.take(nextLength).toList(growable: false);
    searchComplete = nextLength >= _allSearchResults.length;
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

  Future<void> close() async {
    _passageRequest++;
    _searchRequest++;
    _api.close();
    await database.close();
  }
}
