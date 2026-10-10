import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { readFile, mkdir, writeFile, stat } from 'node:fs/promises';
import { resolve, sep, extname, join } from 'node:path';
import { parseArgs } from 'node:util';
import { chromium, firefox, webkit } from 'playwright';
import { measureWorker } from './worker-performance.mjs';
import { classifyNetworkDiagnostics } from './network-diagnostics.mjs';
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

async function openDownloads(page) {
  await page.getByRole('button', { name: /^Open Bible navigation/ }).click();
  await page.getByRole('button', { name: 'Downloads & storage', exact: true }).press('Enter');
}

async function clearDownloads(page) {
  await page.getByRole('button', { name: 'Clear downloads', exact: true }).click();
  await page.getByRole('alertdialog').getByRole('button', { name: 'Clear downloads', exact: true }).click();
  await page.getByText('No complete resources saved yet. Automatic downloads will continue when a connection is available.', { exact: true }).waitFor();
}

const bibleBulkUrl = 'https://api.getbible.net/v3/kjv.json';
const dictionaryBulkUrl = 'https://dictionaries.getbible.net/v1/strongsgreek.json';
const commentaryBulkUrl = 'https://commentaries.getbible.net/v1/fixture.json';
const automaticBulkUrls = new Set([bibleBulkUrl, dictionaryBulkUrl, commentaryBulkUrl]);
const initialAutomaticChecks = new Set([
  'https://api.getbible.net/v3/kjv.sha',
  'https://dictionaries.getbible.net/v1/hashes.json',
  'https://commentaries.getbible.net/v1/hashes.json',
]);

function installedBible(page) {
  return page.getByRole('group', { name: /^King James Version \(English\)\s+Bible[\s\S]*Available offline[\s\S]*Verified source revision:/ });
}

function installedDictionary(page) {
  return page.getByRole('group', { name: /^Greek lexicon · en\s+Dictionary[\s\S]*Available offline/ });
}

function installedCommentary(page) {
  return page.getByRole('group', { name: /^Fixture Commentary · en\s+Commentary[\s\S]*Available offline/ });
}

/** Cache verification belongs below the chapter heading, outside a dialog. */
async function inspectVerification(page, { verified }) {
  const badgeName = verified ? 'Verified Scripture' : 'Saved Scripture';
  const badge = page.getByRole('button', { name: badgeName, exact: true });
  // Flutter may expose paragraph text exclusively through its accessible name.
  // Observe that semantics node, including when there is no DOM text child.
  const explanation = page.getByRole('group', { name: verified
    ? 'This chapter was checked against the hash published by getBible and matches the current source.'
    : 'This is the last known good copy saved on this device. It remains readable offline, but the current source hash could not be checked.',
  exact: true });
  const collapsedBadge = page.getByRole('button', { name: badgeName, exact: true, expanded: false });
  const expandedBadge = page.getByRole('button', { name: badgeName, exact: true, expanded: true });
  await badge.waitFor();
  assert.equal(await badge.count(), 1, 'Verification exposes one accessible button');
  await collapsedBadge.waitFor();
  assert.equal(await badge.getAttribute('aria-expanded'), 'false');
  await badge.click();
  await explanation.waitFor();
  await expandedBadge.waitFor();
  assert.equal(await badge.getAttribute('aria-expanded'), 'true');
  await page.getByRole('button', { name: 'getBible API', exact: true }).waitFor();
  assert.equal(await page.getByRole('dialog').count(), 0,
    'Verification must not cover Scripture with a modal dialog');
  assert.equal(await page.getByRole('alertdialog').count(), 0,
    'Verification must not open the former alert dialog');
  await readerVisible(page);
  await page.getByRole('button', { name: 'Close verification explanation', exact: true }).click();
  await explanation.waitFor({ state: 'hidden' });
  // The text node and button state can land in separate semantics updates.
  // Wait for the actual collapsed state rather than the preceding DOM frame.
  await collapsedBadge.waitFor();
  assert.equal(await badge.getAttribute('aria-expanded'), 'false');
}

