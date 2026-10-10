import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';

/** Small original-text fixtures: no downloaded Bible corpus or live API needed. */
export const firstVerse = 'In the beginning God created the heaven and the earth.';
export const secondVerse = 'And the earth was without form, and void.';
export const noteText = 'Browser smoke: this private note survives a new page.';
export const restoredNoteText = 'Browser smoke: this private note was restored from a file.';
export const unvisitedVerse = 'Thus the heavens and the earth were finished, and all the host of them.';

const chapter = {
  translation: 'King James Version',
  abbreviation: 'kjv',
  language: 'English',
  direction: 'LTR',
  book_nr: 1,
  book_name: 'Genesis',
  chapter: 1,
  name: 'Genesis 1',
  verses: [
    { chapter: 1, verse: 1, name: 'Genesis 1:1', text: firstVerse },
    { chapter: 1, verse: 2, name: 'Genesis 1:2', text: secondVerse },
    { chapter: 1, verse: 3, name: 'Genesis 1:3', text: 'And God said, Let there be light: and there was light.' },
  ],
};
const secondChapter = {
  ...chapter, chapter: 2, name: 'Genesis 2',
  verses: [{ chapter: 2, verse: 1, name: 'Genesis 2:1', text: unvisitedVerse }],
};
const book = {
  nr: 1,
  name: 'Genesis',
  translation: chapter.translation,
  abbreviation: 'kjv',
  language: 'English',
  direction: 'LTR',
  chapters: [chapter, secondChapter],
};
const wholeTranslation = {
  translation: chapter.translation, abbreviation: 'kjv', language: 'English',
  lang: 'en', direction: 'LTR', books: [book],
};
const fixture = (path) => JSON.parse(readFileSync(new URL(`../../test/fixtures/${path}`, import.meta.url), 'utf8'));
const json = (value) => JSON.stringify(value);
const digest = (value) => createHash('sha1').update(json(value)).digest('hex');

/** Hash responses match the precise bytes served, exercising production checks. */
export function apiFixtures() {
  const bible = 'https://api.getbible.net/v3/';
  const records = new Map([
    ['translations.json', {
      kjv: {
        translation: chapter.translation,
        abbreviation: 'kjv', lang: 'en', language: 'English', direction: 'LTR',
        sha: digest(wholeTranslation),
      },
    }],
    ['kjv/books.json', { 1: { nr: 1, name: 'Genesis', sha: digest(book) } }],
    ['kjv/1/chapters.json', {
      1: { chapter: 1, name: 'Genesis 1', sha: digest(chapter) },
      2: { chapter: 2, name: 'Genesis 2', sha: digest(secondChapter) },
    }],
    ['kjv.json', wholeTranslation],
    ['kjv/1.json', book],
    ['kjv/1/1.json', chapter],
    ['kjv/1/2.json', secondChapter],
  ].map(([path, value]) => [bible + path, { body: json(value), contentType: 'application/json' }]));
  records.set(bible + 'kjv.sha', { body: digest(wholeTranslation), contentType: 'text/plain' });
  records.set(bible + 'kjv/1/2.sha', { body: digest(secondChapter), contentType: 'text/plain' });
  records.set('https://dictionaries.getbible.net/v1/dictionaries.json', {
    body: json(fixture('dictionaries_v1/dictionaries.json')), contentType: 'application/json',
  });
  records.set('https://commentaries.getbible.net/v1/commentaries.json', {
    body: json(fixture('commentary_v1.json').catalogue), contentType: 'application/json',
  });
  records.set('https://bookmarks.getbible.net/v1/index.json', {
    body: json(fixture('public_topic_index.json')), contentType: 'application/json',
  });
  records.set(bible + 'kjv/1.sha', { body: digest(book), contentType: 'text/plain' });
  records.set(bible + 'kjv/1/1.sha', { body: digest(chapter), contentType: 'text/plain' });
  records.set('https://raw.githubusercontent.com/trueChristian/daily-scripture/refs/heads/master/README.json', {
    contentType: 'application/json',
    body: json({ date: new Date().toISOString().slice(0, 10), name: 'Genesis 1:1', book: 'Genesis', chapter: 1, verse: 1 }),
  });
  return records;
}
