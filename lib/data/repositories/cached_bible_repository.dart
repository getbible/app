import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../../core/errors.dart';
import '../../core/json.dart';
import '../../domain/models/bible.dart';
import '../../domain/models/cache.dart';
import '../../domain/repositories/bible_repository.dart';
import '../api/api_transport.dart';
import '../api/bible_bulk_parser.dart';
import '../api/getbible_api_client.dart';
import '../database/local_database.dart';
import 'installed_bible_repository.dart';

const Duration scriptureIndexMaxAge = Duration(days: 7);

/// The saved value is replaced only after source consistency and byte integrity
/// have both succeeded. Index changes expire verification, never readable text.
final class CachedBibleRepository implements BibleRepository {
  CachedBibleRepository(
    this._database,
    this._client, {
    DateTime Function()? clock,
    this.installed,
  }) : _clock = clock ?? DateTime.now,
       _identity = ScriptureCacheIdentity(
         apiVersion: _client.apiVersion,
         schemaVersion: bibleModelVersion,
         sourceScope: _client.cacheSourceScope,
       );
  final InstalledBibleRepository? installed;
  final LocalDatabase _database;
  final GetBibleApiClient _client;
  final DateTime Function() _clock;
  final ScriptureCacheIdentity _identity;
  // Navigation identifiers only, bounded to recently opened books. This keeps
  // a current no-store introduction selectable without retaining its body.
  final Map<String, Set<int>> _introductionIds = <String, Set<int>>{};
  String cacheKey(String resource) => _identity.key(resource);

  @override
  Future<RepositoryResult<List<Translation>>> getTranslations({
    bool forceRefresh = false,
  }) async {
    // Installed discovery succeeds after a cold restart with zero HTTP.
    if (!forceRefresh && installed != null) {
      final local = await installed!.getTranslations();
      if (local.data.isNotEmpty) {
        final cached = await _readList('translations', Translation.fromJson);
        final choices = <String, Translation>{
          if (cached != null)
            for (final item in _decodeList(cached, Translation.fromJson))
              item.abbreviation: item,
          for (final item in local.data) item.abbreviation: item,
        };
        return RepositoryResult(
          data: choices.values.toList(),
          freshness: local.freshness,
          checkedAt: local.checkedAt,
        );
      }
    }
    const String resource = 'translations';
    final CacheRecord? cached = await _readList(resource, Translation.fromJson);
    if (!forceRefresh && _isCurrent(cached)) {
      return _cachedList(cached!, Translation.fromJson);
    }
    try {
      final BibleApiDocument<List<Translation>> fresh = await _client
          .getTranslationsDocument();
      if (cached != null) {
        final Map<String, Translation> previous = {
          for (final item in _decodeList(cached, Translation.fromJson))
            item.abbreviation: item,
        };
        final Map<String, Translation> current = {
          for (final item in fresh.value) item.abbreviation: item,
        };
        for (final id in previous.keys) {
          if (previous[id]!.sha != current[id]?.sha) {
            await _invalidateTranslation(id);
          }
        }
      }
      return _storeList(
        resource,
        'translations',
        fresh,
        (item) => item.toJson(),
      );
    } catch (error, stack) {
      return _fallbackList(
        resource,
        cached,
        Translation.fromJson,
        error,
        stack,
      );
    }
  }

