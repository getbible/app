# Agent operating guide

This file is authoritative for automated coding agents working in this repository.

## Mission

Maintain a production-quality, native Flutter implementation named **getBible** in `getbible/app`. Preserve the React website and its backup contract. Android, iOS, web, Windows, macOS, and Linux are supported Flutter targets, with mobile release signing treated as a platform-specific concern. Never replace the reader with a WebView, add tracking, invent cloud synchronization, or commit credentials/signing material.

## Read first

1. Read `README.md` and all files in `docs/`.
2. Inspect `git status` and preserve unrelated changes.
3. Compare requested behavior with `docs/FEATURE_PARITY.md` and the current web application/repository.
4. Mark an item complete only after implementation and automated or documented manual verification.

## Architecture boundaries

- `domain/` has framework-independent models and repository contracts.
- `data/` owns API, SQLite, caching, and repository implementations.
- `application/` coordinates state and use cases; it must not parse raw API JSON.
- `presentation/` contains Flutter widgets; widgets must not issue SQL or raw HTTP.
- `services/` contains bounded operations such as search, backup, and Markdown.

Keep canonical annotations translation-neutral: whole-verse markings and notes use book/chapter/verse across translations. Selected-text markings include the translation and character range. Validate data before storage changes. Move full-translation parsing/search off the UI isolate.

## Required workflow

```bash
flutter pub get
dart format .
flutter analyze
flutter test
```

For release-affecting changes, also build Android APK/AAB and unsigned iOS on macOS. Record environment limitations honestly. Do not label untested work stable.

## Database and migrations

Never edit an existing released schema in place. Increment `localDatabaseSchemaVersion`, implement forward migration, add a migration fixture/test, and document the change in `docs/DATA_AND_BACKUPS.md`. Backups must be completely parsed and validated before mutating stored data.

## API and cache rules

Discover translations/books/chapters dynamically. Use SHA endpoints for chapter verification. Preserve readable cached Scripture on network failures. Invalidate the narrowest affected cache prefix when hashes change. Whole-translation downloads require deliberate user action for offline/search usage.

## UI rules

Scripture is the visual priority. Respect safe areas, RTL, large text, semantics, keyboard focus, reduced motion, and 48dp touch targets. Notes are edited inline below verses. Contextual annotation controls belong near the verse/selection, not permanently at the bottom.

## Product parity and brand assets

The current `getbible/app.getbible.life` default branch and live application are the product source of truth. Treat `docs/WEB_FLUTTER_PARITY.md` as a living, test-backed contract. A web feature is not complete in Flutter until its native equivalent, persistence rules, localization, accessibility behavior, and tests exist. Update both ledgers whenever either implementation changes.

Only the approved GetBible artwork under `assets/branding/` may be used for launchers, favicons, splash screens, window icons, store artwork, or in-app product branding. Never restore Flutter template icons or substitute framework/vendor icons for the application identity. Material/Cupertino icons remain appropriate for ordinary accessible actions such as search, close, share, and settings.

## Git and delivery

Use intentional commits, never rewrite public history, and never commit generated secrets or private keys. CI must remain green. Update the parity ledger and documentation with every material feature change.
