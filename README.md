# getBible

Cross-platform Flutter implementation of [getBible](https://app.getbible.life), maintained at [`getbible/app`](https://github.com/getbible/app). It targets Android, iOS, web, Windows, macOS, and Linux from one native Flutter codebase. Scripture comes from getBible Bible v3, reference previews use Query v3, and private reader data remains on the device. The reader does not use a WebView.

The React application at [`getbible/app.getbible.life`](https://github.com/getbible/app.getbible.life) and its live deployment are the product source of truth. Flutter must reproduce the same reader behavior and data contracts natively. See the [web-to-Flutter parity contract](docs/WEB_FLUTTER_PARITY.md).

> Development status: the alpha reader includes Bible v3, Search and Query, contextual Study, unified personal/global bookmarks, private notebooks, complete backups and explicitly installed public resources. Integrated parity and automated platform acceptance are implemented in this candidate; actual run evidence and remaining device, language-review and store gates are recorded in [testing](docs/TESTING.md) and [feature parity](docs/FEATURE_PARITY.md). Downloadable development packages are not store-approved releases.

## Supported targets

| Target | Development/test command | Distribution output |
|---|---|---|
| Android | `flutter run -d android` | Installable development APK; optional signed APK/AAB |
| iOS/iPadOS | `flutter run -d ios` | Simulator APP ZIP; unsigned device bundle; optional signed IPA |
| Web | `flutter run -d chrome` | Static website ZIP with an offline application shell |
| Windows | `flutter run -d windows` | Setup EXE and portable ZIP |
| macOS | `flutter run -d macos` | Drag-to-Applications DMG and APP ZIP |
| Linux | `flutter run -d linux` | Debian DEB installer and portable TAR.GZ |

Download published versions from [GitHub Releases](https://github.com/getbible/app/releases).
Alpha 5 establishes the corrected **getBible** naming and requires removing
earlier alpha installations and their local test data. This development reset
does not migrate previous installation or database names.
See [installation and testing](docs/INSTALLING.md) for device requirements,
unsigned-package behavior and checksum verification. Flutter creates application
bundles; this repository's packaging scripts turn them into installers. Linux
currently has a DEB and portable bundle, not an AppImage.

## Requirements

- Flutter stable pinned in `.flutter-version` (currently 3.44.6; use the same SDK as CI)
- Dart 3.12.2 or newer
- Android Studio/SDK for Android builds
- macOS with Xcode for iOS/macOS builds
- Native Linux/Windows toolchains for their respective desktop targets

See [local development and error recovery](docs/LOCAL_DEVELOPMENT.md) for a
checksum-verified SDK installer and target-specific preflight checks.

## Start developing

```bash
flutter doctor -v
flutter pub get
flutter run
```

The application ID and iOS bundle ID are `life.getbible.mobile`. No API key is required for the public getBible API.

## Scripture and reference previews

The reader discovers translations, books and chapters through
`https://api.getbible.net/v3`, including published source IDs beyond the usual
66-book canon. It retains original verse text, lexical metadata, source styles,
ordered chapter headings and introductions. The **Source text styles** reader
preference changes presentation without modifying Scripture or private saved
text ranges. Personal selected-text markings retain their original UTF-16
code-unit offsets and quote; a quote mismatch after a source revision stays
saved without coloring unrelated text.

The verification icon toggles a compact explanation beneath the chapter header.
It distinguishes verified Scripture from an offline copy whose current hash
could not be checked, and links to the [Bible API documentation](https://getbible.net/api/bible/).
Translation licensing ends with the book artwork, “The Word for the world!” and
“Powered by getBible APIs.”, linking to [general documentation](https://getbible.net).

Open **Reference preview** from the chapter heading, navigation drawer or verse
context menu. Query v3 at `https://query.getbible.net/v3` resolves the chosen
Bible's citation without installing a translation. The compact sheet or wide
panel shows the reference, translation and native selectable Scripture, with
Copy, exact-verse Open and bounded citation back history. Closing preserves the
reader position; Open loads the contextual chapter only when explicitly chosen.
Finish or close an active inline note editor before using **Open in reader**;
the preview keeps its draft in place while that editor is active.
Missing or incompatible references display an error without substituting a
default passage. Installed Bibles resolve supported references locally using their
published book names and coordinates, without a Query request. Unavailable names
or coordinates produce a clear error; see the offline search contract.

## Search and Study

Online search uses `https://search.getbible.net/v3` for the active Bible and
loads additional pages only when needed. It preserves all/any/phrase and
whole-word/substring modes, case sensitivity, testament or selected-book scope,
diacritics, exclusions, proximity and canonical/relevance order. Reference
queries display the complete resolved selection. Searching does not download
a whole translation or silently switch to local corpus search.

Tap a Scripture word to open its dictionary context, or use native selection
to search the exact selected phrase. Copy, markings and inline note controls
remain available. Verse context actions open commentary or related public
topics; the chapter context opens chapter commentary. **Study Scripture** opens
as a centered dialog on wide windows and a keyboard-aware sheet on compact
screens. Its passage context, selected text, **Search selection** action and
**Dictionaries / Commentaries** tabs stay together. Personal tools use a separate
resource selector for topics, markings, notebooks and verse notes.
Closing restores reader focus and preserves its passage and scroll position.

Dictionary lookup retains source lexical IDs, lemmas, morphology and
transliteration and confirms definitions across available resource indexes.
Installed resources are searched first when present; **Include online dictionaries**
explicitly expands that scope. Suggestions and unavailable resources are distinct
from confirmed definitions. The chooser contains only dictionaries with a
confirmed definition for the current lookup, including related-entry navigation.
Strong's identifiers are actionable and repeated definitions remain visible.
The full dictionary catalogue remains available through the unbound browser.
Commentary uses published book/chapter coverage and
retains ranged and introduction entries. Resource choices display their actual
source language; unavailable coverage has an explicit state. Dictionary,
commentary, topic and notebook citations reuse the same selected-Bible Query
preview and do not navigate the reader until Open is chosen.

Each verse has a direct bookmark icon. Its scrollable menu shows linked topics;
**Add another topic** expands a searchable list and adds a membership without
removing existing ones. Clicking a topic opens its bookmarks, with **All topics**
and **Back to verse** navigation. Topic cards load actual Scripture from the
selected Bible through installed resources or Query, with bounded progressive
loading, caching and per-verse retry. Fetched text never replaces a saved quotation.

Global and personal topics share a list while memberships retain their separate
origins. Follow and Hide are local choices. **Copy to my markings** previews an
independent private copy with collision-safe identities and duplicate-safe
repeated copying. Public updates cannot edit that copy or personal notes.

**Notebooks** provides local titled documents with ordered text blocks and
optional attributed Scripture quotations. Autosave, durable draft journals,
Retry and conflict recovery preserve drafts across ordinary navigation and
restart. Canonical one-note-per-verse editing remains inline and works across
translations. Schema 3 adds notebook storage without converting existing notes.
Use **Backup and restore → Complete private backup** to include notebooks,
draft journals, verse notes, markings, reader preferences, reading position and
Study choices/copy provenance. **Website-compatible backup** remains the v2
reader-data format and explicitly omits notebooks. A forced exit before a pending
save completes can still lose its last uncommitted edit.

## Backup and offline use

Open **Backup and restore** in the navigation drawer. Export prepares a snapshot
before offering Save file and Copy; Scripture and notebook Markdown also offer
system sharing where supported. Import selects a bounded JSON file, validates it
and displays a preview before confirmation. The additive transaction preserves
conflicting private work with deterministic identities. Backups contain private
text in readable JSON; choose their destination deliberately.

Open **Set up offline use** to browse public resource catalogues and explicitly
install a complete Bible, dictionary, commentary or the public-topic collection.
The manager shows attribution, known size, progress, cancellation, retry and
installed revision. Each download is verified and indexed before activation; an
unsuccessful update leaves the previous installation usable. Removing public
resources preserves private notes, notebooks and independent topic copies.
Interrupted downloads restart on retry; byte-range resume is not assumed.

Installed Bibles serve the reader and supported reference previews locally.
Search remains **Online** by default; choose **Installed** for local full-text
search, whose supported filters are stated in the search panel. Installed Study
resources use the same native panels and citations. Public caches and downloaded
corpora are excluded from private backups; reinstall public resources on a new
device. Release Web packages also cache their application files after the first
successful online visit. Once installation finishes, the browser can reopen the
app with the network disabled. Browser storage eviction or clearing site data
removes this capability and may remove private data; keep private backups.

See [API/cache behavior](docs/API_AND_CACHE.md),
[architecture](docs/ARCHITECTURE.md), [dictionaries](docs/dictionaries.md),
[commentaries](docs/commentaries.md), [public topics](docs/public-topics.md)
and [notebooks](docs/notebooks.md) for ownership, persistence and limitations.

## Test the application

The fastest interactive test is the web target:

```bash
flutter pub get
flutter run -d chrome
```

For Android, enable developer mode/USB debugging or start an emulator, then run
`flutter devices` followed by `flutter run -d <device-id>`. Every successful PR
and `main` workflow builds versioned Linux, Windows, macOS, Android, iOS device,
iOS simulator and Web packages. Download them from that run's **Artifacts**
section. An unsigned iOS device bundle validates compilation; use the simulator
bundle or a signed/TestFlight build for execution. Web files need an HTTP server.

`pubspec.yaml` is the single alpha/beta/rc/stable version source. Successful `main`
CI automatically promotes its verified packages to GitHub Releases without
rebuilding. An unchanged published version is skipped. **Publish tested packages**
also accepts a successful `main` run ID for retrying publication of retained
artifacts. Signing is optional and independently configured per target. See [distribution](docs/DEPLOYMENT.md)
and [signing credentials](docs/SIGNING.md). Store submission comes later.

**pub.dev is not an application testing service.** It is Dart and Flutter’s public package registry. This application is not intended to be published there as a reusable package. Test builds belong in GitHub Actions artifacts, GitHub Pages, TestFlight, Play Console internal testing, or locally attached Flutter devices.

## Quality checks

```bash
dart format --output=none --set-exit-if-changed .
flutter analyze
flutter test
flutter build apk --debug
```

CI runs the same checks, native Linux reader/Study/offline-portability journeys, actual compiled
browser startup/persistence checks and native-host builds for every target.
It packages versioned artifacts and checksums. Consult [testing](docs/TESTING.md)
before merging reader, storage, backup, cache or distribution changes.

## Release builds

Android:

```bash
flutter build apk --release
flutter build appbundle --release
```

iOS, on macOS:

```bash
flutter build ios --release --no-codesign
```

Signing keys and provisioning profiles must never be committed. Complete instructions are in [deployment and distribution](docs/DEPLOYMENT.md).

## Architecture

The code is divided into domain models/contracts, data adapters, application state, services, and presentation. SQLite is accessed through Drift's executor; network responses are parsed into strongly typed immutable models. Opened chapters are cached, their SHA endpoints are checked, and usable cached Scripture remains available when verification cannot reach the network.

```text
lib/
  application/       reader lifecycle and independently owned Study controllers
  core/              errors, JSON validation, starter groups
  data/api/          shared transport and service-specific typed adapters
  data/database/     local SQLite schema and platform executors
  data/repositories/ cache and persistence implementations
  domain/models/     versioned data contracts
  domain/repositories/abstract persistence contracts
  presentation/      native reader, Search and adaptive Study UI
  services/          Scripture mapping, backup and Markdown operations
```

See [architecture](docs/ARCHITECTURE.md) and [data contracts](docs/DATA_AND_BACKUPS.md).

## Privacy

Verse notes, notebooks, draft journals, markings, preferences, cached Scripture
and reading position stay on the device. The app has no accounts, advertising,
analytics or tracking. Online Search sends the entered or explicitly selected
query and chosen filters. Query previews send only the selected Bible and
requested Scripture citation; Study requests retrieve public resources and
coordinates. Private notebook/note bodies and markings are not uploaded. See
the [privacy policy draft](docs/PRIVACY.md).

## Branding

The display name is exactly **getBible**; technical package and executable names
use `getbible` where lowercase is required. `ProductIdentity` centrally owns the
name and public destinations. Every generated Scripture link points to
`https://app.getbible.life`; documentation and verification use the distinct
destinations described above. API service roots remain in `ApiConfiguration`.

All launchers, favicons, splash artwork and window icons use the approved
getBible artwork in `assets/branding/`. In-app identity combines the book artwork
with native getBible text. CI checks the artwork manifest and naming contract.
See the [reader alignment contract](docs/READER_ALIGNMENT.md) and
[branding guide](docs/BRANDING.md).

## Documentation index

- [Agent operating guide](AGENTS.md)
- [Architecture](docs/ARCHITECTURE.md)
- [API and cache workflow](docs/API_AND_CACHE.md)
- [Data and backup compatibility](docs/DATA_AND_BACKUPS.md)
- [On-demand dictionaries](docs/dictionaries.md)
- [Chapter and verse commentaries](docs/commentaries.md)
- [Public topics and private copies](docs/public-topics.md)
- [Personal study and sermon notebooks](docs/notebooks.md)
- [Feature-parity ledger](docs/FEATURE_PARITY.md)
- [Web-to-Flutter parity contract](docs/WEB_FLUTTER_PARITY.md)
- [Interface localization and language review](docs/LOCALIZATION.md)
- [Current reference-app parity audit (October 2026)](docs/PARITY_AUDIT_2026-10.md)
- [Local development and launch troubleshooting](docs/LOCAL_DEVELOPMENT.md)
- [Distribution signing requirements](docs/SIGNING.md)
- [Source-backed parity audit (July 2026)](docs/PARITY_AUDIT_2026-07.md)
- [Brand assets](docs/BRANDING.md)
- [Testing and QA](docs/TESTING.md)
- [Deployment and distribution](docs/DEPLOYMENT.md)
- [Download and install test packages](docs/INSTALLING.md)
- [Release checklist](docs/RELEASE_CHECKLIST.md)
- [Privacy policy draft](docs/PRIVACY.md)

## License

The existing repository license is retained in [LICENSE](LICENSE). Scripture translations remain subject to the license and copyright metadata returned by getBible Bible v3; the application license does not relicense translation content.
