import assert from 'node:assert/strict';
import { webcrypto } from 'node:crypto';
import { mkdtemp, readFile, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { execFileSync } from 'node:child_process';
import vm from 'node:vm';
import test from 'node:test';

const root = resolve(import.meta.dirname, '../..');
const fixtureDirectory = await mkdtemp(join(tmpdir(), 'getbible-shell-'));
const fixtureFiles = new Map([
  ['index.html', '<html><base href="/flutter/"><meta name="getbible-offline-shell" content="disabled"><script src="offline_shell.js" defer></script></html>'],
  ['flutter_bootstrap.js', '_flutter.loader.load();'], ['main.dart.js', 'compiled();'],
  ['sqlite3.wasm', 'wasm'], ['drift_worker.dart.js', 'database();'],
  ['offline_bible_worker.dart.js', 'offline();'], ['offline_shell.js', 'register();'],
]);
for (const [name, body] of fixtureFiles) await writeFile(join(fixtureDirectory, name), body);
execFileSync('python3', [join(root, 'scripts/build_web_shell.py'), '--build-dir', fixtureDirectory]);
const script = await readFile(join(fixtureDirectory, 'offline_service_worker.js'), 'utf8');
const manifest = JSON.parse(await readFile(join(fixtureDirectory, 'offline-shell-manifest.json'), 'utf8'));
fixtureFiles.set('index.html', await readFile(join(fixtureDirectory, 'index.html'), 'utf8'));
await rm(fixtureDirectory, { recursive: true, force: true });

class MemoryCache {
  entries = new Map();
  constructor(owner) { this.owner = owner; }
  async match(url) { return this.entries.get(String(url))?.clone(); }
  async put(url, response) {
    if (this.owner.failPath && String(url).endsWith(this.owner.failPath)) throw new Error('Storage quota exceeded');
    this.entries.set(String(url), response.clone());
  }
}

class MemoryCaches {
  values = new Map();
  async open(name) {
    if (!this.values.has(name)) this.values.set(name, new MemoryCache(this));
    return this.values.get(name);
  }
  async delete(name) { return this.values.delete(name); }
  async keys() { return [...this.values.keys()]; }
}

function harness({ scope = 'https://reader.example/flutter/', caches = new MemoryCaches(), worker = script, timeout = 30000 } = {}) {
  const listeners = new Map();
  const requests = [];
  const state = { offline: false, corrupt: null, stalled: null, claimCount: 0, activeFetches: 0, maximumFetches: 0, delay: 0 };
  const context = {
    URL, Headers, Response, Uint8Array, AbortController, crypto: webcrypto,
    setTimeout: (callback, ms) => setTimeout(callback, Math.min(timeout, ms)), clearTimeout, caches,
    self: { registration: { scope }, clients: { claim: async () => { state.claimCount++; } },
      skipWaiting: () => { throw new Error('An update must not interrupt active editors'); },
      addEventListener: (name, callback) => listeners.set(name, callback) },
    fetch: async (url, options) => {
      requests.push({ url, options });
      if (state.offline) throw new Error('All network disabled');
      state.activeFetches++;
      state.maximumFetches = Math.max(state.maximumFetches, state.activeFetches);
      try {
        if (state.delay) await new Promise((resolveDelay) => setTimeout(resolveDelay, state.delay));
        if (options.signal.aborted) throw new Error('Aborted');
        const path = new URL(url).pathname.slice(new URL(scope).pathname.length);
        if (state.stalled === path) {
          await new Promise((_, reject) => options.signal.addEventListener('abort', () => reject(new Error('Aborted')), { once: true }));
        }
        const body = state.corrupt === path
          ? path === 'main.dart.js' ? 'x'.repeat(Buffer.byteLength(fixtureFiles.get(path))) : 'bad response bytes'
          : fixtureFiles.get(path);
        return new Response(body, { status: body === undefined ? 404 : 200,
          headers: { 'content-type': path.endsWith('.html') ? 'text/html' : 'application/octet-stream',
            'cross-origin-opener-policy': 'same-origin', 'cross-origin-embedder-policy': 'require-corp' } });
      } finally { state.activeFetches--; }
    },
  };
  vm.runInNewContext(worker, context);
  return {
    state, requests, caches,
    async dispatch(name) {
      let completion;
      listeners.get(name)({ waitUntil: (promise) => { completion = promise; } });
      await completion;
    },
    fetch(url, { method = 'GET', mode = 'cors' } = {}) {
      let response;
      listeners.get('fetch')({ request: { url, method, mode }, respondWith: (promise) => { response = promise; } });
      return response;
    },
  };
}

test('complete install verifies all assets, bounds concurrency and serves offline reload and friendly routes', async () => {
  const app = harness();
  app.state.delay = 5;
  await app.dispatch('install');
  await app.dispatch('activate');
  assert.equal(app.state.claimCount, 0, 'Activation must not change an already-open page generation');
  assert.equal(app.state.maximumFetches, 4);
  assert.equal(app.requests.length, manifest.files.length);
  assert.ok(app.requests.every(({ options }) => options.cache === 'no-store' && options.credentials === 'omit' && options.redirect === 'error'));
  app.state.offline = true;
  for (const path of ['', 'KJV/John/3?verse=16', 'index.html']) {
    const response = await app.fetch(`https://reader.example/flutter/${path}`, { mode: 'navigate' });
    assert.equal(await response.text(), fixtureFiles.get('index.html'));
    assert.equal(response.headers.get('cross-origin-embedder-policy'), 'require-corp');
  }
  assert.equal(await (await app.fetch('https://reader.example/flutter/main.dart.js?v=one')).text(), 'compiled();');
  assert.equal(app.requests.length, manifest.files.length);
});

test('public API, private requests, other base paths and methods never enter shell cache', async () => {
  const app = harness();
  await app.dispatch('install');
  const before = app.requests.length;
  for (const [url, options] of [
    ['https://api.getbible.net/v3/kjv/1/1.json', {}],
    ['https://reader.example/flutter/api/private-notes', {}],
    ['https://reader.example/other/main.dart.js', {}],
    ['https://reader.example/flutter/main.dart.js', { method: 'POST' }],
  ]) assert.equal(app.fetch(url, options), undefined);
  assert.equal(app.requests.length, before);
});

test('corrupt or oversized downloads remove the staged cache and preserve an active prior generation', async () => {
  for (const corrupt of ['main.dart.js', 'sqlite3.wasm']) {
    const app = harness();
    const old = 'getbible-shell:https://reader.example/flutter/:prior';
    await (await app.caches.open(old)).put('prior', new Response('saved version'));
    app.state.corrupt = corrupt;
    await assert.rejects(app.dispatch('install'), /recorded size|differs from the build/);
    assert.deepEqual(await app.caches.keys(), [old]);
    assert.equal(await (await (await app.caches.open(old)).match('prior')).text(), 'saved version');
    assert.equal(app.state.claimCount, 0);
  }
});

test('incomplete cache has no readiness marker; retry downloads it and activation cleans only its own scope', async () => {
  const app = harness();
  const name = `getbible-shell:https://reader.example/flutter/:${manifest.revision}-${manifest.worker_revision}`;
  await (await app.caches.open(name)).put('partial', new Response('interrupted install'));
  const old = 'getbible-shell:https://reader.example/flutter/:old';
  const other = 'getbible-shell:https://reader.example/another/:old';
  await app.caches.open(old);
  await app.caches.open(other);
  await app.caches.open('private-database-cache');
  await app.dispatch('install');
  await app.dispatch('activate');
  assert.deepEqual(new Set(await app.caches.keys()), new Set([name, other, 'private-database-cache']));
  const requests = app.requests.length;
  await app.dispatch('install');
  assert.equal(app.requests.length, requests, 'A complete identical generation can be reused');
});

test('worker logic changes stage separately and never claim existing pages', async () => {
  const app = harness();
  await app.dispatch('install');
  await app.dispatch('activate');
  const oldNames = await app.caches.keys();
  const changed = harness({ caches: app.caches, worker: script.replace(manifest.worker_revision, 'b'.repeat(64)) });
  await changed.dispatch('install');
  assert.equal(changed.state.claimCount, 0);
  assert.equal((await app.caches.keys()).length, 2);
  assert.ok((await app.caches.keys()).includes(oldNames[0]));
  await changed.dispatch('activate');
  assert.equal(changed.state.claimCount, 0);
  assert.equal((await app.caches.keys()).length, 1);
});

test('late quota failure never marks an incomplete generation ready and retry can recover', async () => {
  const app = harness();
  const prior = 'getbible-shell:https://reader.example/flutter/:old';
  await app.caches.open(prior);
  app.caches.failPath = '.getbible-shell-complete';
  await assert.rejects(app.dispatch('install'), /Storage quota exceeded/);
  assert.deepEqual(await app.caches.keys(), [prior]);
  assert.equal(app.state.claimCount, 0);
  app.caches.failPath = null;
  await app.dispatch('install');
  await app.dispatch('activate');
  assert.equal(app.state.claimCount, 0);
});

test('a stalled static response times out and drains its staged installation', async () => {
  const app = harness({ timeout: 10 });
  app.state.stalled = 'main.dart.js';
  await assert.rejects(app.dispatch('install'), /Aborted/);
  assert.deepEqual(await app.caches.keys(), []);
  assert.equal(app.state.activeFetches, 0);
  assert.equal(app.state.claimCount, 0);
});

test('evicted asset can be repaired only with matching source bytes', async () => {
  const app = harness();
  await app.dispatch('install');
  const cache = await app.caches.open((await app.caches.keys())[0]);
  const url = 'https://reader.example/flutter/main.dart.js';
  cache.entries.delete(url);
  app.state.corrupt = 'main.dart.js';
  await assert.rejects(app.fetch(url), /recorded size|differs from the build/);
  assert.equal(await cache.match(url), undefined);
  app.state.corrupt = null;
  assert.equal(await (await app.fetch(url)).text(), 'compiled();');
});

test('release loader uses its base scope and development/insecure pages do not register', async () => {
  const loader = await readFile(join(root, 'web/offline_shell.js'), 'utf8');
  for (const [enabled, secure, expected] of [['enabled', true, 1], ['disabled', true, 0], ['enabled', false, 0]]) {
    const calls = [];
    vm.runInNewContext(loader, { URL, console,
      document: { querySelector: () => ({ content: enabled }), baseURI: 'https://reader.example/flutter/' },
      window: { isSecureContext: secure, location: { origin: 'https://reader.example' } },
      navigator: { serviceWorker: { register: (...args) => { calls.push(args); return Promise.resolve(); } } },
    });
    assert.equal(calls.length, expected);
    if (expected) {
      assert.equal(String(calls[0][0]), 'https://reader.example/flutter/offline_service_worker.js');
      assert.equal(calls[0][1].scope, 'https://reader.example/flutter/');
      assert.equal(calls[0][1].updateViaCache, 'none');
    }
  }
});
