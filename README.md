# getBible.live (Flutter implementation)

Cross-platform Flutter implementation of [getBible.Life](https://app.getbible.life), maintained at [`getbible/app`](https://github.com/getbible/app). It targets Android, iOS, web, Windows, macOS, and Linux from one native Flutter codebase. Scripture comes from GetBible Bible v3, reference previews use Query v3, and private reader data remains on the device. The reader does not use a WebView.

The React application at [`getbible/app.getbible.life`](https://github.com/getbible/app.getbible.life) and its live deployment are the product source of truth. Flutter must reproduce the same reader behavior and data contracts natively. See the [web-to-Flutter parity contract](docs/WEB_FLUTTER_PARITY.md).

> Development status: the reader provides lossless Bible v3 Scripture, online Search v3, reusable Query v3 previews, an adaptive Study workspace with dictionaries, commentaries and public topics, and separate local study/sermon notebooks. Canonical inline verse notes and personal markings retain their established identities. Complete offline installations, notebook backup portability, full localization and platform/store release gates remain later work. See [feature parity](docs/FEATURE_PARITY.md).

## Supported targets

| Target | Development/test command | Distribution output |
|---|---|---|
| Android | `flutter run -d android` | APK or Play Store AAB |
| iOS/iPadOS | `flutter run -d ios` | Xcode archive/App Store package |
| Web | `flutter run -d chrome` | Static files in `build/web` |
| Windows | `flutter run -d windows` | Windows runner bundle |
| macOS | `flutter run -d macos` | macOS application bundle |
| Linux | `flutter run -d linux` | Linux runner bundle |

## Requirements

- Flutter stable 3.44.6 or newer
- Dart 3.12.2 or newer
- Android Studio/SDK for Android builds
- macOS with Xcode for iOS builds

## Start developing

```bash
flutter doctor -v
flutter pub get
flutter run
```

The application ID and iOS bundle ID are `life.getbible.mobile`. No API key is required for the public GetBible API.

## Scripture and reference previews

The reader discovers translations, books and chapters through
`https://api.getbible.net/v3`, including published source IDs beyond the usual
66-book canon. It retains original verse text, lexical metadata, source styles,
ordered chapter headings and introductions. The **Source text styles** reader
preference changes presentation without modifying Scripture or private saved
text ranges. Personal selected-text markings retain their original UTF-16
code-unit offsets and quote; a quote mismatch after a source revision stays
saved without coloring unrelated text.

Open **Reference preview** from the chapter heading, navigation drawer or verse
context menu. Query v3 at `https://query.getbible.net/v3` resolves the chosen
Bible's citation without installing a translation. The compact sheet or wide
panel shows the reference, translation and native selectable Scripture, with
Copy, exact-verse Open and bounded citation back history. Closing preserves the
reader position; Open loads the contextual chapter only when explicitly chosen.
Finish or close an active inline note editor before using **Open in reader**;
the preview keeps its draft in place while that editor is active.
Missing or incompatible references display an error without substituting a
default passage. Complete installed-Bible offline reference resolution is later
work.

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
topics; the chapter context opens chapter commentary. Study appears beside
Scripture on wide windows and in a keyboard-aware sheet on compact screens.
Closing restores reader focus and preserves its passage and scroll position.

Dictionary lookup retains source lexical IDs, lemmas, morphology and
transliteration, resolves the selected resource's published index, and reads
definitions on demand. Commentary uses published book/chapter coverage and
retains ranged and introduction entries. Resource choices display their actual
source language; unavailable coverage has an explicit state. Dictionary,
commentary, topic and notebook citations reuse the same selected-Bible Query
preview and do not navigate the reader until Open is chosen.

Public topics are separate from private marking groups. Follow and Hide are
local choices. **Copy to my markings** previews an explicit independent private
copy with collision-safe identities and duplicate-safe repeated copying.
Public updates cannot edit that private copy or personal notes.

**Notebooks** provides local titled documents with ordered text blocks and
optional attributed Scripture quotations. Autosave, durable draft journals,
Retry and conflict recovery preserve drafts across ordinary navigation and
restart. Canonical one-note-per-verse editing remains inline and works across
translations. Schema 3 adds notebook storage without converting existing notes.
The current reader backup exports verse notes and markings; notebooks, draft
journals and new Study settings/copy provenance are not yet included. Complete
portability is roadmap step 12. A forced exit before a pending save completes
can still lose its last uncommitted edit.

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

For Android, enable developer mode/USB debugging or start an emulator, then run `flutter devices` followed by `flutter run -d <device-id>`. GitHub Actions also publishes two downloadable artifacts after a successful `main` build:

- `getBible-live-debug-apk` for installation on an Android test device.
- `getBible-live-web`, containing the compiled static web application.

Open the successful workflow run’s **Artifacts** section to download them. Web files must be served by an HTTP server; opening `index.html` directly is not supported. A permanent GitHub Pages preview can be enabled later after the repository is public and Pages is configured to deploy from GitHub Actions.

**pub.dev is not an application testing service.** It is Dart and Flutter’s public package registry. This application is not intended to be published there as a reusable package. Test builds belong in GitHub Actions artifacts, GitHub Pages, TestFlight, Play Console internal testing, or locally attached Flutter devices.

## Quality checks

```bash
dart format --output=none --set-exit-if-changed .
flutter analyze
flutter test
flutter build apk --debug
```

CI runs the same checks, both native Linux reader/Study journeys and release web/Linux builds. It uploads a development debug APK and a compiled web build. Consult [testing](docs/TESTING.md) before merging reader, storage, backup, or cache changes.

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

All platform launchers, favicons, splash artwork, window icons, and in-app identity use the approved GetBible artwork in `assets/branding/`. CI validates a committed checksum manifest so generated Flutter template icons cannot silently return. The source artwork must be replaced only with explicitly approved GetBible assets.

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
- [Source-backed parity audit (July 2026)](docs/PARITY_AUDIT_2026-07.md)
- [Brand assets](docs/BRANDING.md)
- [Testing and QA](docs/TESTING.md)
- [Deployment and distribution](docs/DEPLOYMENT.md)
- [Release checklist](docs/RELEASE_CHECKLIST.md)
- [Privacy policy draft](docs/PRIVACY.md)

## License

The existing repository license is retained in [LICENSE](LICENSE). Scripture translations remain subject to the license and copyright metadata returned by GetBible Bible v3; the application license does not relicense translation content.
