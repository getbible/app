# Builds, versions and distribution packages

`Flutter CI` installs the SDK pinned in `.flutter-version`, restores the committed
lockfile, and builds every target on its native host for pull requests and merges
to `main`. Packages are available in the workflow run's **Artifacts** section.
No store upload is performed by this workflow.

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
components. They use `1.0.0` plus build number `2` for the first example. Every
package filename and manifest retains the complete `1.0.0-alpha.1+2` identity;
Android versionName can retain its prerelease channel. Debian prereleases use
`1.0.0~alpha.1-2` so Debian's upgrade ordering agrees with the channel sequence.

## Build versus publish

Every pull request and merge produces versioned test packages. To publish a
reviewed build as a GitHub release:

1. Change `version:` in `pubspec.yaml`, review and merge the change.
2. Open **Actions → Flutter CI → Run workflow**, select **main**, and enable
   **Publish the version in pubspec.yaml to GitHub Releases**.
3. Leave the web path at `/flutter/`, or supply the leading/trailing-slash path
   that matches your hosting destination.
4. The workflow rebuilds the recorded commit, requires all unsigned target jobs
   and every configured signed target to pass, verifies package manifests and
   checksums, then publishes tag `v<semantic-version>`.

An already published version is skipped, never overwritten. A lower semantic
version or non-increasing native build number is rejected. An interrupted
unpublished draft can be retried only for its original commit. Alpha, beta and
rc releases remain prereleases; only stable releases become the latest stable
release. The workflow never edits the version, makes a version commit, or moves
an existing release tag.

## Package matrix

| Target | Host / architecture | Always-built test output | Optional signed output |
|---|---|---|---|
| Linux | Ubuntu 22.04 / x64 | `.deb`, portable `.tar.gz` | No signing key required for these files; SHA-256 checksums supplied |
| Windows | Windows 2022 / x64 | Per-user setup `.exe`, portable ZIP with Microsoft CRT | Authenticode-signed executable/installer and portable ZIP |
| macOS | macOS 15 / actual app architectures | `.app.zip`, drag-to-Applications `.dmg` | Developer ID signed, notarized and stapled APP/DMG |
| iOS / iPadOS device | macOS / arm64 | Unsigned device `.app.zip` for build validation | App Store distribution `.ipa` |
| iOS / iPadOS simulator | macOS / simulator architecture | Debug simulator `.app.zip` | Signing not required |
| Android phone / tablet | Ubuntu / bundled Android architectures | Installable debug APK, unsigned release APK and AAB | Signed release APK and AAB |
| Chrome / Web | Ubuntu / browser | Static ZIP with local CanvasKit, SQLite WASM and database worker | No package signing key required; host over HTTPS |

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
and `--build-number`, and the matching native host. The workflow contains the
exact platform build commands. Package an already-built Linux bundle with:

```bash
python3 scripts/release/package.py package --target linux \
  --metadata build/release-metadata.json --output dist --arch x64
```

The other targets use the same command with `windows`, `macos`, `ios-device`,
`ios-simulator`, `android` or `web`. Web adds `--base-href /flutter/`. Missing
bundles, mismatched native versions/architectures, unsafe symlinks or existing
output filenames fail clearly. Use a new output directory for a deliberate rebuild.

## Validation and limits

CI includes formatting, analysis, unit/widget/migration tests, both native Linux
reader/Study journeys, and a browser launch of the actual compiled Web application.
Browser fixtures make API responses deterministic while exercising the real
SQLite WASM/worker and persistence after public requests become unavailable.
Linux installs its actual Debian package and launches the installed binary.
Desktop process startup checks complement feature integration tests; they do
not establish complete assistive-technology or device behavior.

Physical-device gestures, screen readers, store acceptance and the remaining
parity/offline/portability work remain listed in the release checklist. Successful
packaging provides downloadable builds without declaring those product gates complete.
