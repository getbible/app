# Native platform acceptance

The shared journeys use the production Flutter reader, application controllers,
SQLite stores and installation workers. Only public HTTP is replaced with
contract fixtures. They never contact private user profiles or a live API.

```bash
flutter pub get --enforce-lockfile
flutter drive --driver=test_driver/platform_acceptance.dart \
  --target=integration_test/platform_acceptance_test.dart -d <device-id>
```

On Linux CI, wrap the command in `xvfb-run -a dbus-run-session --`. The session
bus also exercises the desktop application's single-instance registration.
Use `flutter devices` to find a connected device; mobile signing requirements
still apply to physical iOS hardware. These are debug instrumented acceptance
builds. Normal release builds subsequently regenerate their platform registrants
and must use `flutter build …` without `--no-pub` or a test entry point.

The aggregate checks:

- Upgrade a released schema-4 database twice while preserving private identities,
  timestamps, Unicode note text and public provenance.
- Copy a reference through the native OS clipboard, close it without changing
  reading position, protect an unsaved inline note and open an exact distant verse.
- Read dictionary/commentary/topics, explicitly copy a public topic and reopen
  a private notebook offline through the native responsive Study surface.
- Export and preview/confirm a complete private backup, install all four resource
  types through real workers, reject a corrupt replacement, close/reopen SQLite,
  then read/search/preview every installed resource with zero public HTTP.
- Parse a synthetic 20,000-verse corpus through the actual native worker, enforce
  its bounded verse batches and verify that the UI event loop continues running.

The native file-picker and share-sheet dialogs are OS surfaces outside
`integration_test`; this aggregate does **not** claim to automate those dialogs.
The compiled-browser suite separately uses a real download and file picker.
Physical-device gestures, suspension, accessibility readers and store approval
remain independent acceptance records.

`build/runtime-evidence` retains driver logs and JSON worker telemetry. Android
and iOS additionally capture the reopened installed reader at the actual device
viewport. CI records Android properties/logcat or the selected iOS simulator
identity and screenshot. Timing and process memory are diagnostic measurements,
not hard performance thresholds or physical-device benchmarks.

The Android runner wakes its dedicated emulator, keeps it awake across the
build, and dismisses the insecure keyguard. It builds the integration APK first,
then checks actual native HOME-window focus immediately before launching that
same APK. If the resolved Pixel Launcher already has its known boot ANR dialog,
the runner preserves its screenshot and logcat, force-stops only that launcher
once, and requires its relaunched HOME window to regain stable input focus.
Unknown errors and a repeated launcher ANR fail; application ANRs are never
dismissed. An Android resumed lifecycle alone does not prove native window
focus. The clipboard journey waits for the app's completed Copy action and
asserts the real OS clipboard text. A failure retains window/activity/power
state and an OS screenshot alongside logcat; clipboard assertions are never
replaced by mocks or retries on installed devices.

`runtime-validation.yml` runs macOS/Windows desktop plus Android phone/tablet
(API 35, 2 CPU cores, 2 GiB RAM) and iPhone/iPad simulator jobs. The Linux package
job runs the same aggregate. Each target must pass; failure does not downgrade
the result to a build-only check.

Mobile sandboxes cannot read the checkout's fixture paths. These journeys use a
generated Dart fixture library that is imported only from test code, never
from `lib/` or the release entry point. The original JSON/SQL remains authoritative:

```bash
python3 scripts/testing/embed_fixtures.py
python3 scripts/testing/embed_fixtures.py --check
```

CI rejects a stale generated library. Regular host widget tests import the same
fixtures, so native and widget tests cannot silently test different payloads.
`test/platform_compact_acceptance_test.dart` also runs the full Study and offline
portability journeys at 390 × 844 logical pixels, retaining all persistence and
zero-HTTP assertions to catch inaccessible compact controls before emulator CI.
