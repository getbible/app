# Compiled web release smoke test

This checks the **normal production entry point** in a real Chromium browser,
including the shipped Drift worker and SQLite Wasm. It does not compile an
integration-test replacement app or inject a fake database.

From the repository root, with Flutter 3.44.6 and Node 22 or newer:

```bash
flutter pub get
dart compile js -O2 tool/offline_bible_worker.dart -o web/offline_bible_worker.dart.js
flutter build web --release --no-web-resources-cdn --base-href /flutter/
npm ci --prefix tool/browser_smoke
npx --prefix tool/browser_smoke playwright install --with-deps chromium
node tool/browser_smoke/run.mjs --build-dir build/web --base-path /flutter/
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

1. Load the exact release at the configured deployment base path.
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
8. Fail on uncaught browser exceptions, unexpected console errors or missing
   release assets.

“Offline” here means public APIs are disconnected while local static files still
load. This verifies SQLite persistence, installed Scripture and local search after Dart
state is discarded; it does not claim that a first-ever visit or a service-worker-free
static deployment can cold-start without its application files.

The test creates a fresh browser context for each hosting mode. It never touches
an existing developer browser profile. It emits screenshots, browser errors,
request records, Playwright traces and `results.json` into `build/browser-smoke`.
CI should upload that directory even after failure. Override it with
`--output-dir PATH`; use `--browser-channel chrome` to test a separately installed
Google Chrome. The pinned Chromium dependency keeps the required CI gate
reproducible.
