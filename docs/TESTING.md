# Testing and manual QA

## Interactive platform testing

Run `flutter devices` to list available targets. Use `flutter run -d chrome` for the quickest browser test, or `flutter run -d <device-id>` for a connected phone, emulator, simulator, or desktop target. A successful GitHub Actions run exposes Android APK and web-build artifacts from its summary page.

pub.dev distributes Dart/Flutter libraries; it does not host or execute this application. Browser previews should use a locally served web build or an explicitly configured GitHub Pages deployment. Mobile prereleases should use Android APK/Play internal testing and iOS TestFlight.

## Automated

```bash
dart format --output=none --set-exit-if-changed .
flutter analyze
flutter test
flutter test integration_test/reader_upgrade_test.dart -d <device-id>
flutter test integration_test/study_workspace_test.dart -d <device-id>
```

Required suites cover serialization, API parsing, passage links, expiry/hash invalidation, offline fallback, Unicode/RTL search, marking overlap removal, annotation translation rules, note merge/order, backup fixtures, migrations, reader widgets, toolbar positioning, inline notes, and accessibility semantics.

The cached-Scripture status regression suite renders both verified and
unverified offline states in a narrow viewport at 200% text scaling. This
guards the web and small-screen reader against assertion failures and layout
overflow before an offline-cache change is merged.

The reader-menu regression suite renders an API-supplied long translation name
inside the exact 244 logical-pixel field reported by the web target at 200%
text scaling. It also opens the compact verification badge and checks both the
hash-verified and saved-offline explanations.

### Rich Scripture and annotation preservation

The focused suites are `scripture_text_test.dart`, `scripture_layout_test.dart`,
`scripture_verse_text_test.dart`, `scripture_paragraph_selection_test.dart` and
`scripture_annotation_compatibility_test.dart`. They exercise multiword and
unlocated tokens, source word/token coordinates, overlapping source/private
layers, source-style toggling, Unicode whitespace, emoji/UTF-16, combining
characters, RTL and continuous scripts. Native selection and Copy retain the
original verse text in line and paragraph layouts; paragraph markers and joining
separators do not enter private saved quotes/ranges. Changed quotes remain saved
without coloring unrelated text. Ordered editorial headings and paragraph
ranges use emitted verse IDs, while rich/plain introduction and verse widgets
are checked at 200% text scale.

The shared reader workflow in `test/support/reader_upgrade_journey.dart` runs
through `test/reader_upgrade_test.dart` and
`integration_test/reader_upgrade_test.dart`. It complements the focused widgets
with the composed reader/application/repository workflow. Run its integration
entry point on an available configured device or browser and record that target:

```bash
flutter test test/reader_upgrade_test.dart
flutter test integration_test/reader_upgrade_test.dart -d <device-id>
```

These automated journeys do not substitute for physical-device selection,
clipboard, screen-reader or browser-CORS evidence. Source-style controls must
also be checked beside personal colors, note drafts and native selection during
manual phone/tablet and desktop QA.

### Query v3 reference preview

Run the focused contract and native-widget suites with:

```bash
flutter test test/reference_lookup_test.dart test/reference_preview_test.dart
```

`reference_lookup_test.dart` covers compact Query envelopes, exact source verse
IDs, absent optional chapter metadata, lossless lexical/source fields and `ref`
arrays, translation/coordinate validation, Unicode-safe single-segment URL
encoding, and HTTP 404 without fallback. Structured fixtures exercise individual
and ranged verses, noncontiguous and multi-chapter selections, discovered book
names with source-language labels, and simultaneous 512-character/eight-reference/
200-verse batching bounds. The aggregate stays unavailable if any batch fails
or a requested coordinate is missing. Oversized text and unavailable books have
explicit outcomes. The committed `test/fixtures/query_v3_compact.json` fixture
also round-trips without adding absent source fields and has been checked
against the published Query v3 OpenAPI Scripture schema.

Fresh-cache regression cases return malformed JSON or invalid Scripture with
`Cache-Control: max-age=600`, then corrected Scripture. Retry must fetch the
corrected response, and subsequent lookup may reuse only the valid cache body.
Cancellation tests replace and dismiss requests before late completion;
citation-history tests prove bounded retention and reuse of loaded back entries.