  @override
  Future<RepositoryResult<List<BibleBook>>> getBooks(
    String translation, {
    bool forceRefresh = false,
  }) async {
    final String abbreviation = translation.toLowerCase();
    if (installed != null && await installed!.contains(abbreviation)) {
      return installed!.getBooks(abbreviation);
    }
    final String resource = 'books:$abbreviation';
    final CacheRecord? cached = await _readList(resource, BibleBook.fromJson);
    if (!forceRefresh && _isCurrent(cached)) {
      return _cachedList(cached!, BibleBook.fromJson);
    }
    try {
      final BibleApiDocument<List<BibleBook>> fresh = await _client
          .getBooksDocument(abbreviation);
      if (cached != null) {
        final Map<int, BibleBook> previous = {
          for (final item in _decodeList(cached, BibleBook.fromJson))
            item.number: item,
        };
        final Map<int, BibleBook> current = {
          for (final item in fresh.value) item.number: item,
        };
        for (final id in previous.keys) {
          if (previous[id]!.sha != current[id]?.sha) {
            await _database.deleteCache(cacheKey('chapters:$abbreviation:$id'));
            await _database.invalidateCachePrefix(
              cacheKey('chapter:$abbreviation:$id'),
            );
            await _database.invalidateCachePrefix(
              cacheKey('book:$abbreviation:$id'),
            );
          }
        }
      }
      return _storeList(resource, 'books', fresh, (item) => item.toJson());
    } catch (error, stack) {
      return _fallbackList(resource, cached, BibleBook.fromJson, error, stack);
    }
  }

  @override
  Future<RepositoryResult<List<ChapterInfo>>> getChapters(
    String translation,
    int book, {
    bool forceRefresh = false,
  }) async {
    final String abbreviation = translation.toLowerCase();
    if (installed != null && await installed!.contains(abbreviation)) {
      return installed!.getChapters(abbreviation, book);
    }
    final String resource = 'chapters:$abbreviation:$book';
    final CacheRecord? cached = await _readList(resource, ChapterInfo.fromJson);
    if (!forceRefresh && _isCurrent(cached)) {
      return _cachedList(cached!, ChapterInfo.fromJson);
    }
    BibleApiDocument<List<ChapterInfo>>? index;
    try {
      Object? indexError;
      try {
        index = await _client.getChaptersDocument(abbreviation, book);
      } catch (error) {
        indexError = error;
      }
      // The book representation is required to discover nested introduction
      // records that deliberately have no standalone chapter URL.
      final RepositoryResult<WholeTranslationBook> source =
          await getBookContent(abbreviation, book);
      final List<ChapterInfo> data = <ChapterInfo>[...?index?.value];
      for (final WholeTranslationChapter chapter in source.data.chapters) {
        if (chapter.isIntroduction &&
            !data.any((item) => item.chapter == chapter.chapter)) {
          data.add(
            ChapterInfo(
              chapter: chapter.chapter,
              name: chapter.name,
              sha: '',
              isIntroduction: true,
              nestedChapter: chapter,
            ),
          );
        }
      }
      if (source.data.titles.isNotEmpty ||
          source.data.introduction.isNotEmpty) {
        if (!data.any((item) => item.chapter == 0)) {
          final WholeTranslationChapter introduction = WholeTranslationChapter(
            chapter: 0,
            name: source.data.name,
            verses: const <Verse>[],
            titles: source.data.titles,
            introduction: source.data.introduction,
          );
          data.add(
            ChapterInfo(
              chapter: 0,
              name: source.data.name,
              sha: '',
              isIntroduction: true,
              nestedChapter: introduction,
            ),
          );
        }
      }
      // If the index failed, regular nested chapters remain trustworthy book
      // content, but they must not acquire invented source hashes/URLs.
      if (index == null) {
        for (final chapter in source.data.chapters) {
          if (!data.any((item) => item.chapter == chapter.chapter)) {
            data.add(
              ChapterInfo(
                chapter: chapter.chapter,
                name: chapter.name,
                sha: '',
              ),
            );
          }
        }
      }
      if (data.isEmpty) {
        throw indexError ??
            const ApiFormatException(
              'This book has no readable chapters or introductions.',
            );
      }
      data.sort((left, right) => left.chapter.compareTo(right.chapter));
      _introductionIds.remove(resource);
      _introductionIds[resource] = data
          .where((item) => item.isIntroduction)
          .map((item) => item.chapter)
          .toSet();
      while (_introductionIds.length > 16) {
        _introductionIds.remove(_introductionIds.keys.first);
      }
      if (cached != null && index != null) {
        final Map<int, ChapterInfo> previous = {
          for (final item in _decodeList(cached, ChapterInfo.fromJson))
            item.chapter: item,
        };
        final Map<int, ChapterInfo> current = {
          for (final item in data) item.chapter: item,
        };
        for (final id in previous.keys) {
          if (previous[id]!.sha != current[id]?.sha) {
            await _database.invalidateCachePrefix(
              cacheKey('chapter:$abbreviation:$book:$id'),
            );
          }
        }
      }
      final DateTime now = _now();
      // Book-only discovery may be saved for offline navigation but is never
      // reused as a fresh HTTP index without verification.
      if (source.mayPersist && index?.response.cachePolicy.noStore != true) {
        await _write(
          resource,
          'chapters',
          '',
          data.map((item) => item.toJson()).toList(),
          now,
          response: data.any((item) => item.isIntroduction)
              ? null
              : index?.response,
        );
      }
      return RepositoryResult(
        data: data,
        freshness: source.isVerified
            ? CacheFreshness.fresh
            : CacheFreshness.cachedUnverified,
        checkedAt: now,
        isLegacy: source.isLegacy,
        sourceApiVersion: source.sourceApiVersion,
      );
    } catch (error, stack) {
      // A valid chapter index is useful even if fetching optional book metadata
      // fails, particularly for a small, ordinary online Scripture read.
      if (index != null && index.value.isNotEmpty) {
        return _storeList(resource, 'chapters', index, (item) => item.toJson());
      }
      return _fallbackList(
        resource,
        cached,
        ChapterInfo.fromJson,
        error,
        stack,
      );
    }
  }

