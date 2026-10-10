import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdtemp, mkdir, readFile, rm, writeFile } from 'node:fs/promises';
import { createServer } from 'node:http';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import test from 'node:test';
import { chromium } from '../browser_smoke/node_modules/playwright/index.mjs';

const repository = resolve(import.meta.dirname, '../..');

test('deployment during first install leaves an open editor uncontrolled; next offline page adopts the complete new shell', { timeout: 30000 }, async () => {
  const directory = await mkdtemp(join(tmpdir(), 'getbible-shell-browser-'));
  let browser;
  let server;
  let unblockLoader;
  try {
    const loader = await readFile(join(repository, 'web/offline_shell.js'));
    for (const version of ['A', 'B']) {
      const build = join(directory, version);
      await mkdir(build);
      const files = {
        'index.html': `<html><head><base href="/flutter/"><meta name="getbible-offline-shell" content="disabled"><script>window.pageVersion='${version}';window.privateDraft='unsaved ${version} note';</script><script src="offline_shell.js" defer></script></head><body>${version}</body></html>`,
        'flutter_bootstrap.js': '_flutter.loader.load();', 'main.dart.js': `application version ${version}`,
        'sqlite3.wasm': 'wasm', 'drift_worker.dart.js': 'database();',
        'offline_bible_worker.dart.js': 'offline();', 'offline_shell.js': loader,
      };
      for (const [name, body] of Object.entries(files)) await writeFile(join(build, name), body);
      execFileSync('python3', [join(repository, 'scripts/build_web_shell.py'), '--build-dir', build]);
    }
    let servedVersion = 'A';
    const loaderReady = new Promise((resolveLoader) => { unblockLoader = resolveLoader; });
    server = createServer(async (request, response) => {
      try {
        const pathname = new URL(request.url, 'http://localhost').pathname;
        if (!pathname.startsWith('/flutter/')) return response.writeHead(404).end();
        const name = pathname.slice('/flutter/'.length) || 'index.html';
        if (!/^[A-Za-z0-9._-]+$/.test(name)) return response.writeHead(404).end();
        if (name === 'offline_shell.js' && servedVersion === 'A') await loaderReady;
        const body = await readFile(join(directory, servedVersion, name));
        response.writeHead(200, {
          'content-type': name.endsWith('.js') ? 'text/javascript' : name.endsWith('.html') ? 'text/html' : 'application/octet-stream',
          'cache-control': 'no-store',
        }).end(body);
      } catch { response.writeHead(404).end(); }
    });
    await new Promise((listen) => server.listen(0, '127.0.0.1', listen));
    const origin = `http://127.0.0.1:${server.address().port}/flutter/`;
    browser = await chromium.launch({ headless: true });
    const context = await browser.newContext({ serviceWorkers: 'allow' });
    const originalPage = await context.newPage();
    await originalPage.goto(origin, { waitUntil: 'commit' });
    await originalPage.waitForFunction(() => window.pageVersion === 'A');
    // Reproduce a deployment between the original HTML and its deferred loader.
    servedVersion = 'B';
    unblockLoader();
    await originalPage.evaluate(async () => {
      const registration = await navigator.serviceWorker.ready;
      const worker = registration.active;
      if (worker.state !== 'activated') {
        await new Promise((resolveActive) => worker.addEventListener('statechange', () => {
          if (worker.state === 'activated') resolveActive();
        }));
      }
    });
    assert.deepEqual(await originalPage.evaluate(() => ({
      version: window.pageVersion, draft: window.privateDraft, controlled: navigator.serviceWorker.controller !== null,
    })), { version: 'A', draft: 'unsaved A note', controlled: false });
    await originalPage.close();
    await context.setOffline(true);
    const offlinePage = await context.newPage();
    await offlinePage.goto(origin, { waitUntil: 'domcontentloaded' });
    assert.deepEqual(await offlinePage.evaluate(async () => ({
      version: window.pageVersion, asset: await (await fetch('main.dart.js')).text(),
      controlled: navigator.serviceWorker.controller !== null,
    })), { version: 'B', asset: 'application version B', controlled: true });
  } finally {
    unblockLoader?.();
    await browser?.close();
    if (server) {
      server.closeAllConnections();
      await new Promise((closed) => server.close(closed));
    }
    await rm(directory, { recursive: true, force: true });
  }
});
