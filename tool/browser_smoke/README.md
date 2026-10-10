# Compiled web release smoke test

This checks the **normal production entry point** in real Chromium, Firefox and WebKit browsers,
including the shipped Drift worker and SQLite Wasm. It does not compile an
integration-test replacement app or inject a fake database.

From the repository root, with Flutter 3.44.6 and Node 22 or newer:

```bash
flutter pub get
dart compile js -O2 tool/offline_bible_worker.dart -o web/offline_bible_worker.dart.js
flutter build web --release --no-web-resources-cdn --base-href /flutter/
npm ci --prefix tool/browser_smoke
npx --prefix tool/browser_smoke playwright install --with-deps chromium firefox webkit
python3 scripts/build_web_shell.py --build-dir build/web
node tool/browser_smoke/run.mjs --build-dir build/web --base-path /flutter/ --browsers chromium,firefox,webkit
```

`--no-web-resources-cdn` includes CanvasKit in the release directory, so renderer
startup does not require a third-party CDN. The application also bundles its
existing default Roboto font and its license. This covers ordinary UI text; it
does not claim that every Unicode fallback font is installed locally. All public
API requests are fulfilled
with small deterministic fixtures whose SHA-1 values match the exact response
bytes. An unexpected external request fails the test. This suite consequently
checks browser execution and persistence, not live-service availability or CORS
policy. Public API contract checks remain separate.

Each run covers ordinary static hosting and hosting with COOP/COEP isolation:

1. Load a friendly Scripture URL directly beneath the configured deployment
   base path, exercising the host's HTML-only SPA rewrite and base-relative Wasm.
2. Enable Flutter's existing accessibility semantics and find real Scripture.
3. Open the verse's context menu, create a private inline note and save it,
   then reopen the cached passage and note with public APIs disconnected.
4. Download a complete private backup, check its saved note, then select an
   edited backup file through the production file picker and confirm its preview.
5. Browse the catalogue and deliberately install a complete Bible and dictionary
   through the shipped resource worker; verify both worker branches execute.
6. Close the page, disable public API responses, and open a fresh page.
7. Verify the restored note and both installations persist, open a previously
   unvisited chapter, and search the installed Bible with no public HTTP requests.
   Search also checks the compact toolbar at a 700-pixel viewport.
8. Reopen a friendly Scripture URL in a new page with all browser networking
   disabled. The installed shell and saved database must honor that incoming
   chapter instead of restoring a different last-read chapter.
9. Index deterministic 20,000-verse and 20,000-entry dictionary corpora with the
   actual shipped worker. Record bytes, bounded batches, elapsed time, UI
   heartbeat, and long tasks where the engine supports them. Timing is evidence,
   never a device-speed threshold.
10. Fail on uncaught browser exceptions, unexpected console errors or missing
    release assets.

The first offline checks disconnect only public APIs, isolating database behavior
from application delivery. The final check disables all networking after the
versioned application shell has finished installation. This validates an already
installed browser application; a first-ever visit still needs connectivity.
During fixture-based phases the harness defers delivery of `offline_shell.js`:
WebKit requests from controlled pages can bypass Playwright's HTTP interception.
After installing fixture resources, the harness loads the exact production
script, waits for native worker activation and only then disables all networking.
It does not replace the registration API, worker, cache verification, application
or database. The new offline page must be controlled by that actual worker.
An online host must rewrite unknown HTML document routes to `index.html` while
returning 404 for missing JavaScript, Wasm and other assets. The local harness
implements that deployment contract. Worker activation leaves existing pages
alone; a subsequent navigation uses the installed application shell.

The test creates a fresh browser context for each browser and hosting mode. It never touches
an existing developer browser profile. It emits screenshots, browser errors,
request records, Playwright traces and `results.json` into `build/browser-smoke`.
CI should upload that directory even after failure. Override it with
`--output-dir PATH`; use `--browser-channel chrome` to test a separately installed
Google Chrome. Pinned Playwright browser revisions keep the required CI gates reproducible.
WebKit is browser-engine evidence, not a claim of physical iOS Safari testing.
All requested engines and both hosting modes run even when an earlier case fails;
any failure returns a nonzero process status.

Live deployment evidence is a separate bounded read-only probe:

```bash
node tool/browser_smoke/probe-services.mjs
```

It issues one anonymous browser request to each public service, records visible
cache/retry headers and distinguishes HTTP failures from browser network/CORS
failure. `live-services.json` contains the actual origin, timestamp and outcomes.
An upstream outage is reported without misclassifying deterministic app tests;
the probe does not certify production CORS for every deployment origin.