  @override
  Future<RepositoryResult<BibleChapter>> getChapter(
    String translation,
    int book,
    int chapter,
  ) async {
    final String abbreviation = translation.toLowerCase();
    if (installed != null && await installed!.contains(abbreviation)) {
      return installed!.getChapter(abbreviation, book, chapter);
    }
    final String resource = 'chapter:$abbreviation:$book:$chapter';
    final CacheRecord? cached = await _readObject(
      resource,
      BibleChapter.fromJson,
    );
    try {
      final CacheRecord? index = await _readList(
        'chapters:$abbreviation:$book',
        ChapterInfo.fromJson,
      );
      ChapterInfo? node;
      if (index != null) {
        for (final item in _decodeList(index, ChapterInfo.fromJson)) {
          if (item.chapter == chapter) {
            node = item;
            break;
          }
        }
      }
      if (chapter == 0 ||
          node?.isIntroduction == true ||
          (_introductionIds['chapters:$abbreviation:$book']?.contains(
                chapter,
              ) ??
              false)) {
        final source = await getBookContent(abbreviation, book);
        final WholeTranslationChapter? nested = _introChapter(
          source.data,
          chapter,
        );
        if (nested == null) {
          throw const ApiFormatException(
            'The requested introduction is unavailable in this source.',
          );
        }
        return RepositoryResult(
          data: _fromNested(source.data, nested, abbreviation),
          freshness: source.freshness,
          checkedAt: source.checkedAt,
          isLegacy: source.isLegacy,
          sourceApiVersion: source.sourceApiVersion,
        );
      }
      final String before = await _client.getChapterSha(
        abbreviation,
        book,
        chapter,
      );
      if (cached != null &&
          cached.sha == before &&
          _digest(cached.json) == before) {
        final DateTime now = _now();
        try {
          await _database.touchCache(cached.key, now);
        } catch (_) {}
        return RepositoryResult(
          data: BibleChapter.fromJson(jsonDecode(cached.json)),
          freshness: CacheFreshness.cachedVerified,
          checkedAt: now,
        );
      }
      final BibleApiDocument<BibleChapter> fresh = await _consistent(
        () => _client.getChapterDocument(abbreviation, book, chapter),
        () => _client.getChapterSha(abbreviation, book, chapter),
        initialSha: before,
      );
      final DateTime now = _now();
      await _write(
        resource,
        'chapter',
        fresh.digest,
        fresh.value.toJson(),
        now,
        response: fresh.response,
        rawJson: fresh.rawJson,
      );
      return RepositoryResult(
        data: fresh.value,
        freshness: CacheFreshness.fresh,
        checkedAt: now,
      );
    } catch (_) {
      final CacheRecord? legacy = cached == null
          ? await _readLegacyObject(resource, BibleChapter.fromJson)
          : null;
      final CacheRecord? fallback = cached ?? legacy;
      if (fallback == null) rethrow;
      return RepositoryResult(
        data: BibleChapter.fromJson(jsonDecode(fallback.json)),
        freshness: CacheFreshness.cachedUnverified,
        checkedAt: fallback.checkedAt,
        isLegacy: legacy != null,
        sourceApiVersion: legacy != null ? 'v2' : _identity.apiVersion,
      );
    }
  }

