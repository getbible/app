import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { readFile, mkdir, writeFile, stat } from 'node:fs/promises';
import { resolve, sep, extname, join } from 'node:path';
import { parseArgs } from 'node:util';
import { chromium, firefox, webkit } from 'playwright';
import { measureWorker } from './worker-performance.mjs';
import { apiFixtures, firstVerse, secondVerse, noteText, restoredNoteText, unvisitedVerse } from './fixtures.mjs';
import { studyInstallationFixtures } from './study-fixtures.mjs';

const { values } = parseArgs({ options: {
  'build-dir': { type: 'string', default: 'build/web' },
  'base-path': { type: 'string', default: '/flutter/' },
  'output-dir': { type: 'string', default: 'build/browser-smoke' },
  'browser-channel': { type: 'string' },
  browsers: { type: 'string', default: 'chromium' },
} });
const selectedBrowsers = values.browsers.split(',');
const browserTypes = { chromium, firefox, webkit };
assert.ok(selectedBrowsers.length && selectedBrowsers.every((name) => Object.hasOwn(browserTypes, name)), 'Unsupported browser');
assert.equal(new Set(selectedBrowsers).size, selectedBrowsers.length, 'Duplicate browser');
assert.ok(!values['browser-channel'] || selectedBrowsers.every((name) => name === 'chromium'), 'Browser channel applies only to Chromium');
const buildDirectory = resolve(values['build-dir']);
const outputDirectory = resolve(values['output-dir']);
const basePath = values['base-path'];
assert.match(basePath, /^\/(?:[a-zA-Z0-9._~-]+\/)*$/, 'Base path must start and end in /');
assert.ok(!basePath.split('/').some((segment) => segment === '.' || segment === '..'), 'Base path cannot contain dot segments');
for (const asset of ['index.html', 'main.dart.js', 'sqlite3.wasm', 'drift_worker.dart.js', 'offline_bible_worker.dart.js', 'offline_service_worker.js', 'offline-shell-manifest.json']) {
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

/** Uses the documented SPA rewrite for HTML navigation; missing assets stay 404. */
async function serveBuild({ isolated }) {
  const server = createServer(async (request, response) => {
    try {
      const pathname = decodeURIComponent(new URL(request.url, 'http://localhost').pathname);
      const relativePath = pathname.startsWith(basePath) ? pathname.slice(basePath.length) : null;
      let filePath = relativePath === null ? '' : resolve(buildDirectory, relativePath || 'index.html');
      if (!filePath.startsWith(buildDirectory + sep)) {
        response.writeHead(404).end();
        return;
      }
      let body;
      try {
        body = await readFile(filePath);
      } catch (error) {
        if (error.code !== 'ENOENT' || extname(filePath) || !request.headers.accept?.includes('text/html') ||
            (request.headers['sec-fetch-dest'] && request.headers['sec-fetch-dest'] !== 'document')) throw error;
        filePath = join(buildDirectory, 'index.html');
        body = await readFile(filePath);
      }
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
  await page.getByRole('group', { name: `Genesis 1:2. ${secondVerse}`, exact: true }).waitFor();
}

async function runJourney(browser, { isolated, browserName }) {
  const hosting = isolated ? 'cross-origin-isolated' : 'standard-hosting';
  const mode = `${browserName}-${hosting}`;
  const { server, origin } = await serveBuild({ isolated });
  const context = await browser.newContext({ viewport: { width: 1280, height: 900 }, serviceWorkers: 'allow' });
  const errors = [];
  const requests = [];
  const missingAssets = [];
  const workers = [];
  const fixtures = new Map([...apiFixtures(), ...studyInstallationFixtures()]);
  let apiOffline = false;
  let prepareShell = false;
  let deferredShellLoads = 0;
  let page;
  await context.tracing.start({ screenshots: true, snapshots: true, sources: true });
  context.on('page', (opened) => {
    opened.on('worker', (worker) => workers.push(worker.url()));
    opened.on('pageerror', (error) => errors.push({ type: 'pageerror', message: error.stack ?? error.message }));
    opened.on('console', (message) => {
      if (message.type() !== 'error') return;
      // A deliberately disconnected API logs a network error in Chromium.
      // All uncaught exceptions and local asset errors remain failures.
      if (apiOffline && /net::ERR_INTERNET_DISCONNECTED|Failed to load resource:.*(?:network connection was lost|Internet connection appears to be offline)|NetworkError when attempting to fetch resource/.test(message.text())) return;
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
    if (url === origin + basePath + 'offline_shell.js' && !prepareShell) {
      // WebKit service-worker-controlled requests can bypass Playwright routing.
      // Keep all fixture phases uncontrolled, then load the exact production
      // shell script before the separate fully network-disconnected cold start.
      // Native registration, worker bytes, cache verification and app code are
      // untouched; only this script's initial delivery is deferred.
      deferredShellLoads++;
      return route.fulfill({ status: 200, contentType: 'text/javascript',
        body: '// Offline shell registration is deferred until fixture setup completes.\n' });
    }
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
    await page.goto(origin + basePath + 'KJV/Genesis/1?verse=2', { waitUntil: 'domcontentloaded' });
    await enableSemantics(page);
    await readerVisible(page);
    assert.ok(deferredShellLoads > 0, 'Fixture setup must defer the production shell loader');
    assert.equal(new URL(page.url()).searchParams.get('verse'), '2',
      'First browser launch must preserve the incoming verse rather than choose the daily default');
    assert.equal(await page.evaluate(() => crossOriginIsolated), isolated);
    assert.deepEqual(errors, [], 'Startup produced browser errors');
    assert.deepEqual(missingAssets, [], 'Startup missed built assets');
    console.log(`${mode}: release reader opened`);
    const workerMetrics = await measureWorker(page);
    await writeFile(join(outputDirectory, `${mode}-worker-performance.json`), JSON.stringify(workerMetrics, null, 2));
    assert.equal(workerMetrics.verses, 20000);
    assert.ok(workerMetrics.maximumVerseBatch <= 100);
    assert.ok(workerMetrics.uiHeartbeatTicks > 0, 'UI event loop must remain live while the worker parses');
    const dictionaryMetrics = await measureWorker(page, 'dictionary-index');
    await writeFile(join(outputDirectory, `${mode}-dictionary-performance.json`), JSON.stringify(dictionaryMetrics, null, 2));
    assert.equal(dictionaryMetrics.entries, 20000);
    assert.ok(dictionaryMetrics.maximumEntryBatch <= 128);
    assert.ok(dictionaryMetrics.uiHeartbeatTicks > 0, 'Dictionary index parsing must leave the UI event loop live');

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

    // Preserve coverage for readers that have cached a passage but have not
    // installed a complete Bible. Reopening must retain the note and text.
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
    assert.ok(requests.some((request) => request.apiOffline),
      'Cached chapter path must attempt current-source verification');
    apiOffline = false;
    console.log(`${mode}: cached passage and note reopened without public APIs`);

    // Download the actual private snapshot, then import an edited copy through
    // the system file picker. The preview must precede any merge confirmation.
    await page.getByRole('button', { name: /^Open Bible navigation/ }).click();
    await page.getByRole('button', { name: 'Backup and restore', exact: true }).press('Enter');
    await page.getByRole('button', { name: 'Prepare complete backup', exact: true }).click();
    const downloadEvent = page.waitForEvent('download');
    await page.getByRole('button', { name: 'Save file', exact: true }).click();
    const download = await downloadEvent;
    assert.match(download.suggestedFilename(), /^getbible-private-\d{4}-\d{2}-\d{2}\.json$/);
    const backupPath = join(outputDirectory, `${mode}-private-backup.json`);
    await download.saveAs(backupPath);
    const backup = JSON.parse(await readFile(backupPath, 'utf8'));
    assert.equal(backup.format, 'getbible-private-backup');
    const savedNote = backup.reader.notes.find((note) => note.text === noteText);
    assert.ok(savedNote, 'Downloaded backup must contain the saved private note');
    savedNote.text = restoredNoteText;
    assert.ok(Number.isSafeInteger(savedNote.updatedAt));
    savedNote.updatedAt += 1000;
    const fileChooserEvent = page.waitForEvent('filechooser');
    await page.getByRole('button', { name: 'Choose backup file', exact: true }).click();
    await (await fileChooserEvent).setFiles({
      name: 'restore.json', mimeType: 'application/json',
      buffer: Buffer.from(JSON.stringify(backup)),
    });
    await page.getByText('Complete private backup preview', { exact: true }).waitFor();
    await page.getByRole('button', { name: 'Confirm import', exact: true }).click();
    await page.locator('flt-semantics').getByText(/^Import complete:/).waitFor();
    await page.getByRole('button', { name: 'Back', exact: true }).click();
    await page.getByRole('button', { name: restoredNoteText }).waitFor();
    console.log(`${mode}: downloaded and restored private backup`);

    // Install the complete fixture Bible through the real production worker.
    // Chapter two has never been opened, so a later offline read cannot be
    // satisfied by the opportunistic chapter cache.
    assert.ok(!requests.some((request) => request.url.endsWith('/1/2.json')));
    await page.getByRole('button', { name: /^Open Bible navigation/ }).click();
    await page.getByRole('button', { name: 'Set up offline use', exact: true }).press('Enter');
    await page.getByRole('button', { name: 'Browse catalogue', exact: true }).click();
    await page.getByRole('textbox', { name: 'Find a resource', exact: true }).click();
    await page.locator('input:focus, textarea:focus').fill('King James Version');
    const resourceCard = page.getByRole('group', { name: /^King James Version \(English\)\s+Bible/ });
    await resourceCard.waitFor();
    await resourceCard.scrollIntoViewIfNeeded();
    await page.getByRole('button', { name: 'Install', exact: true }).first().click();
    await page.getByRole('alertdialog').getByRole('button', { name: 'Install', exact: true }).click();
    console.log(`${mode}: resource installation confirmed`);
    await page.getByRole('group', { name: /^King James Version \(English\)\s+Bible[\s\S]*Installed[\s\S]*Verified source revision:/ }).waitFor();
    const bibleWorkers = workers.filter((url) => url.endsWith('/offline_bible_worker.dart.js')).length;
    assert.ok(bibleWorkers > 0, 'Complete installation must execute the bundled web worker');
    assert.equal(
      await page.getByRole('textbox', { name: 'Find a resource', exact: true }).inputValue(),
      'King James Version',
      'Installing a resource must preserve the visible catalogue filter',
    );
    await page.getByRole('textbox', { name: 'Find a resource', exact: true }).click();
    await page.locator('input:focus, textarea:focus').fill('Greek lexicon');
    await page.getByRole('group', { name: /^Greek lexicon · en\s+Dictionary/ }).waitFor();
    await page.getByRole('button', { name: 'Install', exact: true }).first().click();
    await page.getByRole('alertdialog').getByRole('button', { name: 'Install', exact: true }).click();
    console.log(`${mode}: resource installation confirmed`);
    await page.getByRole('group', { name: /^Greek lexicon · en\s+Dictionary[\s\S]*Installed/ }).waitFor();
    assert.ok(workers.filter((url) => url.endsWith('/offline_bible_worker.dart.js')).length > bibleWorkers,
      'Bible and dictionary installation must both execute the production worker');
    await page.getByRole('button', { name: 'Close offline resources', exact: true }).click();
    console.log(`${mode}: complete Bible and dictionary installed by production worker`);

    // A new page discards all Dart state. It reopens the production browser
    // database, while public APIs fail and local release assets still load.
    const requestsBeforeInstalledRestart = requests.length;
    apiOffline = true;
    await page.close();
    page = await context.newPage();
    page.setDefaultTimeout(45000);
    await page.goto(origin + basePath, { waitUntil: 'domcontentloaded' });
    await enableSemantics(page);
    await readerVisible(page);
    await page.getByRole('button', { name: restoredNoteText }).waitFor();
    await page.getByRole('button', { name: 'Verified Scripture', exact: true }).click();
    await page.getByText('Scripture verified', { exact: true }).waitFor();
    await page.getByRole('button', { name: 'Close', exact: true }).click();
    await page.getByRole('button', { name: /^Open Bible navigation/ }).click();
    await page.getByRole('button', { name: 'Set up offline use', exact: true }).press('Enter');
    await page.getByRole('group', { name: /^Greek lexicon · en\s+Dictionary/ }).waitFor();
    await page.getByRole('group', { name: /^Greek lexicon · en\s+Dictionary[\s\S]*Installed/ }).waitFor();
    await page.getByRole('button', { name: 'Close offline resources', exact: true }).click();
    const requestsBeforeOfflineRead = requests.length;
    await page.getByRole('button', { name: 'Next chapter', exact: true }).first().click();
    await page.getByRole('group', { name: `Genesis 2:1. ${unvisitedVerse}`, exact: true }).waitFor();
    assert.equal(requests.length, requestsBeforeOfflineRead,
      'An installed chapter must open without public HTTP requests');
    // The compact reader exposes a dedicated search action, exercising the
    // responsive toolbar as well as the desktop installation layout.
    await page.setViewportSize({ width: 700, height: 900 });
    await page.getByRole('button', { name: 'Search this translation', exact: true }).click();
    await page.getByRole('button', { name: /^Search source\s+Online search/ }).click();
    await page.getByRole('menuitem', { name: 'Installed Bible (offline)', exact: true }).click();
    await page.getByRole('textbox', { name: /Search KJV/ }).click();
    await page.getByPlaceholder('Words, a phrase or a Scripture reference', { exact: true }).fill('finished');
    const requestsBeforeOfflineSearch = requests.length;
    await page.getByRole('button', { name: 'Search', exact: true }).click();
    await page.getByRole('button', { name: 'Open Genesis 2:1', exact: true }).waitFor();
    assert.equal(requests.length, requestsBeforeOfflineSearch,
      'Installed search must not request an online search or query service');
    await page.screenshot({ path: join(outputDirectory, `${mode}-offline.png`) });
    assert.deepEqual(requests.slice(requestsBeforeInstalledRestart), [],
      'Installed restart, reading and search must stay within the local database');
    // The generated application shell must cache its own exact release assets.
    // A fresh page with all networking disabled demonstrates a real cold start,
    // in addition to the earlier independent public-API offline checks.
    prepareShell = true;
    await page.addScriptTag({ url: origin + basePath + 'offline_shell.js' });
    // Activation never claims an existing page: a deploy must not switch the
    // asset generation underneath an open note editor. The next navigation is
    // controlled after the complete worker has activated.
    await page.waitForFunction(async () => {
      const registration = await navigator.serviceWorker.getRegistration();
      return registration?.active?.state === 'activated';
    }, undefined, { timeout: 90000 });
    console.log(`${mode}: production application shell installed`);
    await context.setOffline(true);
    await page.close();
    page = await context.newPage();
    page.setDefaultTimeout(45000);
    // The inbound route differs from the saved Genesis 2 position, proving
    // actual browser deep-link delivery wins over last-reading restoration.
    await page.goto(origin + basePath + 'KJV/Genesis/1?verse=1', { waitUntil: 'domcontentloaded' });
    assert.equal(await page.evaluate(() => navigator.serviceWorker.controller !== null), true,
      'A new offline navigation must use the activated application shell');
    await enableSemantics(page);
    await readerVisible(page);
    await page.getByRole('button', { name: restoredNoteText }).waitFor();
    await page.getByRole('button', { name: 'Next chapter', exact: true }).first().click();
    await page.getByRole('group', { name: `Genesis 2:1. ${unvisitedVerse}`, exact: true }).waitFor();
    await page.screenshot({ path: join(outputDirectory, `${mode}-application-offline.png`) });
    assert.deepEqual(requests.slice(requestsBeforeInstalledRestart), [],
      'Network-disconnected application startup must not fetch public services');
    assert.deepEqual(errors, [], 'Release UI produced browser errors');
    assert.deepEqual(missingAssets, [], 'Release UI requested missing assets');
    return { mode, status: 'passed', checks: ['reader startup', 'SQLite write', 'API-offline cached reader', 'private backup download and file restore', 'production worker Bible and dictionary installation', 'resource filter survives activation', 'new-page persistence', 'unvisited installed chapter without HTTP', 'installed search without HTTP', 'deep-linked application shell and chapter navigation with all networking disabled', '20,000-verse worker liveness', 'no browser errors'] };
  } catch (error) {
    if (page && !page.isClosed()) {
      await page.screenshot({ path: join(outputDirectory, `${mode}-failure.png`) }).catch(() => {});
      await writeFile(join(outputDirectory, `${mode}-failure.html`), await page.content()).catch(() => {});
    }
    throw error;
  } finally {
    await writeFile(join(outputDirectory, `${mode}-browser.json`), JSON.stringify({ errors, missingAssets, requests, workers, deferredShellLoads }, null, 2));
    await context.tracing.stop({ path: join(outputDirectory, `${mode}-trace.zip`) });
    await context.close();
    await new Promise((resolveClose) => server.close(resolveClose));
  }
}

const results = [];
let failed = false;
for (const browserName of selectedBrowsers) {
  let browser;
  try {
    browser = await browserTypes[browserName].launch(
      browserName === 'chromium' ? { channel: values['browser-channel'] } : {},
    );
    for (const isolated of [false, true]) {
      try {
        results.push(await runJourney(browser, { isolated, browserName }));
        console.log(`PASS ${results.at(-1).mode}`);
      } catch (error) {
        failed = true;
        results.push({ browser: browserName, mode: isolated ? 'cross-origin-isolated' : 'standard-hosting', status: 'failed', error: error.stack ?? error.message });
        console.error(error);
      }
    }
  } catch (error) {
    failed = true;
    results.push({ browser: browserName, status: 'failed', error: error.stack ?? error.message });
    console.error(error);
  } finally {
    await writeFile(join(outputDirectory, 'results.json'), JSON.stringify(results, null, 2));
    await browser?.close();
  }
}
if (failed) process.exitCode = 1;
