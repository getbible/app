import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { readFile, mkdir, writeFile, stat } from 'node:fs/promises';
import { resolve, sep, extname, join } from 'node:path';
import { parseArgs } from 'node:util';
import { chromium } from 'playwright';
import { apiFixtures, firstVerse, noteText } from './fixtures.mjs';

const { values } = parseArgs({ options: {
  'build-dir': { type: 'string', default: 'build/web' },
  'base-path': { type: 'string', default: '/flutter/' },
  'output-dir': { type: 'string', default: 'build/browser-smoke' },
  'browser-channel': { type: 'string' },
} });
const buildDirectory = resolve(values['build-dir']);
const outputDirectory = resolve(values['output-dir']);
const basePath = values['base-path'];
assert.match(basePath, /^\/(?:[a-zA-Z0-9._~-]+\/)*$/, 'Base path must start and end in /');
assert.ok(!basePath.split('/').some((segment) => segment === '.' || segment === '..'), 'Base path cannot contain dot segments');
for (const asset of ['index.html', 'main.dart.js', 'sqlite3.wasm', 'drift_worker.dart.js']) {
  assert.ok((await stat(join(buildDirectory, asset))).isFile(), `Missing built asset: ${asset}`);
}
const index = await readFile(join(buildDirectory, 'index.html'), 'utf8');
assert.ok(index.includes(`<base href="${basePath}">`), 'Smoke URL must match the compiled base href');
await mkdir(outputDirectory, { recursive: true });

const contentTypes = new Map([
  ['.html', 'text/html; charset=utf-8'], ['.js', 'text/javascript'],
  ['.json', 'application/json'], ['.wasm', 'application/wasm'],
  ['.css', 'text/css'], ['.png', 'image/png'], ['.ttf', 'font/ttf'],
  ['.otf', 'font/otf'], ['.woff2', 'font/woff2'],
]);

/** Serves only the built directory; unknown paths are 404, never HTML fallbacks. */
async function serveBuild({ isolated }) {
  const server = createServer(async (request, response) => {
    try {
      const pathname = decodeURIComponent(new URL(request.url, 'http://localhost').pathname);
      const relativePath = pathname.startsWith(basePath) ? pathname.slice(basePath.length) : null;
      const filePath = relativePath === null ? '' : resolve(buildDirectory, relativePath || 'index.html');
      if (!filePath.startsWith(buildDirectory + sep)) {
        response.writeHead(404).end();
        return;
      }
      const body = await readFile(filePath);
      const headers = { 'content-type': contentTypes.get(extname(filePath)) ?? 'application/octet-stream' };
      if (isolated) {
        headers['cross-origin-opener-policy'] = 'same-origin';
        headers['cross-origin-embedder-policy'] = 'require-corp';
      }
      response.writeHead(200, headers).end(body);
    } catch (error) {
      response.writeHead(error.code === 'ENOENT' || error.code === 'EISDIR' ? 404 : 500).end();
    }
  });
  await new Promise((resolveListen, reject) => {
    server.once('error', reject);
    server.listen(0, '127.0.0.1', resolveListen);
  });
  return { server, origin: `http://127.0.0.1:${server.address().port}` };
}

async function enableSemantics(page) {
  // Flutter creates this standard opt-in control for browser accessibility.
  // Activate it exactly as an assistive browser does; the app is unmodified.
  await page.locator('flt-semantics-placeholder').waitFor({ state: 'attached' });
  await page.locator('flt-semantics-placeholder').evaluate((element) => element.click());
}

async function readerVisible(page) {
  await page.getByRole('button', { name: 'Genesis 1', exact: true }).waitFor();
  await page.getByRole('group', { name: `Genesis 1:1. ${firstVerse}`, exact: true }).waitFor();
}