  Future<RepositoryResult<WholeTranslationBook>> getBookContent(
    String translation,
    int book,
  ) async {
    final String abbreviation = translation.toLowerCase();
    final String resource = 'book:$abbreviation:$book';
    final cached = await _readBulk<WholeTranslationBook>(
      cacheKey(resource),
      (raw) => BibleBulkParser.bookText(
        raw,
        abbreviation: abbreviation,
        number: book,
      ),
    );
    try {
      final String before = await _client.getBookSha(abbreviation, book);
      if (cached != null &&
          cached.$1.sha == before &&
          cached.$2.digest == before) {
        return RepositoryResult(
          data: cached.$2.value,
          freshness: CacheFreshness.cachedVerified,
          checkedAt: _now(),
        );
      }
      final fresh = await _consistent(
        () => _client.getBookDocument(abbreviation, book),
        () => _client.getBookSha(abbreviation, book),
        initialSha: before,
      );
      final DateTime now = _now();
      await _write(
        resource,
        'book',
        fresh.digest,
        fresh.value.toJson(),
        now,
        response: fresh.response,
        rawJson: fresh.rawJson,
      );
      return RepositoryResult(
        data: fresh.value,
        freshness: CacheFreshness.fresh,
        checkedAt: now,
        mayPersist: !fresh.response.cachePolicy.noStore,
      );
    } catch (_) {
      if (cached == null) rethrow;
      return RepositoryResult(
        data: cached.$2.value,
        freshness: CacheFreshness.cachedUnverified,
        checkedAt: cached.$1.checkedAt,
      );
    }
  }

  @override
  Future<RepositoryResult<WholeTranslation>> getWholeTranslation(
    Translation translation,
  ) async {
    if (installed != null &&
        await installed!.contains(translation.abbreviation)) {
      return installed!.getWholeTranslation(translation);
    }
    final String resource = 'full:${translation.abbreviation}';
    final cached = await _readBulk<WholeTranslation>(
      cacheKey(resource),
      (raw) => BibleBulkParser.translationText(
        raw,
        abbreviation: translation.abbreviation,
      ),
    );
    try {
      final String before = await _client.getTranslationSha(
        translation.abbreviation,
      );
      if (cached != null &&
          cached.$1.sha == before &&
          cached.$2.digest == before) {
        return RepositoryResult(
          data: cached.$2.value,
          freshness: CacheFreshness.cachedVerified,
          checkedAt: _now(),
        );
      }
      final fresh = await _consistent(
        () => _client.getWholeTranslationDocument(translation.abbreviation),
        () => _client.getTranslationSha(translation.abbreviation),
        initialSha: before,
      );
      final DateTime now = _now();
      await _write(
        resource,
        'fullTranslation',
        fresh.digest,
        fresh.value.toJson(),
        now,
        response: fresh.response,
        rawJson: fresh.rawJson,
      );
      return RepositoryResult(
        data: fresh.value,
        freshness: CacheFreshness.fresh,
        checkedAt: now,
      );
    } catch (_) {
      final legacy = cached == null
          ? await _readBulk<WholeTranslation>(
              ScriptureCacheIdentity.legacy.key(resource),
              (raw) => BibleBulkParser.translationText(
                raw,
                abbreviation: translation.abbreviation,
              ),
            )
          : null;
      final fallback = cached ?? legacy;
      if (fallback == null) rethrow;
      return RepositoryResult(
        data: fallback.$2.value,
        freshness: CacheFreshness.cachedUnverified,
        checkedAt: fallback.$1.checkedAt,
        isLegacy: legacy != null,
        sourceApiVersion: legacy != null ? 'v2' : _identity.apiVersion,
      );
    }
  }

