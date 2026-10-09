import 'dart:convert';

import '../../core/json.dart';
import '../../domain/models/bible.dart';
import '../../domain/models/cache.dart';
import '../../domain/models/offline_resource.dart';
import '../../domain/repositories/bible_repository.dart';
import '../../domain/repositories/offline_resource_repository.dart';

/// Reads only an activated, source-scoped installation. No operation issues HTTP
/// or interprets the opportunistic chapter cache as a complete installation.
final class InstalledBibleRepository implements BibleRepository {
  InstalledBibleRepository(this.store, {required this.sourceUri});
  final OfflineResourceStore store;
  final Uri sourceUri;
  Future<OfflineInstalledResource?> snapshot(String translation) => store.find(
    OfflineResourceKind.bible,
    translation.toLowerCase(),
    sourceUri,
  );
  Future<bool> contains(String translation) async =>
      await snapshot(translation) != null;

  Future<OfflineInstalledResource> requireSnapshot(String translation) async =>
      await snapshot(translation) ??
      (throw const FormatException(
        'Install this Bible from Offline resources before using it offline.',
      ));
  Future<Object?> document(
    OfflineInstalledResource installed,
    String path,
  ) async {
    final raw = await store.readDocument(
      installed.resource.key,
      path,
      generation: installed.generation,
    );
    if (raw == null) {
      throw const FormatException(
        'The installed Bible is unavailable or has changed. Please reopen it or reinstall the resource.',
      );
    }
    return jsonDecode(raw);
  }

  RepositoryResult<T> _result<T>(T data, OfflineInstalledResource snapshot) =>
      RepositoryResult(
        data: data,
        freshness: CacheFreshness.cachedVerified,
        checkedAt: snapshot.installedAt,
      );

  @override
  Future<RepositoryResult<List<Translation>>> getTranslations({
    bool forceRefresh = false,
  }) async {
    final installations = (await store.listInstalled())
        .where(
          (item) =>
              item.resource.kind == OfflineResourceKind.bible &&
              item.resource.sourceUri == sourceUri,
        )
        .toList();
    final translations = <Translation>[];
    for (final installed in installations) {
      translations.add(
        Translation.fromJson(await document(installed, 'translation')),
      );
    }
    translations.sort((a, b) => a.translation.compareTo(b.translation));
    return RepositoryResult(
      data: translations,
      freshness: CacheFreshness.cachedVerified,
      checkedAt: installations.isEmpty
          ? DateTime.fromMillisecondsSinceEpoch(0, isUtc: true)
          : installations.last.installedAt,
    );
  }

  @override
  Future<RepositoryResult<List<BibleBook>>> getBooks(
    String translation, {
    bool forceRefresh = false,
  }) async {
    final installed = await requireSnapshot(translation);
    return _result(await booksAt(installed), installed);
  }

  Future<List<BibleBook>> booksAt(OfflineInstalledResource installed) async =>
      requireJsonList(
        await document(installed, 'books'),
        'installed books',
      ).map(BibleBook.fromJson).toList();

  @override
  Future<RepositoryResult<List<ChapterInfo>>> getChapters(
    String translation,
    int book, {
    bool forceRefresh = false,
  }) async {
    final installed = await requireSnapshot(translation);
    return _result(await chaptersAt(installed, book), installed);
  }

  Future<List<ChapterInfo>> chaptersAt(
    OfflineInstalledResource installed,
    int book,
  ) async => requireJsonList(
    await document(installed, 'chapters/$book'),
    'installed chapter index',
  ).map(ChapterInfo.fromJson).toList();

  @override
  Future<RepositoryResult<BibleChapter>> getChapter(
    String translation,
    int book,
    int chapter,
  ) async {
    final installed = await requireSnapshot(translation);
    return _result(await chapterAt(installed, book, chapter), installed);
  }

  Future<BibleChapter> chapterAt(
    OfflineInstalledResource installed,
    int book,
    int chapter,
  ) async {
    final result = BibleChapter.fromJson(
      await document(installed, 'chapter/$book/$chapter'),
    );
    if (result.abbreviation != installed.resource.id ||
        result.bookNumber != book ||
        result.chapter != chapter) {
      throw const FormatException(
        'The installed Scripture identity is invalid.',
      );
    }
    return result;
  }

  @override
  Future<RepositoryResult<WholeTranslation>> getWholeTranslation(
    Translation translation,
  ) async {
    final installed = await requireSnapshot(translation.abbreviation);
    final books = <WholeTranslationBook>[];
    for (final book in await booksAt(installed)) {
      final chapters = <WholeTranslationChapter>[];
      for (final node in await chaptersAt(installed, book.number)) {
        if (node.chapter > 0) {
          final chapter = await chapterAt(installed, book.number, node.chapter);
          chapters.add(
            WholeTranslationChapter(
              chapter: chapter.chapter,
              name: chapter.name,
              verses: chapter.verses,
              source: chapter.source,
              editorial: chapter.editorial,
              titles: chapter.titles,
              introduction: chapter.introduction,
            ),
          );
        }
      }
      books.add(
        WholeTranslationBook(
          number: book.number,
          name: book.name,
          chapters: chapters,
          titles: book.titles,
          introduction: book.introduction,
          source: {
            ...book.toJson(),
            'chapters': chapters.map((chapter) => chapter.toJson()).toList(),
          },
        ),
      );
    }
    final metadata = Translation.fromJson(
      await document(installed, 'translation'),
    );
    if ((await snapshot(translation.abbreviation))?.generation !=
        installed.generation) {
      throw const FormatException(
        'The installed Bible changed. Please reopen it.',
      );
    }
    // Records were individually validated while reading; do not decode or
    // deep-copy an entire translation again on the presentation isolate.
    return _result(
      WholeTranslation(
        translation: metadata.translation,
        abbreviation: metadata.abbreviation,
        language: metadata.language,
        lang: metadata.lang,
        direction: metadata.direction,
        books: books,
        titles: metadata.titles,
        introduction: metadata.introduction,
        source: {
          ...metadata.toJson(),
          'books': books.map((book) => book.toJson()).toList(),
        },
      ),
      installed,
    );
  }

  /// Cache removal cannot uninstall deliberately installed public resources.
  @override
  Future<void> clearScriptureCache() async {}
}