async function runJourney(browser, { isolated }) {
  const mode = isolated ? 'cross-origin-isolated' : 'standard-hosting';
  const { server, origin } = await serveBuild({ isolated });
  const context = await browser.newContext({ viewport: { width: 1280, height: 900 }, serviceWorkers: 'block' });
  const errors = [];
  const requests = [];
  const missingAssets = [];
  const fixtures = apiFixtures();
  let apiOffline = false;
  let page;
  await context.tracing.start({ screenshots: true, snapshots: true, sources: true });
  context.on('page', (opened) => {
    opened.on('pageerror', (error) => errors.push({ type: 'pageerror', message: error.stack ?? error.message }));
    opened.on('console', (message) => {
      if (message.type() !== 'error') return;
      // A deliberately disconnected API logs a network error in Chromium.
      // All uncaught exceptions and local asset errors remain failures.
      if (apiOffline && message.text().includes('net::ERR_INTERNET_DISCONNECTED')) return;
      errors.push({ type: 'console', message: message.text() });
    });
    opened.on('response', (response) => {
      if (response.url().startsWith(origin) && response.status() >= 400) {
        missingAssets.push(`${response.status()} ${response.url()}`);
      }
    });
  });
  await context.route('**/*', async (route) => {
    const request = route.request();
    const url = request.url();
    if (url.startsWith(origin + '/')) return route.continue();
    if (!/^https?:/.test(url)) return route.continue();
    requests.push({ method: request.method(), url, apiOffline });
    const fixture = fixtures.get(url);
    if (!fixture) {
      errors.push({ type: 'unexpected-network-request', message: `${request.method()} ${url}` });
      return route.abort('blockedbyclient');
    }
    if (request.method() !== 'GET') {
      errors.push({ type: 'unexpected-method', message: `${request.method()} ${url}` });
      return route.abort('blockedbyclient');
    }
    if (apiOffline) return route.abort('internetdisconnected');
    return route.fulfill({
      status: 200,
      contentType: fixture.contentType,
      body: fixture.body,
      headers: { 'access-control-allow-origin': '*', 'cache-control': 'max-age=600', 'cross-origin-resource-policy': 'cross-origin' },
    });
  });
  try {
    page = await context.newPage();
    page.setDefaultTimeout(45000);
    await page.goto(origin + basePath, { waitUntil: 'domcontentloaded' });
    await enableSemantics(page);
    await readerVisible(page);
    assert.equal(await page.evaluate(() => crossOriginIsolated), isolated);
    assert.deepEqual(errors, [], 'Startup produced browser errors');
    assert.deepEqual(missingAssets, [], 'Startup missed built assets');
    console.log(`${mode}: release reader opened`);

    // Verse-number context actions exercise the actual rendered release UI.
    await page.getByText('1', { exact: true }).click();
    await page.getByRole('menuitem', { name: 'Add note', exact: true }).click();
    await page.getByRole('textbox', { name: 'Write your note…' }).click();
    // Flutter replaces its semantics mirror with the platform editing element
    // on focus. Fill that connected editor, rather than racing its activation.
    await page.getByPlaceholder('Write your note…', { exact: true }).fill(noteText);
    await page.getByRole('button', { name: 'Save note', exact: true }).click();
    await page.getByRole('button', { name: noteText }).waitFor();
    await page.screenshot({ path: join(outputDirectory, `${mode}-saved.png`) });
    console.log(`${mode}: private note saved`);

    // A new page discards all Dart state. It reopens the production browser
    // database, while public APIs fail and local release assets still load.
    apiOffline = true;
    await page.close();
    page = await context.newPage();
    page.setDefaultTimeout(45000);
    await page.goto(origin + basePath, { waitUntil: 'domcontentloaded' });
    await enableSemantics(page);
    await readerVisible(page);
    await page.getByRole('button', { name: noteText }).waitFor();
    await page.getByRole('button', { name: 'Saved Scripture', exact: true }).click();
    await page.getByText('Saved for offline reading', { exact: true }).waitFor();
    await page.getByRole('button', { name: 'Close', exact: true }).click();
    await page.screenshot({ path: join(outputDirectory, `${mode}-offline.png`) });
    assert.ok(requests.some((request) => request.apiOffline), 'Offline cache path must attempt verification');
    assert.deepEqual(errors, [], 'Release UI produced browser errors');
    assert.deepEqual(missingAssets, [], 'Release UI requested missing assets');
    return { mode, status: 'passed', checks: ['reader startup', 'SQLite write', 'new-page persistence', 'API-offline cached reader', 'no browser errors'] };
  } catch (error) {
    if (page && !page.isClosed()) {
      await page.screenshot({ path: join(outputDirectory, `${mode}-failure.png`) }).catch(() => {});
      await writeFile(join(outputDirectory, `${mode}-failure.html`), await page.content()).catch(() => {});
    }
    throw error;
  } finally {
    await writeFile(join(outputDirectory, `${mode}-browser.json`), JSON.stringify({ errors, missingAssets, requests }, null, 2));
    await context.tracing.stop({ path: join(outputDirectory, `${mode}-trace.zip`) });
    await context.close();
    await new Promise((resolveClose) => server.close(resolveClose));
  }
}

const browser = await chromium.launch({ channel: values['browser-channel'] });
const results = [];
try {
  for (const isolated of [false, true]) {
    try {
      results.push(await runJourney(browser, { isolated }));
      console.log(`PASS ${results.at(-1).mode}`);
    } catch (error) {
      results.push({ mode: isolated ? 'cross-origin-isolated' : 'standard-hosting', status: 'failed', error: error.message });
      throw error;
    }
  }
} finally {
  await writeFile(join(outputDirectory, 'results.json'), JSON.stringify(results, null, 2));
  await browser.close();
}
