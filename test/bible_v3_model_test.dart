import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:getbible_live/domain/models/bible.dart';

Object? fixture(String name) =>
    jsonDecode(File('test/fixtures/bible_v3/$name').readAsStringSync());

void main() {
  for (final name in <String>['plain_chapter.json', 'rich_chapter.json']) {
    test('$name round trips every source field without rewriting text', () {
      final source = fixture(name);
      final chapter = BibleChapter.fromJson(source);
      expect(chapter.toJson(), equals(source));
      expect(BibleChapter.fromJson(chapter.toJson()).toJson(), equals(source));
    });
  }
  test(
    'whole translation retains nested titles, introductions and unknowns',
    () {
      final source = fixture('rich_translation.json');
      final translation = WholeTranslation.fromJson(source);
      expect(translation.toJson(), equals(source));
      expect(translation.books.single.number, 900000123);
      expect(translation.introduction.single.text, 'Translation introduction.');
      expect(translation.books.single.chapters.first.isIntroduction, isTrue);
      expect(translation.books.single.chapters.first.verses, isEmpty);
    },
  );
  test('nested and standalone chapters expose identical source enrichment', () {
    final standalone = BibleChapter.fromJson(fixture('rich_chapter.json'));
    final translation = WholeTranslation.fromJson(
      fixture('rich_translation.json'),
    );
    final book = translation.books.single;
    final nested = book.chapters.last.toBibleChapter(
      abbreviation: translation.abbreviation,
      bookNumber: book.number,
      bookName: book.name,
      translation: translation.translation,
      language: translation.language,
      direction: translation.direction,
    );
    expect(
      nested.verses.map((verse) => verse.toJson()),
      standalone.verses.map((verse) => verse.toJson()),
    );
    expect(nested.editorial!.toJson(), standalone.editorial!.toJson());
    expect(nested.verses.first.text, '  A😀  supplied\tname\nremains.  ');
    final token = nested.verses.first.tokens.first;
    expect(token.lemma, {
      'strong': ['G1', 'G2'],
      'other': ['lex:one'],
    });
    expect(token.src, [1, '2,3']);
    expect(nested.verses.first.tokens[1].wordEnd, 3);
    expect(nested.verses.first.tokens.last.wordStart, 0);
    expect(nested.editorial!.headings.single.canonical, isFalse);
  });
  test(
    'compact query verse inherits chapter without fabricating source JSON',
    () {
      final Map<String, Object?> source = {
        'verse': 1,
        'text': ' Original text ',
        'future': false,
      };
      final verse = Verse.fromJson(source, fallbackChapter: 4);
      expect(verse.chapter, 4);
      expect(verse.toJson(), source);
    },
  );
  test('intro-only books round trip without inventing chapters or verses', () {
    final source = fixture('intro_only_book.json');
    final book = WholeTranslationBook.fromJson(source);
    expect(book.toJson(), source);
    expect(book.chapters, isEmpty);
    expect(book.titles.single.canonical, isFalse);
  });
  test(
    'parsed source metadata cannot be mutated into different saved coordinates',
    () {
      final Map<String, Object?> original = {
        'chapter': 1,
        'verse': 1,
        'text': 'Original',
        'future': {'value': 'original'},
      };
      final verse = Verse.fromJson(original);
      original['text'] = 'Changed outside the model';
      (original['future'] as Map<String, Object?>)['value'] = 'changed';
      expect(verse.text, 'Original');
      expect((verse.toJson()['future'] as Map)['value'], 'original');
      expect(() => verse.source!['text'] = 'changed', throwsUnsupportedError);
    },
  );
  test(
    'known enrichment with invalid field types is rejected before activation',
    () {
      for (final wrong in [null, 1, 'true']) {
        expect(
          () => Verse.fromJson({
            'chapter': 1,
            'verse': 1,
            'text': 'Text',
            'paragraph': wrong,
          }),
          throwsFormatException,
        );
        expect(
          () => Verse.fromJson({
            'chapter': 1,
            'verse': 1,
            'text': 'Text',
            'tokens': wrong,
          }),
          throwsFormatException,
        );
      }
    },
  );
  test('malformed editorial and empty Scripture cannot replace valid text', () {
    expect(
      () => Verse.fromJson({'chapter': 1, 'verse': 1, 'text': ''}),
      throwsFormatException,
    );
    expect(
      () => ChapterEditorial.fromJson([
        {
          'type': 'heading',
          'text': 'Header',
          'anchor': {'verse': 1, 'edge': 'after'},
        },
      ]),
      throwsFormatException,
    );
  });
}