`reference_preview_test.dart` covers displayed reference/translation, exact raw
Copy, exact-verse Open, typed input retaining the selected Bible, RTL fallback
when compact metadata omits direction, loading/unavailable/retry states, HTTP
input errors distinct from offline failures, failed Open, 200% text on a narrow
surface, compact and wide presentation, and focus/scroll preservation on close.
Route-race regressions delay Open, then dismiss the preview or select another
citation: completion must not dismiss another route or the newer citation.

For device/browser QA, open Reference preview from the chapter heading or
navigation drawer and from a verse context menu. Try a range and multiple
references; verify the selected translation and original source label. Close
with the close control, back/Escape and sheet dismissal, confirming that the
reader's passage, scroll, focus and private annotations remain unchanged.
Open a distant verse and confirm its exact source ID is visible after navigation.
Exercise RTL, large text, keyboard input/selection, Copy, offline failure,
404, rate limit and retry, and confirm no chapter turn fires while the preview
is open. Widget tests do not establish actual browser CORS, physical-device
clipboard behavior or offline installed-Bible resolution.

### Search and contextual Study

The focused suites cover Search pagination/filter/reference envelopes, late
responses and route ownership; dictionary identifiers/aliases and bounded
history; sparse commentary ranges and introductions; public-topic locales and
explicit collision-safe copying; and notebook ordering, autosave, draft conflicts,
Unicode limits and forward schema migrations. See the individual feature guides
for their contract cases.

`test/support/study_workspace_journey.dart` runs through
`test/study_composition_test.dart` and
`integration_test/study_workspace_test.dart`. It opens Study from original
Scripture text, reads on-demand dictionaries/commentary, follows and explicitly
copies a public topic, edits a private notebook, and reopens it offline. It verifies
that canonical verse-note identities and original Scripture stay unchanged and
that the workflow performs no bulk resource download.

Additional composed regressions cover Search dismissal and delayed Open,
stored-citation Bible attribution, wide/compact nested notebook preview routes,
word tap versus native selection/scrolling, and short-height large-text Study
surfaces. `app_shutdown_test.dart` overlaps two shutdowns before autosave fires
and reopens actual SQLite to verify the final private edit survived.
Its fault-injection case rejects a failed journal write, verifies that the draft,
database and public reader remain usable, and retries shutdown after recovery.

CI runs both native Linux journeys before building the Linux release. Integration
tests use deterministic HTTP fixtures; public contracts and real downloaded
resource documents are checked separately. Neither replaces physical-device
gestures, assistive technology, clipboard, process suspension or browser-runtime
CORS QA. After an integration run, use normal `flutter pub get`/build commands
for the production target so the integration-test plugin is not retained in
production plugin registration.

For manual QA, exercise Study with native selection, 200% text, RTL, a visible
keyboard and a short landscape viewport. Open a notebook reference preview,
Open in reader, then return to the still-owned insertion dialog: its captured
quotation must remain the original text. Search from captured Study context must
retain that context's Bible even after a reference changed the reader's Bible.
Check dirty indicators, retry and recovery before suspending or restarting.

## Primary manual journeys

1. Clean install opens daily/KJV behavior and changes translation.
2. Navigate books, chapters, previous/next boundaries, and swipe.
3. Restart and restore the last visible verse.
4. Open a cached chapter with networking disabled.
5. Mark/remove selected text and whole verses across translations.
6. Add/edit/delete an inline note.
7. Download/search a translation and open a highlighted result.
8. Export, clear data, import, and verify conflict rules.
9. Switch to RTL Scripture and exercise selection/navigation.
10. Test phone/tablet, portrait/landscape, dark/light, 200% text, keyboard, and screen reader.

## Side-by-side parity review

Before a release, run the Flutter app beside `https://app.getbible.life/` using equivalent viewport sizes and the same passage. Compare navigation, daily Scripture, typography/layout, themes, toolbar anchoring, marking and note behavior, search results, Markdown, translation metadata, offline indicators, localization, RTL, restoration, and destructive confirmations. Record every material difference in `FEATURE_PARITY.md`; do not normalize a missing Flutter workflow as a platform difference.

Visually inspect the launcher, splash, task-switcher/window icon, browser favicon/PWA icon, and in-app wordmark on light and dark system surfaces. `sha256sum -c assets/branding/BRAND_ASSETS.sha256` must pass before testing release artifacts.

Do not declare physical-device behavior verified from widget tests alone.
