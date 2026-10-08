import 'dart:convert';

import '../../core/errors.dart';
import '../../core/json.dart';
import '../../domain/models/bible.dart';
import '../../domain/models/cache.dart';
import '../../domain/repositories/bible_repository.dart';
import '../api/getbible_api_client.dart';
import '../database/local_database.dart';

const Duration scriptureIndexMaxAge = Duration(days: 7);

final class CachedBibleRepository implements BibleRepository {
  CachedBibleRepository(
    this._database,
    this._client, {
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final LocalDatabase _database;
  final GetBibleApiClient _client;
  final DateTime Function() _clock;

  @override
  Future<RepositoryResult<List<Translation>>> getTranslations({
    bool forceRefresh = false,
  }) async {
    const String key = 'translations';
    CacheRecord? cached = await _database.readCache(key);
    cached = await _validateListCache(key, cached, Translation.fromJson);
    if (!forceRefresh && _isCurrent(cached)) {
      return _cachedList(cached!, Translation.fromJson);
    }
    try {
      final List<Translation> fresh = await _client.getTranslations();
      if (cached != null) {
        final List<Translation> previous = _decodeList(
          cached,
          Translation.fromJson,
        );
        final Map<String, Translation> previousById = <String, Translation>{
          for (final Translation item in previous) item.abbreviation: item,
        };
        for (final Translation item in fresh) {
          if (previousById[item.abbreviation]?.sha != item.sha) {
            await _database.deleteCachePrefix('books:${item.abbreviation}');
            await _database.deleteCachePrefix('chapters:${item.abbreviation}:');
            await _database.deleteCachePrefix('chapter:${item.abbreviation}:');
            await _database.deleteCachePrefix('full:${item.abbreviation}');
          }
        }
      }
      return _storeList(
        key,
        'translations',
        '',
        fresh,
        (Translation item) => item.toJson(),
      );
    } catch (_) {
      if (cached != null) {
        return _cachedList(cached, Translation.fromJson, false);
      }
      rethrow;
    }
  }

  @override
  Future<RepositoryResult<List<BibleBook>>> getBooks(
    String translation, {
    bool forceRefresh = false,
  }) async {
    final String abbreviation = translation.toLowerCase();
    final String key = 'books:$abbreviation';
    CacheRecord? cached = await _database.readCache(key);
    cached = await _validateListCache(key, cached, BibleBook.fromJson);
    if (!forceRefresh && _isCurrent(cached)) {
      return _cachedList(cached!, BibleBook.fromJson);
    }
    try {
      final List<BibleBook> fresh = await _client.getBooks(abbreviation);
      if (cached != null) {
        final Map<int, BibleBook> previous = <int, BibleBook>{
          for (final BibleBook item in _decodeList(cached, BibleBook.fromJson))
            item.number: item,
        };
        for (final BibleBook item in fresh) {
          if (previous[item.number]?.sha != item.sha) {
            await _database.deleteCachePrefix(
              'chapters:$abbreviation:${item.number}',
            );
            await _database.deleteCachePrefix(
              'chapter:$abbreviation:${item.number}:',
            );
          }
        }
      }
      return _storeList(
        key,
        'books',
        '',
        fresh,
        (BibleBook item) => item.toJson(),
      );
    } catch (_) {
      if (cached != null) return _cachedList(cached, BibleBook.fromJson, false);
      rethrow;
    }
  }

  @override
  Future<RepositoryResult<List<ChapterInfo>>> getChapters(
    String translation,
    int book, {
    bool forceRefresh = false,
  }) async {
    final String abbreviation = translation.toLowerCase();
    final String key = 'chapters:$abbreviation:$book';
    CacheRecord? cached = await _database.readCache(key);
    cached = await _validateListCache(key, cached, ChapterInfo.fromJson);
    if (!forceRefresh && _isCurrent(cached)) {
      return _cachedList(cached!, ChapterInfo.fromJson);
    }
    try {
      final List<ChapterInfo> fresh = await _client.getChapters(
        abbreviation,
        book,
      );
      if (cached != null) {
        final Map<int, ChapterInfo> previous = <int, ChapterInfo>{
          for (final ChapterInfo item in _decodeList(
            cached,
            ChapterInfo.fromJson,
          ))
            item.chapter: item,
        };
        for (final ChapterInfo item in fresh) {
          if (previous[item.chapter]?.sha != item.sha) {
            await _database.deleteCachePrefix(
              'chapter:$abbreviation:$book:${item.chapter}',
            );
          }
        }
      } else {
        for (final ChapterInfo item in fresh) {
          final CacheRecord? chapterCache = await _database.readCache(
            'chapter:$abbreviation:$book:${item.chapter}',
          );
          if (chapterCache != null && chapterCache.sha != item.sha) {
            await _database.deleteCachePrefix(
              'chapter:$abbreviation:$book:${item.chapter}',
            );
          }
        }
      }
      return _storeList(
        key,
        'chapters',
        '',
        fresh,
        (ChapterInfo item) => item.toJson(),
      );
    } catch (_) {
      if (cached != null) {
        return _cachedList(cached, ChapterInfo.fromJson, false);
      }
      rethrow;
    }
  }

  @override
  Future<RepositoryResult<BibleChapter>> getChapter(
    String translation,
    int book,
    int chapter,
  ) async {
    final String abbreviation = translation.toLowerCase();
    final String key = 'chapter:$abbreviation:$book:$chapter';
    CacheRecord? cached = await _database.readCache(key);
    cached = await _validateObjectCache(key, cached, BibleChapter.fromJson);
    try {
      final String sha = await _client.getChapterSha(
        abbreviation,
        book,
        chapter,
      );
      if (cached != null && cached.sha == sha) {
        final DateTime now = _now();
        try {
          await _database.touchCache(key, now);
        } catch (_) {
          // Verification succeeded, so a bookkeeping failure must not hide the
          // usable chapter from the reader.
        }
        return RepositoryResult<BibleChapter>(
          data: BibleChapter.fromJson(jsonDecode(cached.json)),
          freshness: CacheFreshness.cachedVerified,
          checkedAt: now,
        );
      }
      final (BibleChapter, String) consistent =
          await _downloadConsistentChapter(
            abbreviation,
            book,
            chapter,
            initialSha: sha,
          );
      final BibleChapter fresh = consistent.$1;
      final String confirmedSha = consistent.$2;
      final DateTime now = _now();
      await _writeCacheBestEffort(
        key: key,
        kind: 'chapter',
        sha: confirmedSha,
        payload: fresh.toJson(),
        checkedAt: now,
      );
      return RepositoryResult<BibleChapter>(
        data: fresh,
        freshness: CacheFreshness.fresh,
        checkedAt: now,
      );
    } catch (_) {
      if (cached == null) rethrow;
      return RepositoryResult<BibleChapter>(
        data: BibleChapter.fromJson(jsonDecode(cached.json)),
        freshness: CacheFreshness.cachedUnverified,
        checkedAt: cached.checkedAt,
      );
    }
  }

  @override
  Future<RepositoryResult<WholeTranslation>> getWholeTranslation(
    Translation translation,
  ) async {
    final String key = 'full:${translation.abbreviation}';
    CacheRecord? cached = await _database.readCache(key);
    cached = await _validateObjectCache(key, cached, WholeTranslation.fromJson);
    if (cached != null && cached.sha == translation.sha) {
      return RepositoryResult<WholeTranslation>(
        data: WholeTranslation.fromJson(jsonDecode(cached.json)),
        freshness: CacheFreshness.cachedVerified,
        checkedAt: cached.checkedAt,
      );
    }
    try {
      final WholeTranslation fresh = await _client.getWholeTranslation(
        translation.abbreviation,
      );
      final DateTime now = _now();
      await _writeCacheBestEffort(
        key: key,
        kind: 'fullTranslation',
        sha: translation.sha,
        payload: fresh.toJson(),
        checkedAt: now,
      );
      return RepositoryResult<WholeTranslation>(
        data: fresh,
        freshness: CacheFreshness.fresh,
        checkedAt: now,
      );
    } catch (_) {
      if (cached == null) rethrow;
      return RepositoryResult<WholeTranslation>(
        data: WholeTranslation.fromJson(jsonDecode(cached.json)),
        freshness: CacheFreshness.cachedUnverified,
        checkedAt: cached.checkedAt,
      );
    }
  }

  @override
  Future<void> clearScriptureCache() => _database.clearCache();

  Future<JsonMap> getDailyScripture() => _client.getDailyScripture();

  Future<(BibleChapter, String)> _downloadConsistentChapter(
    String translation,
    int book,
    int chapter, {
    required String initialSha,
  }) async {
    String before = initialSha;
    for (int attempt = 0; attempt < 2; attempt++) {
      final BibleChapter payload = await _client.getChapter(
        translation,
        book,
        chapter,
      );
      final String after = await _client.getChapterSha(
        translation,
        book,
        chapter,
      );
      if (before == after) return (payload, after);
      before = after;
    }
    throw const ApiFormatException(
      'The Scripture chapter changed repeatedly while it was downloading.',
    );
  }

  DateTime _now() => _clock().toUtc();

  bool _isCurrent(CacheRecord? record) =>
      record != null &&
      _now().difference(record.checkedAt) < scriptureIndexMaxAge;

  RepositoryResult<List<T>> _cachedList<T>(
    CacheRecord record,
    T Function(Object?) parse, [
    bool verified = true,
  ]) => RepositoryResult<List<T>>(
    data: _decodeList(record, parse),
    freshness: verified
        ? CacheFreshness.cachedVerified
        : CacheFreshness.cachedUnverified,
    checkedAt: record.checkedAt,
  );

  List<T> _decodeList<T>(CacheRecord record, T Function(Object?) parse) =>
      requireJsonList(
        jsonDecode(record.json),
        record.kind,
      ).map(parse).toList(growable: false);

  Future<RepositoryResult<List<T>>> _storeList<T>(
    String key,
    String kind,
    String sha,
    List<T> data,
    JsonMap Function(T) serialize,
  ) async {
    final DateTime now = _now();
    await _writeCacheBestEffort(
      key: key,
      kind: kind,
      sha: sha,
      payload: data.map(serialize).toList(),
      checkedAt: now,
    );
    return RepositoryResult<List<T>>(
      data: data,
      freshness: CacheFreshness.fresh,
      checkedAt: now,
    );
  }

  Future<CacheRecord?> _validateListCache<T>(
    String key,
    CacheRecord? record,
    T Function(Object?) parse,
  ) async {
    if (record == null) return null;
    try {
      _decodeList(record, parse);
      return record;
    } catch (_) {
      await _discardCorruptedCache(key);
      return null;
    }
  }

  Future<CacheRecord?> _validateObjectCache<T>(
    String key,
    CacheRecord? record,
    T Function(Object?) parse,
  ) async {
    if (record == null) return null;
    try {
      parse(jsonDecode(record.json));
      return record;
    } catch (_) {
      await _discardCorruptedCache(key);
      return null;
    }
  }

  Future<void> _discardCorruptedCache(String key) async {
    try {
      await _database.deleteCachePrefix(key);
    } catch (_) {
      // The bad value is ignored for this request even if storage is already
      // failing and cannot remove it permanently.
    }
  }

  Future<void> _writeCacheBestEffort({
    required String key,
    required String kind,
    required String sha,
    required Object payload,
    required DateTime checkedAt,
  }) async {
    try {
      await _database.writeCache(
        key: key,
        kind: kind,
        sha: sha,
        payload: payload,
        checkedAt: checkedAt,
      );
    } catch (_) {
      // Fresh network content remains useful even when local storage is full,
      // read-only, or temporarily unavailable.
    }
  }
}
