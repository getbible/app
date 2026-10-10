import { createServer } from 'node:http';
import { mkdir, writeFile } from 'node:fs/promises';
import { resolve } from 'node:path';
import { chromium } from 'playwright';

// Bounded, anonymous read-only probes from an actual browser origin. A remote
// outage/CORS failure is separately reported: deterministic fixture journeys are
// the code gate, while this report is evidence of current deployed availability.
const urls = [
  'https://api.getbible.net/v3/kjv/1/1.json',
  'https://query.getbible.net/v3/kjv/John%203%3A16',
  'https://search.getbible.net/v3/kjv?q=grace&limit=1',
  'https://dictionaries.getbible.net/v1/dictionaries.json',
  'https://commentaries.getbible.net/v1/commentaries.json',
  'https://bookmarks.getbible.net/v1/index.json',
];
const output = resolve('build/browser-smoke/live-services.json');
const server = createServer((_, response) => response.writeHead(200, { 'content-type': 'text/html' }).end('<!doctype html><title>Public API CORS probe</title>'));
await new Promise((done) => server.listen(0, '127.0.0.1', done));
let browser;
try {
  browser = await chromium.launch();
  const page = await browser.newPage();
  const browserErrors = [];
  page.on('console', (message) => { if (message.type() === 'error') browserErrors.push(message.text()); });
  const origin = `http://127.0.0.1:${server.address().port}`;
  await page.goto(origin);
  const results = await page.evaluate(async (services) => Promise.all(services.map(async (url) => {
    const started = performance.now();
    try {
      const response = await fetch(url, { mode: 'cors', credentials: 'omit', cache: 'no-store', signal: AbortSignal.timeout(20000) });
      await response.body?.cancel();
      return { url, outcome: response.ok ? 'available-with-browser-cors' : 'upstream-http-error', status: response.status,
        elapsedMilliseconds: performance.now() - started,
        exposedHeaders: Object.fromEntries(['cache-control', 'etag', 'last-modified', 'retry-after'].map((name) => [name, response.headers.get(name)])) };
    } catch (error) {
      return { url, outcome: 'network-or-cors-unavailable', error: error.message, elapsedMilliseconds: performance.now() - started };
    }
  })), urls);
  await mkdir(resolve('build/browser-smoke'), { recursive: true });
  await writeFile(output, JSON.stringify({ measuredAt: new Date().toISOString(), origin, results, browserErrors,
    interpretation: 'Anonymous synthetic requests only. Remote availability is separate from deterministic application correctness; CORS/network failures require deployment investigation.' }, null, 2));
  for (const result of results) console.log(`${result.outcome}: ${result.url}`);
} finally {
  await browser?.close();
  await new Promise((done) => server.close(done));
}
