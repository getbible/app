import { createHash } from 'node:crypto';

/** Small original-text fixtures: no downloaded Bible corpus or live API needed. */
export const firstVerse = 'In the beginning God created the heaven and the earth.';
export const noteText = 'Browser smoke: this private note survives a new page.';

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
    { chapter: 1, verse: 2, name: 'Genesis 1:2', text: 'And the earth was without form, and void.' },
    { chapter: 1, verse: 3, name: 'Genesis 1:3', text: 'And God said, Let there be light: and there was light.' },
  ],
};
const book = {
  nr: 1,
  name: 'Genesis',
  translation: chapter.translation,
  abbreviation: 'kjv',
  language: 'English',
  direction: 'LTR',
  chapters: [chapter],
};
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
        sha: digest(book),
      },
    }],
    ['kjv/books.json', { 1: { nr: 1, name: 'Genesis', sha: digest(book) } }],
    ['kjv/1/chapters.json', { 1: { chapter: 1, name: 'Genesis 1', sha: digest(chapter) } }],
    ['kjv/1.json', book],
    ['kjv/1/1.json', chapter],
  ].map(([path, value]) => [bible + path, { body: json(value), contentType: 'application/json' }]));
  records.set(bible + 'kjv/1.sha', { body: digest(book), contentType: 'text/plain' });
  records.set(bible + 'kjv/1/1.sha', { body: digest(chapter), contentType: 'text/plain' });
  records.set('https://raw.githubusercontent.com/trueChristian/daily-scripture/refs/heads/master/README.json', {
    contentType: 'application/json',
    body: json({ date: new Date().toISOString().slice(0, 10), name: 'Genesis 1:1', book: 'Genesis', chapter: 1, verse: 1 }),
  });
  return records;
}
