import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';

const fixtureBytes = (path) => readFileSync(new URL(`../../test/fixtures/${path}`, import.meta.url));
const fixture = (path) => JSON.parse(fixtureBytes(path).toString('utf8'));

/**
 * A complete small dictionary installation, sharing the native test corpus.
 * Metadata sizes and SHA256 hashes describe the exact UTF-8 response bodies,
 * including the complete module's original whitespace. Merge these records
 * after apiFixtures() so its discovery-only dictionary catalogue is replaced.
 */
export function studyInstallationFixtures() {
  const module = 'strongsgreek';
  const base = 'https://dictionaries.getbible.net/v1/';
  const bulk = fixtureBytes('offline_study_v1/dictionary.json');
  const catalogue = fixture('dictionaries_v1/dictionaries.json');
  const metadata = fixture(`dictionaries_v1/${module}/metadata.json`);
  metadata.bytes = bulk.length;
  const descriptor = catalogue.dictionaries.find((item) => item.id === module);
  if (!descriptor) throw new Error(`Dictionary fixture catalogue lacks ${module}`);
  descriptor.bytes = bulk.length;
  const documents = new Map([
    ['dictionaries.json', JSON.stringify(catalogue)],
    [`${module}/metadata.json`, JSON.stringify(metadata)],
    [`${module}/index.json`, JSON.stringify(fixture(`dictionaries_v1/${module}/index.json`))],
    [`${module}.json`, bulk.toString('utf8')],
  ]);
  documents.set('hashes.json', JSON.stringify({
    schema: 'getbible-hashes-v1',
    algorithm: 'sha256',
    files: Object.fromEntries([...documents].map(([path, body]) => [
      path, createHash('sha256').update(body, 'utf8').digest('hex'),
    ])),
  }));
  return new Map([...documents].map(([path, body]) => [
    base + path, { body, contentType: 'application/json' },
  ]));
}
