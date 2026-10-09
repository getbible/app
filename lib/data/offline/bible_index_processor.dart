import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../../core/json.dart';
import '../../domain/models/bible.dart';

/// Runs exclusively in a worker. Each yielded envelope is acknowledged before
/// the next one is produced, bounding database writes and UI-isolate messages.
Iterable<Map<String, Object?>> indexBibleSource(
  List<int> bytes,
  String abbreviation,
  String expectedSha,
) sync* {
  if (sha1.convert(bytes).toString() != expectedSha) {
    throw const FormatException(
      'The downloaded Bible failed SHA-1 verification.',
    );
  }
  final source = requireJsonMap(
    jsonDecode(utf8.decode(bytes)),
    'installed Bible',
  );
  final bible = WholeTranslation.fromJson(source);
  if (bible.abbreviation != abbreviation || bible.books.isEmpty) {
    throw const FormatException(
      'The downloaded Bible has the wrong identity or no books.',
    );
  }
  final metadata = Map<String, Object?>.from(source)..remove('books');
  metadata['sha'] = expectedSha;
  Translation.fromJson(metadata);
  final bookNumbers = <int>{};
  final books = <Object?>[];
  for (final book in bible.books) {
    if (!bookNumbers.add(book.number) ||
        (book.chapters.isEmpty &&
            book.titles.isEmpty &&
            book.introduction.isEmpty)) {
      throw const FormatException(
        'The Bible contains duplicate or unreadable books.',
      );
    }
    if (book.chapters.any((chapter) => chapter.chapter < 1)) {
      throw const FormatException(
        'Published nested chapters must have positive source identities.',
      );
    }
    final record = Map<String, Object?>.from(book.toJson())..remove('chapters');
    record['direction'] ??= bible.direction;
    books.add(record);
  }
  yield {
    'documents': {
      'translation': jsonEncode(metadata),
      'books': jsonEncode(books),
    },
    'completed': 0,
    'total': bible.books.length,
  };
  int completed = 0;
  for (final book in bible.books) {
    final chapterNumbers = <int>{};
    final chapters = <Object?>[];
    final contents = <WholeTranslationChapter>[...book.chapters];
    if (book.titles.isNotEmpty || book.introduction.isNotEmpty) {
      contents.insert(
        0,
        WholeTranslationChapter(
          chapter: 0,
          name: book.name,
          verses: const [],
          titles: book.titles,
          introduction: book.introduction,
        ),
      );
    }
    for (final chapter in contents) {
      if (!chapterNumbers.add(chapter.chapter) ||
          chapter.chapter < 0 ||
          (chapter.chapter == 0 && chapter.verses.isNotEmpty) ||
          (chapter.verses.isEmpty && !chapter.isIntroduction)) {
        throw const FormatException(
          'The Bible contains duplicate or unreadable chapters.',
        );
      }
      final fullChapter = chapter.toBibleChapter(
        abbreviation: bible.abbreviation,
        bookNumber: book.number,
        bookName: book.name,
        translation: bible.translation,
        language: bible.language,
        lang: bible.lang,
        direction: optionalString(book.extra, 'direction', bible.direction),
        encoding: bible.encoding,
      );
      chapters.add(
        ChapterInfo(
          chapter: chapter.chapter,
          name: chapter.name,
          sha: '',
          isIntroduction: chapter.isIntroduction,
        ).toJson(),
      );
      yield {
        'documents': {
          'chapter/${book.number}/${chapter.chapter}': jsonEncode(
            fullChapter.toJson(),
          ),
        },
      };
      for (int start = 0; start < chapter.verses.length; start += 100) {
        yield {
          'verses': chapter.verses
              .skip(start)
              .take(100)
              .map(
                (verse) => <String, Object?>{
                  'book': book.number,
                  'chapter': chapter.chapter,
                  'verse': verse.verse,
                  'bookName': book.name,
                  'direction': fullChapter.direction,
                  'verseJson': jsonEncode(verse.toJson()),
                  'text': verse.text,
                  'normalizedText': verse.text.toLowerCase(),
                },
              )
              .toList(),
        };
      }
    }
    yield {
      'documents': {'chapters/${book.number}': jsonEncode(chapters)},
      'completed': ++completed,
      'total': bible.books.length,
    };
  }
}