async function runJourney(browser, { isolated, browserName }) {
  const hosting = isolated ? 'cross-origin-isolated' : 'standard-hosting';
  const mode = `${browserName}-${hosting}`;
  const { server, origin } = await serveBuild({ isolated });
  const context = await browser.newContext({ viewport: { width: 1280, height: 900 }, serviceWorkers: 'allow' });
  const errors = [];
  const consoleErrors = [];
  const injectedDisconnects = [];
  const pageIds = new WeakMap();
  let nextPageId = 0;
  const requests = [];
  const missingAssets = [];
  const workers = [];
  const fixtures = new Map([...apiFixtures(), ...studyInstallationFixtures()]);
  let apiOffline = false;
  let deferAutomaticChecks = true;
  let releaseAutomaticChecks;
  const automaticChecksReady = new Promise((resolveChecks) => { releaseAutomaticChecks = resolveChecks; });
  const pendingFixtureResponses = new Set();
  let networkPhase = 0;
  const setApiOffline = (offline) => { apiOffline = offline; networkPhase++; };
  const consoleDiagnostics = () => classifyNetworkDiagnostics(consoleErrors, injectedDisconnects);
  let prepareShell = false;
  let deferredShellLoads = 0;
  let page;
  await context.tracing.start({ screenshots: true, snapshots: true, sources: true });
  // Observe independently of fixture interception, including the final phase
  // where the native service worker owns delivery and all routing is removed.
  context.on('request', (request) => {
    const url = request.url();
    if (/^https?:/.test(url) && !url.startsWith(origin + '/')) {
      requests.push({ method: request.method(), url, apiOffline });
    }
  });
  context.on('page', (opened) => {
    pageIds.set(opened, ++nextPageId);
    opened.on('worker', (worker) => workers.push(worker.url()));
    opened.on('pageerror', (error) => errors.push({ type: 'pageerror', message: error.stack ?? error.message }));
    opened.on('console', (message) => {
      if (message.type() !== 'error') return;
      consoleErrors.push({ type: 'console', message: message.text(),
        locationUrl: message.location().url, pageId: pageIds.get(opened),
        phase: networkPhase, apiOffline });
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
    const fixture = fixtures.get(url);
    if (!fixture) {
      errors.push({ type: 'unexpected-network-request', message: `${request.method()} ${url}` });
      return route.abort('blockedbyclient');
    }
    if (request.method() !== 'GET') {
      errors.push({ type: 'unexpected-method', message: `${request.method()} ${url}` });
      return route.abort('blockedbyclient');
    }
    const respond = (async () => {
      // Keep the first launch cache-only until the explicit offline phase. Hold
      // manifest checks before staging begins, so closing the page cannot leave
      // an abandoned installation lease or a partially activated generation.
      if (deferAutomaticChecks && initialAutomaticChecks.has(url)) await automaticChecksReady;
      if (apiOffline) {
        const phase = networkPhase;
        let pageId;
        try { pageId = pageIds.get(request.frame().page()); } catch { /* No page provenance: fail closed. */ }
        await route.abort('internetdisconnected');
        injectedDisconnects.push({ url, method: request.method(), knownFixture: true,
          code: 'internetdisconnected', pageId, phase, apiOffline: true });
        return;
      }
      return route.fulfill({
        status: 200,
        contentType: fixture.contentType,
        body: fixture.body,
        headers: { 'access-control-allow-origin': '*', 'cache-control': 'max-age=600', 'cross-origin-resource-policy': 'cross-origin' },
      });
    })();
    pendingFixtureResponses.add(respond);
    try { await respond; } finally { pendingFixtureResponses.delete(respond); }
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
    assert.deepEqual([...errors, ...consoleDiagnostics().unexpected], [], 'Startup produced browser errors');
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
    const workersBeforeAutomatic = workers.filter((url) => url.endsWith('/offline_bible_worker.dart.js')).length;

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
    assert.ok(!requests.some((request) => automaticBulkUrls.has(request.url)),
      'Deferred automatic checks must preserve the cache-only reader phase');
    setApiOffline(true);
    deferAutomaticChecks = false;
    releaseAutomaticChecks();
    await Promise.all([...pendingFixtureResponses]);
    await page.close();
    page = await context.newPage();
    page.setDefaultTimeout(45000);
    await page.goto(origin + basePath, { waitUntil: 'domcontentloaded' });
    await enableSemantics(page);
    await readerVisible(page);
    await page.getByRole('button', { name: noteText }).waitFor();
    await inspectVerification(page, { verified: false });
    assert.ok(requests.some((request) => request.apiOffline),
      'Cached chapter path must attempt current-source verification');
    console.log(`${mode}: cached passage and note reopened without public APIs`);

    // Failed background checks intentionally persist their retry backoff. Use
    // the real clear-downloads control to reset that public state, preserving
    // the private note, before testing a successful automatic online startup.
    await openDownloads(page);
    await clearDownloads(page);
    await page.getByRole('button', { name: 'Close offline resources', exact: true }).click();
    await page.getByRole('button', { name: noteText }).waitFor();
    setApiOffline(false);
    await page.close();
    page = await context.newPage();
    page.setDefaultTimeout(45000);
    await page.goto(origin + basePath, { waitUntil: 'domcontentloaded' });
    await enableSemantics(page);
    await readerVisible(page);
    await page.getByRole('button', { name: noteText }).waitFor();

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

    // Startup must install every advertised dictionary/commentary plus the
    // selected Bible without pressing any Install control. Chapter two remains
    // unvisited, so its later offline read cannot use the chapter cache.
    assert.ok(!requests.some((request) => request.url.endsWith('/1/2.json')));
    await openDownloads(page);
    await installedBible(page).waitFor();
    await installedDictionary(page).waitFor();
    await installedCommentary(page).waitFor();
    for (const url of automaticBulkUrls) {
      assert.ok(requests.some((request) => request.url === url),
        `Automatic startup must fetch the complete resource: ${url}`);
    }
    assert.ok(workers.filter((url) => url.endsWith('/offline_bible_worker.dart.js')).length >= workersBeforeAutomatic + 3,
      'Bible, dictionary and commentary activation must use the production worker');
    assert.ok(!requests.some((request) => request.url === 'https://bookmarks.getbible.net/v1/all.json'),
      'The complete public bookmark dataset must remain an explicit choice');
    console.log(`${mode}: Bible, dictionary and commentary installed automatically`);

    // Exclusion removes the public copy and survives a new page. Other saved
    // resources and the user's restored private note must remain available.
    const dictionaryDownloads = () => requests.filter((request) => request.url === dictionaryBulkUrl).length;
    const dictionaryBeforeExclusion = dictionaryDownloads();
    await installedDictionary(page).getByRole('checkbox', { name: /^Keep offline/, checked: true }).click();
    await installedDictionary(page).waitFor({ state: 'hidden' });
    await page.getByRole('button', { name: 'Close offline resources', exact: true }).click();
    await page.getByRole('button', { name: restoredNoteText }).waitFor();
    await page.close();
    page = await context.newPage();
    page.setDefaultTimeout(45000);
    await page.goto(origin + basePath, { waitUntil: 'domcontentloaded' });
    await enableSemantics(page);
    await readerVisible(page);
    await page.getByRole('button', { name: restoredNoteText }).waitFor();
    await openDownloads(page);
    await installedBible(page).waitFor();
    await installedCommentary(page).waitFor();
    assert.equal(dictionaryDownloads(), dictionaryBeforeExclusion,
      'An excluded dictionary must not be downloaded again on startup');

    // Clear installed public data through the real manager, then restart. The
    // default Bible/commentary return while the dictionary exclusion persists.
    await clearDownloads(page);
    await page.getByRole('button', { name: 'Close offline resources', exact: true }).click();
    await page.getByRole('button', { name: restoredNoteText }).waitFor();
    await page.close();
    page = await context.newPage();
    page.setDefaultTimeout(45000);
    await page.goto(origin + basePath, { waitUntil: 'domcontentloaded' });
    await enableSemantics(page);
    await readerVisible(page);
    await page.getByRole('button', { name: restoredNoteText }).waitFor();
    await openDownloads(page);
    await installedBible(page).waitFor();
    await installedCommentary(page).waitFor();
    assert.equal(dictionaryDownloads(), dictionaryBeforeExclusion,
      'Clear downloads must preserve per-resource exclusions');
    await page.getByRole('button', { name: 'Browse catalogue', exact: true }).click();
    await page.getByRole('textbox', { name: 'Find a resource', exact: true }).click();
    await page.locator('input:focus, textarea:focus').fill('Greek lexicon');
    const dictionaryChoice = page.getByRole('group', {
      name: /^Greek lexicon · en\s+Dictionary[\s\S]*https:\/\/dictionaries\.getbible\.net/,
    });
    await dictionaryChoice.getByRole('checkbox', { name: /^Keep offline/, checked: false }).waitFor();
    await dictionaryChoice.getByRole('checkbox', { name: /^Keep offline/, checked: false }).click();
    await installedDictionary(page).waitFor();
    assert.ok(dictionaryDownloads() > dictionaryBeforeExclusion,
      'Restoring Keep offline must reactivate the complete dictionary');
    assert.equal(
      await page.getByRole('textbox', { name: 'Find a resource', exact: true }).inputValue(),
      'Greek lexicon',
      'Automatic activation must preserve the visible catalogue filter',
    );
    await page.getByRole('button', { name: 'Close offline resources', exact: true }).click();
    await page.getByRole('button', { name: restoredNoteText }).waitFor();
    console.log(`${mode}: exclusions, clear downloads and automatic restoration preserved private data`);

    // A new page discards all Dart state. It reopens the production browser
    // database, while public APIs fail and local release assets still load.
    const requestsBeforeInstalledRestart = requests.length;
    setApiOffline(true);
    await page.close();
    page = await context.newPage();
    page.setDefaultTimeout(45000);
    await page.goto(origin + basePath, { waitUntil: 'domcontentloaded' });
    await enableSemantics(page);
    await readerVisible(page);
    await page.getByRole('button', { name: restoredNoteText }).waitFor();
    await inspectVerification(page, { verified: true });
    await page.getByRole('button', { name: /^Open Bible navigation/ }).click();
    await page.getByRole('button', { name: 'Downloads & storage', exact: true }).press('Enter');
    await installedDictionary(page).waitFor();
    await installedCommentary(page).waitFor();
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
    await page.getByRole('button', { name: /^Search source\s+Installed Bible \(offline\)/ }).waitFor();
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
    // Playwright's polling predicate must be synchronous: an async predicate
    // yields a truthy Promise before registration has actually completed.
    // Await the native lifecycle instead, with a bounded installation timeout.
    await page.evaluate(async () => {
      let timeout;
      try {
        await Promise.race([
          (async () => {
            const registration = await navigator.serviceWorker.ready;
            const worker = registration.active;
            if (worker.state === 'activated') return;
            await new Promise((resolveActive, reject) => {
              const changed = () => {
                if (worker.state === 'activated') {
                  worker.removeEventListener('statechange', changed);
                  resolveActive();
                } else if (worker.state === 'redundant') {
                  worker.removeEventListener('statechange', changed);
                  reject(new Error('Application shell became redundant before activation'));
                }
              };
              worker.addEventListener('statechange', changed);
              changed();
            });
          })(),
          new Promise((_, reject) => {
            timeout = setTimeout(() => reject(new Error('Application shell activation timed out')), 90000);
          }),
        ]);
      } finally {
        clearTimeout(timeout);
      }
    });
    const shellState = await page.evaluate(async () => {
      const registration = await navigator.serviceWorker.getRegistration();
      const cacheNames = await caches.keys();
      return {
        pageUrl: location.href,
        baseUri: document.baseURI,
        scope: registration?.scope,
        worker: registration?.active?.scriptURL,
        workerState: registration?.active?.state,
        caches: await Promise.all(cacheNames.map(async (name) => ({
          name, entries: (await (await caches.open(name)).keys()).length,
        }))),
      };
    });
    await writeFile(join(outputDirectory, `${mode}-shell.json`), JSON.stringify(shellState, null, 2));
    assert.equal(shellState.scope, origin + basePath);
    assert.equal(shellState.worker, origin + basePath + 'offline_service_worker.js');
    assert.equal(shellState.workerState, 'activated');
    // Fixture setup is complete. Let the browser's native offline navigation
    // use its service worker without Playwright interception; request events
    // above continue to prove that no public service is requested.
    await context.unrouteAll({ behavior: 'wait' });
    console.log(`${mode}: production application shell installed`);
    networkPhase++;
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
    assert.ok(!requests.some((request) => request.url === 'https://bookmarks.getbible.net/v1/all.json'),
      'Automatic startup, restoration and updates must never fetch bookmark bulk');
    assert.deepEqual([...errors, ...consoleDiagnostics().unexpected], [], 'Release UI produced browser errors');
    assert.deepEqual(missingAssets, [], 'Release UI requested missing assets');
    return { mode, status: 'passed', checks: ['reader startup', 'SQLite write', 'API-offline cached reader', 'inline cache verification without a modal', 'private backup download and file restore', 'automatic Bible, dictionary and commentary activation by production workers', 'persistent resource exclusion and restoration', 'clear downloads preserves private data and exclusions', 'bookmark bulk remains opt-in', 'resource filter survives activation', 'new-page persistence', 'unvisited installed chapter without HTTP', 'installed search without HTTP', 'deep-linked application shell and chapter navigation with all networking disabled', '20,000-verse worker liveness', 'no browser errors'] };
  } catch (error) {
    if (page && !page.isClosed()) {
      await page.screenshot({ path: join(outputDirectory, `${mode}-failure.png`) }).catch(() => {});
      await writeFile(join(outputDirectory, `${mode}-failure.html`), await page.content()).catch(() => {});
    }
    throw error;
  } finally {
    deferAutomaticChecks = false;
    releaseAutomaticChecks();
    await Promise.allSettled([...pendingFixtureResponses]);
    const diagnostics = consoleDiagnostics();
    await writeFile(join(outputDirectory, `${mode}-browser.json`), JSON.stringify({
      errors: [...errors, ...diagnostics.unexpected], expectedDiagnostics: diagnostics.expected,
      injectedDisconnects, missingAssets, requests, workers, deferredShellLoads,
    }, null, 2));
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
