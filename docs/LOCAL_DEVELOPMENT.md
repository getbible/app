# Local development and host diagnostics

Use the exact SDK in [`.flutter-version`](../.flutter-version), currently Flutter
3.44.6, for local work and CI. This keeps failures reproducible across machines.
The SDK is installed separately from the operating-system compilers, browser,
Android SDK, Xcode and Visual Studio. `flutter pub get` cannot install those host
dependencies. The scripts below use Python 3.8 or newer and its standard library.

## Ubuntu/Debian: prepare the host

Run these explicit administrative commands once:

```bash
sudo apt-get update
sudo apt-get install -y python3 curl git unzip xz-utils zip libglu1-mesa \
  clang cmake ninja-build pkg-config libgtk-3-dev g++
```

`g++` selects the distribution's C++ standard-library development package.
The Linux check actually compiles and links a C++/GTK program, so missing headers
or libraries are detected as well as a missing `clang++` executable. These are
development dependencies; end users install a built package instead.

From the repository root, in a normal host terminal:

```bash
python3 scripts/bootstrap_flutter.py
export FLUTTER_ROOT="${XDG_CACHE_HOME:-$HOME/.cache}/getbible/flutter/$(cat .flutter-version)"
export PATH="$FLUTTER_ROOT/bin:$PATH"
hash -r
flutter --version
flutter doctor -v
flutter pub get
python3 scripts/develop.py check linux
python3 scripts/develop.py run linux
```

The bootstrap selects the exact stable release and CPU architecture from
Flutter's official release metadata, downloads its official archive, checks the
published SHA-256 before extraction and activates the SDK only after extraction
finishes. It preserves existing installations, makes no shell-profile changes,
and never invokes `sudo`. Interrupted downloads do not become usable SDKs. It
supports Linux and macOS when that release publishes an archive for the host CPU.
An unavailable archive fails explicitly rather than selecting a different CPU.

Use `--destination /absolute/path/to/new-sdk` to choose another location, then
use the printed `FLUTTER_ROOT` and `PATH` commands. The development wrapper uses
an explicit `FLUTTER_ROOT` first, then its pinned cached SDK, then `PATH`.
Configure your editor's Flutter SDK path to the same directory and restart its
terminal. Do not run `flutter upgrade` in the pinned SDK; update the repository
pin and validate every target together when upgrading.

## Chrome and static web builds

Install Chrome using Google's normal host installation, then run:

```bash
python3 scripts/develop.py check chrome
python3 scripts/develop.py run chrome
```

`CHROME_EXECUTABLE` may select an explicit browser executable. The check launches
Chrome with a temporary profile and its sandbox enabled, rendering a local blank
document headlessly. It detects crashes, unusable executables and launch timeouts.
A successful headless check alone does not verify a graphical desktop session;
`run chrome` then performs Flutter's actual interactive launch.

To launch the browser manually, including an already open browser:

```bash
python3 scripts/develop.py run web-server --web-port 8080
```

Open the URL Flutter prints. Flutter documents limited debugging support in
web-server mode. This avoids automatic browser process launching; it does not
change the application. Keep Chrome's sandbox enabled and run as an ordinary
desktop user.

A static web build needs neither Chrome nor the Linux desktop compiler:

```bash
python3 scripts/develop.py build web --release
python3 -m http.server 8080 --directory build/web
```

Open `http://localhost:8080`. For a deployed subdirectory, pass the matching
`--base-href` to the build command; the server path must agree. Never open the
compiled `index.html` directly through a `file:` URL.

## Diagnoses from the October 2026 reports

| Report | Evidence and remedy |
|---|---|
| Linux `CMAKE_CXX_COMPILER not set` | CMake says `CXX=clang++` cannot be found; the Flutter Snap warning already identifies missing `clang`. Install the Linux packages above. If `CXX` explicitly points at a removed compiler, correct it or `unset CXX`, then rerun the check. |
| Chrome fails after three launch attempts | The browser process reports Snap portal access denial, a GTK property error and a crashpad error. This establishes a browser-launch failure, not a Dart compiler failure. The combination points to the Snap/host graphical environment, but the log does not identify the sole browser crash cause. Use the official SDK from a host terminal, verify Chrome opens independently and run the Chrome check. Manual web-server mode is available while diagnosing the host session. |
| Packages have newer incompatible versions | Informational dependency-resolution output, not either reported failure. Preserve `pubspec.lock`; do not force dependency upgrades to repair a missing compiler or browser crash. |

If switching SDKs leaves old generated build paths, run `flutter clean` followed
by `flutter pub get` once, then retry. These commands remove generated build
outputs, not application data. Avoid deleting application databases or user
configuration when repairing the compiler environment.

## Other native targets

Use the same pinned official SDK on each host. Windows requires Visual Studio's
Desktop development with C++ workload; macOS and iOS/iPadOS require macOS/Xcode;
Android requires the Android SDK and accepted licenses. Follow Flutter's official
target setup documentation and the repository's [distribution guide](DEPLOYMENT.md).
On Windows download the pinned SDK from the official archive and select it in
the editor. The development wrapper above focuses on the Linux and browser
failure reports; it does not certify another platform's toolchain.

## What automated checks establish

`python3 -m unittest discover -s scripts/tests -p 'test_development.py'` covers
missing/stale compilers, GTK link failure, incompatible SDKs, Snap selection,
browser crashes/timeouts, failed build exit codes and corrupt SDK downloads.
These simulate known environmental failures; real target builds and browser
tests must still run in CI on provisioned hosts. CI cannot install tools on a
developer's workstation. A green unit suite alone does not prove a build, a
browser launch, package installation or store submission succeeds.

Official references:

- [Manual SDK installation](https://docs.flutter.dev/install/manual)
- [SDK archive](https://docs.flutter.dev/install/archive)
- [Linux prerequisites](https://docs.flutter.dev/platform-integration/linux/setup)
- [Browser setup and manual launching](https://docs.flutter.dev/platform-integration/web/setup)
- [Build and serve web output](https://docs.flutter.dev/deployment/web)
