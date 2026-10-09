# Local launch failures and distribution coverage

The 9 October 2026 reports expose two host setup failures and a separate CI
delivery gap. Dependency update notices in both logs are informational.

* Linux stops in CMake because `clang++` is missing. The Flutter Snap also
  reports the missing compiler before dependency resolution. Installing Flutter
  alone does not install the Linux native toolchain.
* The Chrome target compiles, then Chrome exits before connecting to Flutter's
  debugger. Its stderr includes Snap portal access and GTK configuration errors.
  This points to the browser's host environment; the log does not establish an
  application compilation error or identify a single conclusive browser cause.

The previous workflow installed Flutter 3.44.6, ran unit/widget tests and two
Linux integration journeys, and built Web, Linux and Android debug. It uploaded
only the Web files and debug APK. It neither built Apple/Windows targets nor
produced desktop installers, and a compiled Web artifact was not launched in a
browser. Those checks could not establish complete distribution readiness.

This repair adds reproducible developer preflight/setup, actual browser startup
and persistence coverage, platform-host build jobs, versioned packaging and
checksums. Testable unsigned outputs must remain distinguishable from signed
store submissions. See `LOCAL_DEVELOPMENT.md` and `DEPLOYMENT.md` for the final
commands and signing boundaries.
