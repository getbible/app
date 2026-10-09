import '../../core/request_cancellation.dart';
import '../../domain/models/bible.dart';
import '../../domain/models/offline_resource.dart';
import '../../domain/models/reference.dart';
import '../../domain/repositories/query_repository.dart';
import 'installed_bible_repository.dart';

/// Installed Bibles resolve their own published book names, chapter identities
/// and verse ranges. Unsupported aliases never trigger an online substitution.
final class InstalledQueryRepository implements QueryRepository {
  InstalledQueryRepository({required this.installed, required this.online});
  final InstalledBibleRepository installed;
  final QueryRepository online;

  @override
  Future<ReferenceResult> query(
    String translation,
    String reference, {
    RequestCancellation? cancellation,
  }) async {
    cancellation?.throwIfCancelled();
    final snapshot = await installed.snapshot(translation);
    if (snapshot == null) {
      return online.query(translation, reference, cancellation: cancellation);
    }
    return queryAt(snapshot, reference, cancellation: cancellation);
  }

  Future<ReferenceResult> queryAt(
    OfflineInstalledResource snapshot,
    String reference, {
    RequestCancellation? cancellation,
  }) async {
    final parts = reference.trim().split(';');
    if (reference.runes.length > 512 ||
        parts.isEmpty ||
        parts.length > 8 ||
        parts.any((part) => part.trim().isEmpty) ||
        RegExp(r'[\x00-\x1f\x7f]').hasMatch(reference)) {
      throw const ReferenceLookupException(
        'Use up to 8 references and 512 characters.',
      );
    }
    final books = await installed.booksAt(snapshot);
    // Longest names first prevents a numbered or extended name being treated
    // as a shorter name followed by a chapter suffix.
    books.sort((a, b) => b.name.length.compareTo(a.name.length));
    final selected = <String, ReferenceChapter>{};
    for (final input in parts) {
      cancellation?.throwIfCancelled();
      BibleBook? book;
      RegExpMatch? match;
      for (final candidate in books) {
        final pattern = RegExp(
          '^${RegExp.escape(candidate.name).replaceAll(' ', r'\s*')}\\s*(\\d+)(?::([\\d,\\s-]+))?\$',
          caseSensitive: false,
          unicode: true,
        );
        final found = pattern.firstMatch(input.trim());
        if (found != null) {
          book = candidate;
          match = found;
          break;
        }
      }
      if (book == null || match == null) {
        throw const ReferenceLookupException(
          'This offline reference is unavailable. Use a published book name followed by chapter and optional verses, for example John 3:16-18.',
        );
      }
      final chapterId = int.tryParse(match.group(1)!);
      if (chapterId == null || chapterId < 1) {
        throw const ReferenceLookupException(
          'Scripture chapters must be positive.',
        );
      }
      final chapter = await installed.chapterAt(
        snapshot,
        book.number,
        chapterId,
      );
      final wanted = <int>{};
      if (match.group(2) == null) {
        wanted.addAll(chapter.verses.map((verse) => verse.verse));
      } else {
        for (final range in match.group(2)!.split(',')) {
          final bounds = RegExp(
            r'^\s*(\d+)\s*(?:-\s*(\d+)\s*)?$',
          ).firstMatch(range);
          if (bounds == null) {
            throw const ReferenceLookupException(
              'Enter valid verse numbers or inclusive ranges.',
            );
          }
          final first = int.tryParse(bounds.group(1)!);
          final last = int.tryParse(bounds.group(2) ?? bounds.group(1)!);
          if (first == null ||
              last == null ||
              first < 1 ||
              last < first ||
              last - first >= 200) {
            throw const ReferenceLookupException(
              'Select up to 200 verses in ascending ranges.',
            );
          }
          for (int verse = first; verse <= last; verse++) {
            wanted.add(verse);
          }
        }
      }
      if (wanted.isEmpty ||
          !chapter.verses
              .map((verse) => verse.verse)
              .toSet()
              .containsAll(wanted)) {
        throw const ReferenceLookupException(
          'One or more selected verses are unavailable in this installed Bible.',
        );
      }
      final key = '${snapshot.resource.id}_${book.number}_$chapterId';
      final previous = selected[key];
      wanted.addAll(
        previous?.verses.map((verse) => verse.verse) ?? const <int>[],
      );
      selected[key] = ReferenceChapter(
        key: key,
        bookNumber: book.number,
        chapter: chapterId,
        verses: chapter.verses.where((verse) => wanted.contains(verse.verse)),
        references: {...?previous?.references, input.trim()},
        bookName: book.name,
        direction: chapter.direction,
        metadata: {...chapter.extra}..remove('editorial'),
      );
      if (selected.values.fold<int>(
            0,
            (count, item) => count + item.verses.length,
          ) >
          200) {
        throw const ReferenceLookupException(
          'Select no more than 200 verses per reference request.',
        );
      }
    }
    cancellation?.throwIfCancelled();
    // Removal/update during a read must not publish a successful mixed snapshot.
    if ((await installed.snapshot(snapshot.resource.id))?.generation !=
        snapshot.generation) {
      throw const ReferenceLookupException(
        'The installed Bible changed. Retry this reference.',
      );
    }
    return ReferenceResult(
      translation: snapshot.resource.id,
      chapters: selected.values,
      requestedReferences: parts,
    );
  }
}
