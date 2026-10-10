# Testing and manual QA

## Interactive platform testing

Run `flutter devices` to list available targets. Use `flutter run -d chrome` for the quickest browser test, or `flutter run -d <device-id>` for a connected phone, emulator, simulator, or desktop target. Every successful CI run retains versioned packages in its Artifacts section. Successful main runs also promote new versions to [GitHub Releases](https://github.com/getbible/app/releases) without rebuilding; see [installation](INSTALLING.md) and [distribution](DEPLOYMENT.md).

pub.dev distributes Dart/Flutter libraries; it does not host or execute this application. Browser previews should use a locally served web build or an explicitly configured GitHub Pages deployment. Mobile prereleases should use Android APK/Play internal testing and iOS TestFlight.

## Automated

```bash
dart format --output=none --set-exit-if-changed .
flutter analyze
flutter test
flutter test integration_test/reader_upgrade_test.dart -d <device-id>
flutter test integration_test/study_workspace_test.dart -d <device-id>
flutter test integration_test/offline_portability_test.dart -d <device-id>
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

Keyboard-metrics regressions exercise positive, transient negative and zero
bottom insets in compact reference and Study sheets. Hosted iPad CI exposed a
negative `RenderPadding` assertion during reference-preview keyboard dismissal;
later focus-tree errors and the Study timeout were consequences of that first
layout failure. Flutter 3.44.6's iOS `FlutterViewController` assigns its keyboard
spring curve directly to `physical_view_inset_bottom`, without a lower bound.
The exact native undershoot was not recorded, so the engine origin remains an
inference; the negative-input layout failure is reproduced deterministically.
The application bounds only negative keyboard clearance at zero and retains
normal positive spacing. The native journey still checks real input, clipboard
readback and unsaved-draft preservation.

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

CI runs the aggregate native Linux acceptance journey before building the Linux
release: reader, Study, private portability, released-schema migration and
background-worker behavior. Integration tests use deterministic HTTP fixtures;
public contracts and real downloaded resource documents are checked separately.
Neither replaces physical-device
gestures, assistive technology, clipboard, process suspension or browser-runtime
CORS QA. After an integration run, use the normal production `flutter build`
command, without an integration-test entry point or `--no-pub`. CI first validates
dependencies with `flutter pub get --enforce-lockfile`, then permits each build's
normal platform preparation. Tests and analysis may reuse that dependency
resolution with `--no-pub`; production builds must regenerate their native tooling
for the selected build mode.

In pinned Flutter 3.44.6, `FlutterCommand.regeneratePlatformSpecificToolingIfApplicable`
returns early when `--no-pub` is set. Standalone `flutter pub get` generates
platform registrants with `releaseMode: false`, while `injectPlugins` filters
development-only plugins for supported release targets. Android's Gradle plugin
separately excludes those native dependencies from release variants. Skipping
regeneration can therefore leave an `integration_test` Java registration whose
native class is absent from the release classpath. The debug APK can pass while
the following release APK fails. The workflow now exercises the complete
debug-APK → release-APK → release-AAB sequence with normal build preparation.
Do not repair this by editing generated registrants, deleting the integration
test dependency or adding test code to release dependencies. Apple plugin
filtering differs in this SDK; a successful build does not establish that every
platform omits all development-only native plugins.

The SDK source documents this behavior in
[`runner/flutter_command.dart`](https://github.com/flutter/flutter/blob/3.44.6/packages/flutter_tools/lib/src/runner/flutter_command.dart),
[`commands/packages.dart`](https://github.com/flutter/flutter/blob/3.44.6/packages/flutter_tools/lib/src/commands/packages.dart)
and [`flutter_plugins.dart`](https://github.com/flutter/flutter/blob/3.44.6/packages/flutter_tools/lib/src/flutter_plugins.dart).

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

## Recorded Study increment validation

Implementation source `76254ab46555a6f5b41fd9b63673001b843e944e` was checked on
Flutter 3.44.6 / Dart 3.12.2. [CI run 37838406451](https://github.com/getbible/app/actions/runs/37838406451)
passed both jobs for this source. Later documentation changes do not replace
the requirement for green CI on the head being reviewed.

| Gate | Recorded result |
|---|---|
| Whole-tree formatting and static analysis | 151 Dart files formatting-clean; no analyzer issues |
| Unit and widget suite | 266 tests passed |
| Native Linux reader integration | Passed, including actual OS clipboard and exact-verse navigation |
| Native Linux Study integration | Passed, including explicit topic copying and offline private-notebook reopening |
| Web / Linux release and Android debug | Passed in the source commit's CI |
| Approved branding | Exact asset checksums passed |
| Current public schemas | 41/41 fixture cases passed against official live Query, Search, Dictionary, Commentary and Bookmark OpenAPI contracts |
| Real public documents | 13 downloaded resource documents accepted by production adapters; no UI/live-browser claim |
| Independent final review | Nine additional focused regressions passed; no blocking finding |

Contract fingerprints were rechecked against the public `/openapi.json`
documents. Real resource checks included Strong's Greek and Abbott-Smith
published indexes, a selected dictionary definition, sparse Abbott commentary
coverage/chapter data, and a public topic/reverse lookup/locales. No bulk corpus
download was required for these workflows.

A 6,917,748-byte published dictionary index with 114,712 entries was exercised
on this Linux worker. Native parsing uses a compute worker; cooperative
filtering/cancellation continued to yield. This JIT measurement is evidence for
the chosen implementation, not a phone/browser performance guarantee.
Five service OPTIONS requests returned successful CORS preflights and exposed
cache/retry headers; actual deployed-browser CORS remains a separate gate.

That recorded increment also validated unsigned Android release APK/AAB output.
It predates the host and distribution workflow described below and is not evidence
that the current head passed Apple/Windows builds or signed-package checks.
At that historical increment, physical-device accessibility, full locale
adoption, complete installations and private notebook portability were still
open. The later sections record their implementation and current evidence;
human linguistic review and physical-device acceptance remain separate gates.

## Distribution and host regression gates

The current workflow restores the pinned Flutter SDK and lockfile, checks every
native target on its corresponding host, and runs the production Web bundle in
Chromium, Firefox and WebKit. `tool/browser_smoke` supplies deterministic fixtures
at public API boundaries, including Bible/daily and Study installation resources.
The app uses its real SQLite WASM and workers, downloads/restores a private backup,
installs Bible and dictionary resources, and reopens with all networking disabled
under both ordinary static hosting and cross-origin-isolated headers. Unexpected
external requests, JavaScript exceptions and absent reader/note state fail the
job. The separate shell tests cover verified asset caching, interrupted installs
and deployment changes without taking over an existing page's unsaved work.

Python standard-library suites cover developer preflight, checksum-verified SDK
setup, package/version validation, Debian packaging, signing configuration,
provisioning validation and release publication invariants:

```bash
python3 -m unittest discover -s scripts/tests -p 'test_*.py'
python3 -m unittest discover -s scripts/release/tests -p 'test_*.py'
```

Unsigned package builds require no signing credentials. Optional signed jobs
run only on trusted main and only with complete per-platform configuration.
Missing configuration skips only that platform's signed job and is reported by
name. A signing job that runs and fails is a real failure, not a successful
unsigned fallback. `publish-release.yml` automatically promotes a new version
after a successful trusted `Flutter CI` run on main. Its manual trigger accepts
an existing successful main `source_run_id` for recovery; neither path rebuilds
the application. The source commit's `pubspec.yaml` is authoritative, and an
already published version is left unchanged.

The promotion/publication suites require main ancestry, matching source SHA,
version and timestamp, all unsigned target artifacts and any successful signed
targets, exact manifest/checksum coverage, increasing semantic/native versions,
and download/upload digest verification. They exercise recovery of an interrupted
draft at the original commit/build, reject moved tags or mismatched uploads, and
ensure an already published version is never overwritten. These API-contract
tests do not create a real GitHub release or imply that signing credentials were
present. CI retains package artifacts for 90 days; expired or incomplete source
artifacts cannot be promoted.

Linux installs its Debian output and launches the installed application. Windows
silently installs its EXE into a temporary directory and launches that installed
binary. macOS inspects its ZIP, mounts the produced DMG read-only, copies the app
to a temporary installation directory, unmounts the DMG, checks its custom URL
scheme and launches the copied app. Linux and Windows also check installed
launcher/protocol registration. These are loader/startup checks, not a substitute
for interactive feature/device testing.

The source-backed [October parity audit](PARITY_AUDIT_2026-10.md) records current
reference behavior and outstanding product gaps. New daily-reference and bookmark
preservation suites target previously untested failures, including a full
schema-3-to-4 SQLite migration and current website provenance round trips.

## Recorded parity and distribution repair validation

The repair increment passed 298 Flutter unit/widget tests and 55 Python checks
(42 release/packaging checks and 13 development-environment checks), with clean
Dart formatting and analysis. The real compiled Web application passed its
reader/private-note persistence journey under both ordinary and isolated hosting
locally and in CI. Local Linux release compilation, archive/Debian packaging,
checksums and Debian installation also passed. This worker's display access
prevented local native UI execution; the Linux reader and Study journeys passed
on the native CI runner.

That increment's native build, installed-package startup and downloadable-artifact
status is recorded in [pull request #3 and its checks](https://github.com/getbible/app/pull/3).
Earlier green builds do not replace a complete passing matrix on the latest
reviewed commit, including the Android build-mode regeneration repair above.
No distribution credentials were supplied for this validation, and no signed
release or store submission is claimed.

## Private portability and installed resources (steps 12–15)

The private-data suite covers complete snapshots and legacy inputs, deterministic
collisions, repeated imports after local edits, notebook/block/reference and
recoverable-journal preservation, typed preferences and copy provenance, malformed
or unsupported input, actual SQLite restart and rollback after a late write
failure. File adapters and widgets check byte limits, invalid UTF-8, cancellation,
preview before import, export failures and retained Save/Copy alternatives.

The offline suites exercise the real SQLite store and source-specific installers:
staged/active isolation, exact-byte integrity, publication races, cancellation,
interrupted process recovery, live-window leases, logical quota and injected
physical-write failures. A failed replacement must leave the previous generation
usable. Removal and cache eviction must preserve private work.

Bible and Study tests index complete published-shape fixtures through actual
worker code. They close/reopen the database, disable public HTTP and read installed
chapters, introductions, extended book IDs, references, local search, dictionary
definitions, commentary ranges and public-topic associations. Unsupported offline
search filters fail explicitly. Native integration and compiled-browser journeys
complement these tests; mocked HTTP verifies app behavior, not live-source CORS
or store approval.

Targeted suites:

```bash
flutter test test/private_portability_test.dart test/offline_resource_store_test.dart
flutter test test/installed_bible_test.dart test/installed_study_test.dart
flutter test integration_test/offline_portability_test.dart -d linux
```

For device acceptance, export and reimport on each target through its actual file
picker, test share cancellation and Save/Copy fallback, install/update/remove a
large resource, restart without public network access, and verify private data
after a storage-limit failure. Browser tests must include the configured non-root
base path and both ordinary and isolated hosting. Physical device accessibility,
suspension/eviction and signing/store acceptance were deferred to steps 16–17
at that increment; their current gates are recorded below.

### Recorded local validation for this increment

The steps 12–15 implementation passes all 369 Flutter unit/widget/composed
checks, clean Dart formatting/analysis, and 55 Python checks (42 distribution
checks and 13 developer-environment checks). Release compilation succeeds for
Linux and Web with the pinned SDK. The complete offline/private portability
journey and delayed import/download navigation regressions execute through the
production composition, real workers and SQLite persistence.

A browser CI failure also exposed catalogue filter state loss when download
progress and installed cards changed the resource list. A regression reproduces
the failure before the fix and verifies that filter text, selection and keyboard
focus survive activation, then successfully selects a different resource.

The local native integration runner compiles successfully but cannot establish
its debug connection in this managed display environment. Supported-host CI
remains the required evidence for native UI execution and platform packages.
Current branch checks and artifacts are attached to
[pull request #4](https://github.com/getbible/app/pull/4). Only a complete green
run on its latest commit establishes the batch's platform acceptance.

The actual compiled Chromium application also passes under both ordinary static
hosting and COOP/COEP isolation at `/flutter/`: note persistence, cached-only
offline reopening, complete private JSON download and file-picker restore,
complete Bible and dictionary installation through the shipped worker, then a
fresh page reading an unvisited chapter and searching installed Scripture with
zero public HTTP requests. Both runs report no browser exceptions or missing
assets. These checks include real browser storage and file workflows.

The increment's package version is `1.0.0-alpha.2+3`. At that increment, package
creation did not publish a GitHub release; publication required an explicit
action. The current automatic main promotion contract is described above.
Store submission remains a separate action.

## Integrated release candidate: steps 16–17

Candidate version: `1.0.0-alpha.3+4`. Reference source:
`getbible/app.getbible.life@098eeaa06c75efde4a3c75a9984d66ac987add30`.
The historical evidence above belongs to its stated earlier increments and must
not be treated as a test result for this candidate. Current source and CI are in
[pull request #5](https://github.com/getbible/app/pull/5).

### Automated acceptance contract

`integration_test/platform_acceptance_test.dart` combines reader/clipboard,
Study, private portability, installed-resource reopening, released-schema
migration and a 20,000-verse background-worker journey. It uses generated,
test-only fixtures so mobile sandboxes do not depend on the repository's disk
paths. Production application assets do not contain those fixture documents.
`test/platform_compact_acceptance_test.dart` also runs the shared Study and
offline-portability journeys at a 390 × 844 logical-pixel phone viewport.
`test/study_ios_layout_test.dart` exercises the shorter iOS layout, including
scrolling lazily rendered dictionary entries into view. Compact Study tests
retain the panel's captured context through its closing animation and cover
notifications while that route is being removed.
`test/study_tablet_layout_test.dart` holds a pending keyboard inset through the
first dictionary lookup at 1280 × 900 logical pixels. The shared journey verifies
loaded source metadata, scrolls its lazy list, and checks the visible,
hit-testable source-language label before opening the definition; native IME
transitions must not be mistaken for missing resource data.

```bash
python scripts/testing/embed_fixtures.py --check
flutter drive --driver=test_driver/platform_acceptance.dart \
  --target=integration_test/platform_acceptance_test.dart -d <device-id>
```

The native workflow requires Linux, Windows and macOS runtime execution,
Android phone and tablet emulator profiles with 2 GiB RAM, and both iPhone and
iPad simulators. Reports retain selected device identity, driver output, mobile
screenshots and measured worker elapsed time, UI heartbeat and process memory.
The corpus is synthetic, and its metrics are evidence rather than an arbitrary
speed threshold. Simulator results do not establish physical-device performance.
Android clipboard acceptance requires the application's real resumed/input-focus
state, waits for the platform write acknowledgment, and reads the actual OS
clipboard. The dedicated emulator is kept awake; failure artifacts include
window/activity/power state, all-buffer logcat and a native screenshot. Synthetic
widget focus alone does not establish Android clipboard permission.

The production Web build uses bundled rendering resources, generated static
shell inventory and Chromium, Firefox and WebKit runtime journeys under plain
and COOP/COEP-isolated hosting. The journey exercises real browser SQLite,
private backup download/file-picker restore, installed Bible and dictionary
workers, unvisited offline chapter/search, and a new page with **all networking
disabled**, including the static host. WebKit automation is not a claim that
physical Safari/iOS acceptance has been performed. The separate bounded live
CORS probe records actual service responses and distinguishes upstream
availability from deterministic fixture-backed application regressions.

GitHub CI also installs the actual DEB/EXE/DMG outputs where supported, checks
installed launchers/custom-protocol registration and launches the installed
application. iOS unsigned device bundles are compile artifacts; use simulator
APPs or a provisioned signed build for execution. Signed targets retain their
independent configuration gates. Release publication automatically accepts a new
version only from the complete verified inventory of a successful trusted main
run, including the required runtime jobs, and does not rebuild it. A manual
retry selects the original successful run rather than creating new packages.

Focused regressions cover transactional bookmark reconciliation and origin
removal, exact source annotations/citations, confirmed dictionary discovery,
Search debounce, friendly/native links, draft-preserving navigation, startup
storage denial and non-destructive Retry. Localization contract checks pin the
upstream message catalogue and validate native placeholders/call sites; they
cannot certify language quality.

### Human acceptance record required before stable release

For each supported desktop, phone and tablet, record the candidate version,
package checksum, OS/device, tester, date and result. Exercise the complete
reader → word → dictionary citation → Query → Search result → commentary →
topic → personal marking → notebook → backup → offline restart sequence using
rich and plain Bibles, matching and nonmatching resource languages, and missing
coverage. Check native selection/Copy, pointer anchoring, inline drafts across
rotation/resizing/suspension, large text, RTL, high contrast, reduced motion,
keyboard/IME, actual VoiceOver/TalkBack and file/share destinations.

Retain a backup before an actual old-to-new package upgrade and compare private
IDs, ranges/quotes, origins, notes, notebook blocks/journals and preferences after
restart. Automated schema fixtures complement this installed-package upgrade;
they do not replace it. Human linguistic review, physical-device gestures,
actual Safari, verified HTTPS domain associations, signing credentials and store
approval are external acceptance evidence. An alpha download may be published
with these gates explicitly open; it must not be described as a stable,
store-approved or fully device-certified release.


## Identity and reader alignment: alpha.5

Candidate `1.0.0-alpha.5+6` is tracked in
[pull request #7](https://github.com/getbible/app/pull/7). Its acceptance contract
is [Reader alignment](READER_ALIGNMENT.md); earlier increment results above do
not substitute for checks on this PR's final head.

Local validation used the pinned Flutter 3.44.6 / Dart 3.12.2 SDK:

| Check | Evidence |
|---|---|
| Complete Flutter unit/widget suite | 509 tests passed, including automatic offline acquisition and generation changes |
| Analyzer and formatting | No issues; no formatting changes |
| Developer/release tooling | 41 developer tests and 64 release-tool tests passed; nine offline-shell and six browser-harness checks passed |
| Branding, assets and localization | Identity gate, approved-asset checksums, 444-template inventory, 69 locale packs and reference synchronization checked |
| Release compilation | Linux and web compiled successfully during the increment |
| Graphical inspection | Actual wide Study and compact bookmark captures with loaded fonts; selector clipping and excess menu height corrected |

The composed reader cases cover direct/additive topics, full Query verse cards,
return to the captured verse, generic reopening without a stale return target,
inline verification and exact documentation URLs. Selection cases invoke real
semantics Copy and preserve UTF-16 source ranges, including reversed emoji
selection. Dictionary navigation is tested while requests are still in flight;
per-module Retry restores all definitions after partial failure. A 320px wide
keyboard layout and a 300px available-height/200% text menu remain operable.

Compiled-browser CI exposed duplicate accessibility buttons on the verification
badge that the original widget checks did not detect. The badge now merges its
expanded state with the native button semantics; dedicated tests count exported
roles and exercise screen-reader activation, Tab focus and Space. The browser
journey checks a single button, expansion/dismissal, verified and saved content,
and the absence of a modal while keeping the persistence/offline checks intact.
The corrected release passed all four Chromium/WebKit journeys across standard
and isolated hosting, with no unexpected browser errors or missing assets.
Local Firefox could not launch even a blank page because this host denied its
sandbox namespace setup; Firefox acceptance remains a hosted-CI gate.

A pre-rename generated Flutter web entry point initially retained the old Dart
package import. Clearing that generated cache resolved the build; existing
checkouts should run `flutter clean` and `flutter pub get` as documented in
[Local development](LOCAL_DEVELOPMENT.md#clean-build-after-the-alpha-identity-reset).
The local native Linux driver could not start its session bus because this
execution environment denied socket creation; it is not reported as a local
runtime pass. Hosted CI supplies native runtime and installer-launch evidence.

The PR workflow builds all supported targets and runs the shared acceptance
journeys on its supported desktop and mobile hosts. Consult that exact head's
checks and retained artifacts for completion; unsigned builds are not store
certification. No app-identity upgrade path is provided for these alpha builds.

### Automatic offline acceptance

Only opened Bible translations are acquired automatically, using each complete
translation file. Dictionary and commentary catalogues supply the default
downloads; persistent per-module exclusions prevent unwanted copies. The full
public bookmarks dataset remains explicit opt-in, while topic choices always
come from Bookmarks v1 metadata or its saved copy.

The scheduler tests cover sequential bounded work, foreground Bible priority,
queue saturation, duplicate suppression, cancellation, persistent exclusions,
30-day freshness, retry backoff, unchanged hashes and atomic replacements. A
failed update retains the last verified generation. Schema-v5 fixtures verify
the schema-v6 metadata migration without changing private work. Source-specific
revision tests distinguish Bible SHA-1 from Study manifest fingerprints.

Clear/remove regressions delay public HTTP responses, repository writes,
dictionary browsing and active downloads across deletion. Old work must not
restore removed data or silently restart acquisition. Fresh use may reacquire
eligible defaults; it never overrides exclusions or installs absent bookmarks.
Private notes, notebooks, preferences and saved quotations remain intact.
Generation-transition tests keep visible Study content readable during updates
and reload one coherent generation on subsequent navigation, with bounded retry
and exact dictionary-ID validation. Search adopts the installed Bible by default
while preserving a user's explicit search mode and filter choices.

The compiled browser journey exercises automatic whole-Bible, dictionary and
commentary installation through real workers, persistent exclusions, public
clearing and restoration, no unsolicited full-bookmark requests, private backup
round trips, and a fresh offline page reading an unvisited chapter and searching
installed Scripture with zero public HTTP. It also cold-starts the cached shell
with all networking disabled. The workflow repeats these checks in Chromium,
Firefox and WebKit under both standard and isolated hosting.
Local Chromium and WebKit runs passed all four hosting journeys, with 16 checks
per journey and no browser errors or missing assets. Firefox remains a hosted
gate because of the local host restriction described above.

Seven newly introduced long prose/error templates intentionally retain English
fallbacks in the affected locale packs, with pending translation recorded in
provenance. Automated inventory and placeholder checks do not establish human
linguistic review; see [Localization](LOCALIZATION.md).
