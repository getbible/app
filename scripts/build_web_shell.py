#!/usr/bin/env python3
"""Generate a verified, versioned offline shell for a completed Flutter Web build.

Only static build files enter this cache. Scripture, private reader data and API
responses keep their application-owned storage policy. Run after flutter build
web and before browser acceptance or packaging; generated files stay in build/.
"""
from __future__ import annotations

import argparse
from dataclasses import asdict, dataclass
import hashlib
import json
import os
from pathlib import Path
import re
import sys
import tempfile


MAX_FILE_BYTES = 64 * 1024**2
MAX_TOTAL_BYTES = 256 * 1024**2
MAX_FILES = 4096
MANIFEST_NAME = "offline-shell-manifest.json"
WORKER_NAME = "offline_service_worker.js"
MARKER_NAME = ".getbible-shell-complete"
ENABLED_META = '<meta name="getbible-offline-shell" content="enabled">'
DISABLED_META = '<meta name="getbible-offline-shell" content="disabled">'
REQUIRED_FILES = {
    "index.html", "flutter_bootstrap.js", "main.dart.js", "sqlite3.wasm",
    "drift_worker.dart.js", "offline_bible_worker.dart.js", "offline_shell.js",
}

# This exact template is part of cache identity. Changing worker behavior cannot
# reuse a completed cache installed by an earlier worker with the same assets.
WORKER_TEMPLATE = r"""'use strict';
const SHELL = __GETBIBLE_SHELL_MANIFEST__;
const BASE = new URL(self.registration.scope);
const PREFIX = 'getbible-shell:' + BASE.href + ':';
const VERSION = SHELL.revision + '-' + SHELL.worker_revision;
const CACHE = PREFIX + VERSION;
const COMPLETE = new URL('.getbible-shell-complete', BASE).href;
const ASSETS = new Map(SHELL.files.map((entry) => [new URL(entry.path, BASE).href, entry]));
const INDEX = new URL('index.html', BASE).href;
const TIMEOUT_MS = 30000;

async function complete(cache) {
  const marker = await cache.match(COMPLETE);
  if (!marker || await marker.text() !== VERSION) return false;
  for (const url of ASSETS.keys()) if (!await cache.match(url)) return false;
  return true;
}

async function verifiedResponse(url, entry, controller) {
  const timer = setTimeout(() => controller.abort(), TIMEOUT_MS);
  try {
    const response = await fetch(url, {
      cache: 'no-store', credentials: 'omit', redirect: 'error', signal: controller.signal,
    });
    if (response.status !== 200 || response.type === 'opaque' || !response.body) {
      throw new Error('Offline shell asset is unavailable: ' + entry.path);
    }
    const bytes = new Uint8Array(entry.bytes);
    const reader = response.body.getReader();
    let offset = 0;
    try {
      for (;;) {
        const { value, done } = await reader.read();
        if (done) break;
        if (offset + value.byteLength > bytes.byteLength) {
          throw new Error('Offline shell asset exceeds its recorded size: ' + entry.path);
        }
        bytes.set(value, offset);
        offset += value.byteLength;
      }
    } catch (error) {
      await reader.cancel().catch(() => {});
      throw error;
    } finally {
      reader.releaseLock();
    }
    const hash = Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256', bytes)))
      .map((value) => value.toString(16).padStart(2, '0')).join('');
    if (offset !== entry.bytes || hash !== entry.sha256) {
      throw new Error('Offline shell asset differs from the build: ' + entry.path);
    }
    const headers = new Headers(response.headers);
    // Fetch already decoded transport compression. Preserve isolation/MIME/CSP
    // headers without incorrectly labelling the verified bytes as compressed.
    headers.delete('content-encoding');
    headers.delete('content-length');
    return new Response(bytes, { status: 200, headers });
  } finally {
    clearTimeout(timer);
  }
}

async function install() {
  let cache = await caches.open(CACHE);
  if (await complete(cache)) return;
  await caches.delete(CACHE);
  cache = await caches.open(CACHE);
  const controller = new AbortController();
  const entries = Array.from(ASSETS.entries());
  let cursor = 0;
  async function worker() {
    try {
      while (!controller.signal.aborted && cursor < entries.length) {
        const [url, entry] = entries[cursor++];
        const response = await verifiedResponse(url, entry, controller);
        await cache.put(url, response);
      }
    } catch (error) {
      controller.abort();
      throw error;
    }
  }
  // Drain all workers before removing a failed staged cache; late writes must
  // not leave a partly populated generation advertised as ready.
  const results = await Promise.allSettled(Array.from({ length: Math.min(4, entries.length) }, worker));
  const failure = results.find((result) => result.status === 'rejected');
  try {
    if (failure) throw failure.reason;
    await cache.put(COMPLETE, new Response(VERSION, { headers: { 'content-type': 'text/plain' } }));
  } catch (error) {
    await caches.delete(CACHE);
    throw error;
  }
}

self.addEventListener('install', (event) => {
  // No skipWaiting: existing tabs keep their matching assets and unsaved work.
  event.waitUntil(install());
});

self.addEventListener('activate', (event) => {
  event.waitUntil((async () => {
    const cache = await caches.open(CACHE);
    if (!await complete(cache)) throw new Error('Offline shell installation is incomplete');
    for (const name of await caches.keys()) {
      if (name.startsWith(PREFIX) && name !== CACHE) await caches.delete(name);
    }
    // Do not claim existing pages: their initial HTML may belong to an older
    // deployment than this newly installed cache. The next navigation adopts
    // this complete generation naturally, without switching a running editor.
  })());
});

async function asset(url) {
  const cache = await caches.open(CACHE);
  const cached = await cache.match(url);
  if (cached) return cached;
  // Repair an evicted static asset only if its bytes still match this version.
  // A newer server bundle must not be mixed into an older active application.
  const response = await verifiedResponse(url, ASSETS.get(url), new AbortController());
  await cache.put(url, response.clone());
  return response;
}

self.addEventListener('fetch', (event) => {
  const request = event.request;
  const url = new URL(request.url);
  if (request.method !== 'GET' || url.origin !== BASE.origin || !url.pathname.startsWith(BASE.pathname)) return;
  url.search = '';
  url.hash = '';
  if (ASSETS.has(url.href)) {
    event.respondWith(asset(url.href));
  } else if (request.mode === 'navigate') {
    // Friendly passage routes share the cached entry point; never cache the
    // requested route/query or any private/public API response.
    event.respondWith(asset(INDEX));
  }
});
"""