  Future<(CacheRecord, ParsedBibleSource<T>)?> _readBulk<T>(
    String key,
    Future<ParsedBibleSource<T>> Function(String) parse,
  ) async {
    CacheRecord? record;
    try {
      record = await _database.readCache(key);
    } catch (_) {
      return null;
    }
    if (record == null) return null;
    try {
      return (record, await parse(record.json));
    } catch (_) {
      try {
        await _database.deleteCache(key);
      } catch (_) {}
      return null;
    }
  }

  @override
  Future<void> clearScriptureCache() {
    _introductionIds.clear();
    return _database.clearScriptureCache();
  }

  Future<JsonMap> getDailyScripture() => _client.getDailyScripture();

  Future<BibleApiDocument<T>> _consistent<T>(
    Future<BibleApiDocument<T>> Function() download,
    Future<String> Function() getSha, {
    required String initialSha,
  }) async {
    String before = initialSha;
    for (int attempt = 0; attempt < 2; attempt++) {
      final BibleApiDocument<T> document = await download();
      final String after = await getSha();
      if (before == after && document.digest == after) return document;
      _client.transport.discardResponse(document.response);
      before = after;
    }
    throw const ApiFormatException(
      'The Scripture source changed or its exact bytes failed SHA-1 verification.',
    );
  }

  WholeTranslationChapter? _introChapter(
    WholeTranslationBook book,
    int chapter,
  ) {
    for (final item in book.chapters) {
      if (item.chapter == chapter && item.isIntroduction) return item;
    }
    if (chapter == 0 &&
        (book.titles.isNotEmpty || book.introduction.isNotEmpty)) {
      return WholeTranslationChapter(
        chapter: 0,
        name: book.name,
        verses: const <Verse>[],
        titles: book.titles,
        introduction: book.introduction,
      );
    }
    return null;
  }

  BibleChapter _fromNested(
    WholeTranslationBook book,
    WholeTranslationChapter chapter,
    String abbreviation,
  ) => chapter.toBibleChapter(
    abbreviation: abbreviation,
    bookNumber: book.number,
    bookName: book.name,
    translation: optionalString(book.extra, 'translation'),
    language: optionalString(book.extra, 'language'),
    direction: optionalString(book.extra, 'direction', 'LTR'),
  );
  Future<void> _invalidateTranslation(String id) async {
    await _database.deleteCachePrefix(cacheKey('books:$id'));
    await _database.deleteCachePrefix(cacheKey('chapters:$id'));
    await _database.invalidateCachePrefix(cacheKey('chapter:$id'));
    await _database.invalidateCachePrefix(cacheKey('book:$id'));
    await _database.invalidateCachePrefix(cacheKey('full:$id'));
  }

