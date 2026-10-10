import 'package:flutter_test/flutter_test.dart';
import 'package:getbible/domain/models/bible.dart';
import 'package:getbible/services/markdown_service.dart';

void main() {
  const BibleChapter chapter = BibleChapter(
    translation: 'KJV',
    abbreviation: 'kjv',
    language: 'English',
    direction: 'LTR',
    bookNumber: 49,
    bookName: 'Ephesians',
    chapter: 5,
    name: 'Ephesians 5',
    verses: <Verse>[
      Verse(
        chapter: 5,
        verse: 1,
        name: 'Ephesians 5:1',
        text: ' Be ye therefore followers of God ',
      ),
      Verse(
        chapter: 5,
        verse: 2,
        name: 'Ephesians 5:2',
        text: 'And walk in love',
      ),
    ],
  );
  const Translation translation = Translation(
    translation: 'King James Version',
    abbreviation: 'kjv',
    lang: 'en',
    language: 'English',
    direction: 'LTR',
    sha: 'sha',
    distributionLicense: 'Public domain\nSecond line',
  );

  test('chapter Markdown matches the web contract', () {
    expect(
      chapterMarkdown(chapter, translation),
      '# Ephesians 5\n\n'
      '1. Be ye therefore followers of God\n'
      '2. And walk in love\n\n'
      '---\n'
      '**King James Version**\n\n'
      '> Public domain\n'
      '> Second line',
    );
  });

  test('range Markdown has an inclusive range heading', () {
    expect(
      scriptureMarkdown(chapter, translation, 1, 1),
      startsWith('# Ephesians 5:2\n\n2. And walk in love'),
    );
  });

  test('Markdown filename is stable', () {
    expect(chapterMarkdownFilename(chapter), 'Ephesians-5.md');
  });
}