class ShellBuildError(Exception):
    """An incomplete or unsafe Web build cannot be advertised as offline ready."""


@dataclass(frozen=True)
class ShellAsset:
    path: str
    bytes: int
    sha256: str


def canonical_json(value) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=True).encode("ascii")


def atomic_write(path: Path, content: bytes) -> None:
    with tempfile.NamedTemporaryFile(dir=path.parent, prefix=".shell-", delete=False) as output:
        temporary = Path(output.name)
        try:
            os.chmod(temporary, 0o644)
            output.write(content)
            output.flush()
            os.fsync(output.fileno())
        except BaseException:
            temporary.unlink(missing_ok=True)
            raise
    try:
        temporary.replace(path)
    finally:
        temporary.unlink(missing_ok=True)


class ShellBuilder:
    def __init__(self, directory: Path):
        self.directory = directory.resolve()

    def build(self) -> dict:
        if not self.directory.is_dir():
            raise ShellBuildError("Flutter Web build directory is missing")
        files = {}
        for path in self.directory.rglob("*"):
            name = path.relative_to(self.directory).as_posix()
            if path.is_symlink():
                raise ShellBuildError(f"Static build contains a symlink: {name}")
            if path.is_dir():
                continue
            if (not path.is_file() or not re.fullmatch(r"[A-Za-z0-9._~+/-]+", name)
                    or any(part in ("", ".", "..") for part in name.split("/")) or name == MARKER_NAME):
                raise ShellBuildError(f"Unsupported static build path: {name}")
            if name not in {MANIFEST_NAME, WORKER_NAME}:
                files[name] = path
        if not REQUIRED_FILES <= files.keys():
            raise ShellBuildError("Missing compiled application files: " + ", ".join(sorted(REQUIRED_FILES - files.keys())))
        if len(files) > MAX_FILES:
            raise ShellBuildError("Static build contains too many files")
        index = files["index.html"].read_text(encoding="utf-8")
        if index.count(DISABLED_META) + index.count(ENABLED_META) != 1 or 'src="offline_shell.js"' not in index:
            raise ShellBuildError("Built index is missing the offline loader and its build-only opt-in marker")
        bases = re.findall(r'<base\s+href="([^"]+)"\s*/?>', index)
        if (len(bases) != 1 or not re.fullmatch(r"/(?:[A-Za-z0-9._~-]+/)*", bases[0])
                or any(part in (".", "..") for part in bases[0].split("/"))):
            raise ShellBuildError("Built index must use a local absolute base path with a trailing slash")
        index_bytes = index.replace(DISABLED_META, ENABLED_META).encode("utf-8")
        bootstrap = files["flutter_bootstrap.js"].read_text(encoding="utf-8")
        if re.search(r"_flutter\.loader\.load\(\s*\{[^)]*serviceWorkerSettings", bootstrap):
            raise ShellBuildError("Disable Flutter's legacy service worker before enabling this offline shell")
        assets = []
        total = 0
        for name, path in sorted(files.items()):
            size = len(index_bytes) if name == "index.html" else path.stat().st_size
            total += size
            if size > MAX_FILE_BYTES or total > MAX_TOTAL_BYTES:
                raise ShellBuildError("Static build exceeds the bounded offline cache budget")
            if name == "index.html":
                checksum = hashlib.sha256(index_bytes).hexdigest()
            else:
                with path.open("rb") as data:
                    checksum = hashlib.file_digest(data, "sha256").hexdigest()
            assets.append(asdict(ShellAsset(name, size, checksum)))
        manifest = {
            "schema_version": 1, "files": assets,
            "revision": hashlib.sha256(canonical_json(assets)).hexdigest(),
            "worker_revision": hashlib.sha256(WORKER_TEMPLATE.encode("utf-8")).hexdigest(),
        }
        worker = WORKER_TEMPLATE.replace("__GETBIBLE_SHELL_MANIFEST__", canonical_json(manifest).decode("ascii"))
        # Publication/packaging occurs after this command succeeds. Each file is
        # replaced atomically; a deployment never serves temporary file bytes.
        atomic_write(files["index.html"], index_bytes)
        atomic_write(self.directory / MANIFEST_NAME, canonical_json(manifest) + b"\n")
        atomic_write(self.directory / WORKER_NAME, worker.encode("utf-8"))
        return manifest


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build-dir", type=Path, default=Path("build/web"))
    args = parser.parse_args()
    try:
        manifest = ShellBuilder(args.build_dir).build()
        print(f'Offline shell: {len(manifest["files"])} files, {sum(entry["bytes"] for entry in manifest["files"])} bytes, revision {manifest["revision"]}')
    except (ShellBuildError, OSError, UnicodeError, ValueError) as error:
        print(f"Offline shell build failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