  DateTime _now() => _clock().toUtc();
  String _digest(String raw) => sha1.convert(utf8.encode(raw)).toString();
  bool _isCurrent(CacheRecord? record) =>
      record != null &&
      !record.mustRevalidate &&
      record.freshUntil != null &&
      _now().isBefore(record.freshUntil!) &&
      _now().difference(record.checkedAt) < scriptureIndexMaxAge;
  List<T> _decodeList<T>(CacheRecord record, T Function(Object?) parse) =>
      requireJsonList(
        jsonDecode(record.json),
        record.kind,
      ).map(parse).toList(growable: false);
  RepositoryResult<List<T>> _cachedList<T>(
    CacheRecord record,
    T Function(Object?) parse, {
    bool verified = true,
    bool legacy = false,
  }) => RepositoryResult(
    data: _decodeList(record, parse),
    freshness: verified
        ? CacheFreshness.cachedVerified
        : CacheFreshness.cachedUnverified,
    checkedAt: record.checkedAt,
    isLegacy: legacy,
    sourceApiVersion: legacy ? 'v2' : _identity.apiVersion,
  );
  Future<RepositoryResult<List<T>>> _fallbackList<T>(
    String resource,
    CacheRecord? cached,
    T Function(Object?) parse,
    Object error,
    StackTrace stack,
  ) async {
    if (cached != null) return _cachedList(cached, parse, verified: false);
    final CacheRecord? legacy = await _readLegacyList(resource, parse);
    if (legacy != null) {
      return _cachedList(legacy, parse, verified: false, legacy: true);
    }
    Error.throwWithStackTrace(error, stack);
  }

  Future<RepositoryResult<List<T>>> _storeList<T>(
    String resource,
    String kind,
    BibleApiDocument<List<T>> data,
    JsonMap Function(T) serialize,
  ) async {
    final DateTime now = _now();
    await _write(
      resource,
      kind,
      '',
      data.value.map(serialize).toList(),
      now,
      response: data.response,
    );
    return RepositoryResult(
      data: data.value,
      freshness: CacheFreshness.fresh,
      checkedAt: now,
    );
  }

  Future<CacheRecord?> _readList<T>(
    String resource,
    T Function(Object?) parse,
  ) => _validate(cacheKey(resource), (record) => _decodeList(record, parse));
  Future<CacheRecord?> _readObject<T>(
    String resource,
    T Function(Object?) parse,
  ) =>
      _validate(cacheKey(resource), (record) => parse(jsonDecode(record.json)));
  Future<CacheRecord?> _readLegacyList<T>(
    String resource,
    T Function(Object?) parse,
  ) => _validate(
    ScriptureCacheIdentity.legacy.key(resource),
    (record) => _decodeList(record, parse),
  );
  Future<CacheRecord?> _readLegacyObject<T>(
    String resource,
    T Function(Object?) parse,
  ) => _validate(
    ScriptureCacheIdentity.legacy.key(resource),
    (record) => parse(jsonDecode(record.json)),
  );
  Future<CacheRecord?> _validate(
    String key,
    Object? Function(CacheRecord) parse,
  ) async {
    final CacheRecord? record = await _database.readCache(key);
    if (record == null) return null;
    try {
      parse(record);
      return record;
    } catch (_) {
      try {
        await _database.deleteCache(key);
      } catch (_) {}
      return null;
    }
  }

  Future<void> _write(
    String resource,
    String kind,
    String hash,
    Object payload,
    DateTime now, {
    ApiResponse? response,
    String? rawJson,
  }) async {
    if (response?.cachePolicy.noStore == true) return;
    try {
      final Duration lifetime =
          response?.cachePolicy.remainingLifetime(now) ?? Duration.zero;
      await _database.writeCache(
        key: cacheKey(resource),
        kind: kind,
        sha: hash,
        payload: payload,
        checkedAt: now,
        rawJson: rawJson,
        freshUntil: lifetime > Duration.zero ? now.add(lifetime) : null,
        mustRevalidate: response?.cachePolicy.noCache ?? true,
      );
    } catch (_) {
      /* Local storage failure must not hide validated network Scripture. */
    }
  }
}
