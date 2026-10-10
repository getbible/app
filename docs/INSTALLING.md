# Installing test releases

Download from [getbible/app Releases](https://github.com/getbible/app/releases).
Alpha, beta and release-candidate builds have the **Pre-release** label. Their
notes contain direct links to the actual installers, source commit and successful
CI run. Use the same release version across devices when reporting a problem.
The auto-generated **Source code** ZIP/tarball contains source code, not an app.

For an unmerged PR, open its successful **Flutter CI** run and download a
`packages-<platform>-<version>` artifact. Sign into GitHub to download Actions
artifacts and extract that outer ZIP first. The installers inside are already
versioned; no Flutter SDK or compilation is needed to install them.

## Choose the package

| Device | Download | Installation |
|---|---|---|
| Debian/Ubuntu x64 | `linux-x64.deb` | Open with a package manager or use `sudo apt install ./<downloaded-file>.deb`. |
| Other compatible Linux x64 | `linux-x64.tar.gz` | Extract the entire folder and run `getbible_life` inside it; install its GTK/runtime dependencies from the host distribution. |
| Windows x64 | `windows-x64-setup.exe` | Run the installer; it installs for the current user without administrator access. |
| macOS | `macos-<architecture>.dmg` | Open, drag getBible.live into Applications, then launch it. `universal` supports both Intel and Apple Silicon. |
| Android phone/tablet or emulator | `android-multiarch-debug.apk` | Install the APK, allowing installation from the chosen source, or use `adb install -r <downloaded-file>.apk`. |
| iPhone/iPad Simulator on macOS | `ios-simulator-<architecture>.app.zip` | Extract with `ditto`, install with `xcrun simctl`, then launch in Xcode Simulator. |
| Chrome or another supported browser | `web-browser.zip` | Extract and serve over HTTP on localhost or HTTPS on a server, at its recorded base path. |

Filenames also include `getbible-live-<version>-build.<number>-`. The complete
commands in each release's notes use that release's actual filenames. Optional
`-signed` desktop installers and signed Android release APKs should be preferred
when provided. A portable Windows ZIP or macOS APP ZIP is also available; extract
the complete bundle so runtime libraries, assets and executable permissions are
preserved. Linux is packaged as DEB and tar.gz; no AppImage is produced.

## Verify and open unsigned desktop builds

Each platform includes `-SHA256SUMS` and `-manifest.json`. The manifest identifies
the source commit, version, architecture, signing state and SHA-256 of every
package. On Linux, use `sha256sum <downloaded-file>`; on macOS,
`shasum -a 256 <downloaded-file>`; on Windows PowerShell,
`Get-FileHash -Algorithm SHA256 <downloaded-file>`. Compare the result with its
entry in SHA256SUMS. If every file listed in a platform's checksum file is in the
same folder, `sha256sum -c <platform-SHA256SUMS>` verifies the full set on Linux.

Windows SmartScreen may warn because a test EXE has no distribution signature.
After verifying the download's source and checksum, choose **More info → Run
anyway** if your device policy permits. The installer bundles the Microsoft C++
runtime and does not download a prerequisite at install time.

For an unsigned macOS download, first attempt to open the app, then use
**System Settings → Privacy & Security → Open Anyway** if Gatekeeper blocks it
and your device policy allows this override. This accepts that specific app;
there is no need to disable Gatekeeper globally. Apple documents the process in
[Open apps safely on your Mac](https://support.apple.com/102445). A damaged bundle
or wrong CPU architecture is a separate problem; accepting a warning will not
repair it. Download and extract the original archive again before reporting it.

## Mobile test limits

The debug APK is installable on physical Android phones/tablets and compatible
emulators. An unsigned release APK is build-validation output and needs signing;
an AAB is intended for Play Console upload, not direct installation. Separate CI
runs can use different debug keys. If Android reports an incompatible signature
during an update, export a complete private backup from the existing installation
before deciding to uninstall it. Uninstalling Android applications deletes their
private data. Configuring a persistent release key avoids this identity change.

On macOS with Xcode, start the desired simulator and extract the simulator ZIP
using the exact command and filename in that release's notes. The equivalent
installation sequence after extraction into `ios-simulator/` is:

```bash
xcrun simctl install booted ios-simulator/Runner.app
xcrun simctl launch booted life.getbible.mobile
```

Match the package's CPU architecture to the simulator. The `ios-device` unsigned
APP ZIP **cannot be installed on a physical iPhone or iPad** by accepting a
warning. Apple requires provisioning/signing for devices. The optional signed
App Store IPA still needs an authorized TestFlight/App Store Connect upload; it
is not an ad-hoc sideload package. Store upload is a later workflow and is not
performed by these builds.

## Web test hosting

The default bundle base path is `/flutter/`. Extract the Web ZIP into
`preview/flutter/`, serve its parent with
`python3 -m http.server 8000 --directory preview`, and open
`http://localhost:8000/flutter/`. A custom manual CI build records its actual
`base_href` in the manifest and release notes; use that path instead. Keep the
database/offline worker and Wasm files beside the other app assets. Opening
`index.html` through `file://` is unsupported. Browser-private data belongs to
the origin, so changing the hostname or port gives a different local data store.

The reader uses friendly paths such as `/flutter/kjv/Genesis/1/3`. A production
host must rewrite otherwise-unmatched HTML navigation requests under the base
path to that deployment's `index.html`, while returning real missing-asset
errors for JavaScript, Wasm and other files. This is required for a first visit
directly to a passage before a service worker controls the browser. Python's
simple file server has no SPA fallback: begin the local test at `/flutter/` and
wait for shell preparation before testing passage reloads.

After the initial online visit finishes preparing application files, this shell
can reopen from the same origin with the network unavailable. Install the
desired Bible/Study resources separately for complete offline content. Browser
storage eviction or explicitly clearing site data can remove the app shell or
private data; export private backups. Application updates prepare a new verified
cache while existing tabs retain their current app version. Close all tabs for
that deployment and reopen it to activate a waiting update; the app does not
force-reload an open private editor.

## Updates, links and removal

Export **Backup and restore → Complete private backup** before testing a new
version. The application identifier remains `life.getbible.mobile`; normal
desktop updates preserve its private data. Replacing Linux files through DEB,
running the Windows installer again, or replacing the macOS APP updates the app
without intentionally deleting its database. A backup remains necessary before
downgrades or operating-system/device cleanup.

The Linux DEB and Windows installer register the `getbible:` passage scheme.
For example, `getbible:///KJV/John/3?verse=16` opens John 3:16 in the installed
app. Portable extraction does not register an operating-system protocol handler.
The app validates links and protects an active private editor before navigation.
Public HTTPS association depends on the website's domain-association
configuration and platform signing; a desktop installer does not take over all
web links.

Remove Linux DEB installs with `sudo apt remove getbible-live`, Windows installs
through **Installed apps**, and macOS installs by removing getBible.live from
Applications. The desktop installers do not deliberately erase private user
files during removal. OS cleanup tools and mobile uninstallation can remove
private data, so keep exported backups outside the app's own data directory.

When reporting a problem, include the release version, operating system/CPU,
package filename, source CI run, installation method and exact error. Do not
attach private backups or signing credentials to a public issue.
