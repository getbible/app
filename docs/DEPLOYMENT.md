# Builds, versions and distribution packages

`Flutter CI` installs the SDK pinned in `.flutter-version`, restores the committed
lockfile, and builds every target on its native host for pull requests and merges
to `main`. Every successful main build with a new recorded version is promoted
to [GitHub Releases](https://github.com/getbible/app/releases), with direct
installer links and installation instructions. Promotion reuses the exact
packages already produced by CI. PR packages remain available in their workflow
run's **Artifacts** section for 90 days (subject to repository retention limits).
No store upload is performed by these workflows.

## One version source

`pubspec.yaml` is the only application version source. Use the following sequence,
always increasing the integer after `+` across all channels:

| Channel | Example | GitHub release |
|---|---|---|
| Alpha | `1.0.0-alpha.1+2` | Prerelease |
| Beta | `1.0.0-beta.1+3` | Prerelease |
| Release candidate | `1.0.0-rc.1+4` | Prerelease |
| Stable | `1.0.0+5` | Normal release |

These are examples of successive versions, not extra configuration values.
The current version begins the alpha channel; completion of package automation
is not a claim that feature parity or store acceptance is complete. Increment
both the semantic version and build number before publishing the next release.
Repeated CI runs do not change the recorded version. Windows version components
and build numbers must fit 16-bit fields, so the tooling rejects numbers above
65535 instead of silently truncating them.

Apple bundle marketing versions and Windows native file versions require numeric
components. They use `1.0.0` plus build number `2` for the first example. Package
filenames encode that release as `1.0.0-alpha.1-build.2`; manifests retain
`1.0.0-alpha.1+2`. Android versionName retains its prerelease channel in both
unsigned and signed builds. Debian prereleases use
`1.0.0~alpha.1-2` so Debian's upgrade ordering agrees with the channel sequence.

## Automatic publication and retry without rebuilding

1. Increase `version:` in `pubspec.yaml`, including its `+BUILD` integer, and
   merge the reviewed change to `main`.
2. **Flutter CI** builds and tests every target, retaining versioned packages,
   manifests and checksums. Every required runtime/build job and any configured
   signing job must succeed; missing credentials skip only that signed target.
3. **Publish tested packages** starts after the successful main run, retrieves
   its existing artifacts and publishes `v<semantic-version>` on GitHub Releases.
   Testers can download installers from the release notes or **Assets**. Public
   releases do not require an Actions session to download.

If upload fails, fix the stated issue and open **Actions → Publish tested
packages → Run workflow**, select **main**, and enter the original successful
Flutter CI run's numeric ID as `source_run_id`. It is the number after
`/actions/runs/` in that run's URL. This also promotes a still-retained successful
main build created before the automatic publisher was introduced. No Flutter SDK
is installed and no application is rebuilt by promotion. A source run whose
artifacts have expired cannot be recovered by this workflow; start a new Flutter
CI run on the appropriate main commit/version instead.

PR runs, fork runs, failed runs and unrelated workflows cannot be promoted. The
publisher verifies repository and workflow identities, successful completion,
main ancestry, the source commit's `pubspec.yaml` and timestamp, the exact package
artifact inventory, archive SHA-256 values, and every package manifest/checksum.
Signed targets that succeeded in that source run must have matching signed
artifacts. It never executes downloaded content. The GitHub token is not sent to
artifact storage redirects. Download/extraction limits reject oversized archives,
path traversal, symlinks, duplicate filenames and unexpected files.

Only the publication job receives `contents: write`, alongside `actions: read`;
the automatic `GITHUB_TOKEN` supplies those permissions. No additional release
token or secret is required. The workflow checks out trusted main publisher code,
not PR code or a source checkout extracted from an artifact. Signing secrets
remain confined to the existing target-specific signing jobs.

An already published version is skipped, never overwritten. A lower semantic
version or non-increasing native build number is rejected. An interrupted
unpublished draft can be retried only for its original commit and build number.
Already uploaded files are retained only when their size and SHA-256 match the
verified local package; differing uploads are rejected instead of replaced.
Publication requires all seven unsigned targets and every configured signed
target, complete manifest/checksum coverage, and matching GitHub upload digests.
The tag's actual commit is checked before uploads and again before publication.
Large assets are streamed during upload. Alpha, beta and
rc releases remain prereleases; only stable releases become the latest stable
release. The workflow never edits the version, makes a version commit, or moves
an existing release tag. Release assets persist independently of Actions artifact
retention. Packages are attached to **Releases**, not GitHub Packages: these are
end-user applications, not container images or dependency registry packages.

## Package matrix

| Target | Host / architecture | Always-built test output | Optional signed output |
|---|---|---|---|
| Linux | Ubuntu 22.04 / x64 | `.deb`, portable `.tar.gz` | No signing key required for these files; SHA-256 checksums supplied |
| Windows | Windows 2022 / x64 | Per-user setup `.exe`, portable ZIP with Microsoft CRT | Authenticode-signed executable/installer and portable ZIP |
| macOS | macOS 15 / actual app architectures | `.app.zip`, drag-to-Applications `.dmg` | Developer ID signed, notarized and stapled APP/DMG |
| iOS / iPadOS device | macOS / arm64 | Unsigned device `.app.zip` for build validation | App Store distribution `.ipa` |
| iOS / iPadOS simulator | macOS / simulator architecture | Debug simulator `.app.zip` | Signing not required |
| Android phone / tablet | Ubuntu / bundled Android architectures | Installable debug APK, unsigned release APK and AAB | Signed release APK and AAB |
| Chrome / Web | Ubuntu / browser | Static ZIP with local CanvasKit, SQLite WASM and database and offline-index workers | No package signing key required; host over HTTPS |

Phone and tablet share the Android application. iPhone and iPad share the iOS
application; they are not separate packages. Each package has a JSON manifest
recording its source commit, semantic/native version, channel, architecture,
signing state, intended use, size and SHA-256. Checksums are generated after all
signing/notarization changes.

Unsigned iOS device output is **not installable on a physical device**. The
simulator output runs through Xcode Simulator. An App Store IPA requires a later
TestFlight/App Store Connect upload; it is not an arbitrary sideload package.
Unsigned Windows/macOS downloads may prompt platform trust checks. Android debug
signatures are development identities and are not a stable distribution/upgrade
identity; use a persistent configured release key when upgrade continuity matters.

Flutter itself produces the native runner and its runtime/data bundle. This
repository's packaging layer builds Linux DEBs, Windows setup EXEs and macOS
DMGs from those bundles. Linux output is a DEB plus a portable archive, not an
AppImage. Installer and portable files are both retained; the latter are useful
for unpacked development testing. Use [Installing test releases](INSTALLING.md)
for download, checksum, installation, update and removal instructions.

## Signing configuration

See [Signing](SIGNING.md) and [Android/Windows credentials](SIGNING_ANDROID_WINDOWS.md)
for every GitHub secret and variable, how to obtain it and each output's scope.
Each platform has an independent namespace. Missing configuration skips only
that signed job and lists the missing **names**, without printing values.
All unsigned build checks continue. Invalid supplied keys/certificates fail the
configured signed job; they never silently produce an unsigned file labelled signed.
Signing credentials are available only to trusted `main` jobs, never PR code.

macOS notarization is part of building its signed direct-download package. Store
listing, store upload, review and rollout automation are a later separate workflow.

## Reproduce locally

Follow [Local development](LOCAL_DEVELOPMENT.md) to install the pinned SDK and
native prerequisites. Then create the shared metadata once:

```bash
python3 scripts/release/package.py metadata --output build/release-metadata.json
flutter pub get --enforce-lockfile
```

Use `version_name` and `build_number` from that JSON for Flutter's `--build-name`
and `--build-number` on desktop, Web and Apple targets. Android uses
`release_version` for `--build-name`, preserving the channel. Build on the
matching native host. After the explicit locked dependency restore, production
builds perform Flutter's normal native tooling regeneration. Do not add
`--no-pub` to those build commands: switching from native integration/debug to
release requires regenerated plugin registration in the pinned Flutter SDK.
Tests and analysis can reuse dependency resolution with `--no-pub`.
The workflow contains the exact platform build commands. Package an already-built
Linux bundle with:

```bash
python3 scripts/release/package.py package --target linux \
  --metadata build/release-metadata.json --output dist --arch x64
```

The other targets use the same command with `windows`, `macos`, `ios-device`,
`ios-simulator`, `android` or `web`. Web adds `--base-href /flutter/`. Missing
bundles, mismatched native versions/architectures, unsafe symlinks or existing
output filenames fail clearly. Use a new output directory for a deliberate rebuild.

## Validation and limits

CI includes formatting, analysis, unit/widget/migration tests, native Linux
reader, Study and offline-portability journeys, and a browser launch of the actual compiled Web application.
Browser fixtures make API responses deterministic while exercising the real
SQLite WASM, both workers and persistence after public requests become unavailable.
The static package includes `offline_bible_worker.dart.js`; CI rebuilds it from
`tool/offline_bible_worker.dart` before compilation and packaging. Missing worker
assets fail packaging rather than surfacing as a broken install after deployment.
The generated app-shell manifest covers the complete compiled Web application;
packaging verifies its inventory revision, file sizes and SHA-256 values before
adding package metadata/license files. Missing offline shell/worker files or
compiled assets changed after shell generation fail packaging.
Run `python3 scripts/build_web_shell.py --build-dir build/web` after a local
Flutter Web build to produce this manifest and the corresponding worker. The
loader is disabled in source/development and enabled only by successful release
shell generation. CI runs the generator before browser acceptance and packaging.
The committed `web/flutter_bootstrap.js` uses Flutter's documented loader and
build-configuration substitutions, then initializes without `serviceWorkerSettings`.
This prevents Flutter's default offline-first worker from competing with the
verified shell for the same scope; the generator rejects that competing setup.
The host must serve `index.html` for otherwise-unmatched HTML navigations under
the configured base path, preserving true 404 responses for missing assets.
This makes first-visit friendly passage links work before service-worker
activation. Database and parsing-worker URLs resolve against the document base,
not a nested passage path. Keep HTTPS (or localhost for development); do not
serve the Web bundle using `file://`.
Linux installs its actual Debian package and launches the installed binary.
Windows installs its generated EXE into a temporary directory and launches that
installed application; macOS extracts its generated ZIP and launches its app.
Desktop process startup checks complement feature integration tests; they do
not establish complete assistive-technology or device behavior.

Physical-device gestures, screen readers, store acceptance and the remaining
device-validation work remain listed in the release checklist. Successful
packaging provides downloadable builds without declaring those product gates complete.

The release tooling tests exercise successful unsigned promotion, independent
signing requirements, tampered/missing/foreign/expired archives, source version
and commit disagreement, unsafe extraction, run changes during transfer,
interrupted draft recovery and immutable published assets. CI's package install
and runtime jobs validate actual host behavior separately from these API-contract
tests. The current evidence is attached to the reviewed PR and its final CI run.

Primary workflow contracts: [GitHub workflow_run events](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows#workflow_run),
[Actions artifact API](https://docs.github.com/en/rest/actions/artifacts) and
[release assets API](https://docs.github.com/en/rest/releases/assets).
