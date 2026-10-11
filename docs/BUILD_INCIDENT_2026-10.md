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

## 10 October: iPad runtime timeout blocked alpha 5 publication

[Main CI run 38078120633](https://github.com/getbible/app/actions/runs/38078120633)
successfully built and retained all seven platform package archives for
`1.0.0-alpha.5+6`. All other required checks passed. Its iPad runtime job completed
the Xcode build at 19:14 UTC, then emitted no driver connection or test-start
message before the 50-minute job timeout at 19:54 UTC. This was a simulator
launch/attachment stall after compilation; the available log does not identify
the underlying CoreSimulator failure. It does not establish an application test
assertion failure.

The acceptance launcher had no timeout around the Flutter child process or its
simulator commands. It also buffered its evidence file: the retained
`runtime-iPad` artifact contained a zero-byte `driver.log`, even though command
output had reached the Actions console. Cancellation at the outer job deadline
prevented useful final simulator diagnostics. The unsuccessful CI conclusion
correctly prevented automatic release promotion.

Recover an otherwise successful main run by rerunning only its failed/cancelled
runtime job. A successful new attempt triggers **Publish tested packages** and
promotes the original versioned archives, with commit/checksum validation and no
rebuild. Successful checks must remain required; do not publish a failed run or
replace its conclusion with a manual override. The promotion inventory accepts
original-attempt package archives and ignores repeated runtime diagnostics.

The revised launcher builds the integration APP once, then reuses that exact
bundle for bounded simulator attempts. It limits build, boot, attachment and
test phases independently, with a 38-minute overall execution budget and a
separate 90-second cleanup reserve. Child output is written directly to disk;
per-stage JSON events, simulator screenshots and console diagnostics survive a
timeout. Owned child process groups are terminated, and cleanup reserves time
for shutdown even if diagnostic commands stall.

One reboot/relaunch is allowed only after an observed simulator install, launch
or VM-service wait times out before the host test driver begins, without a
reported error. Build failures, nonzero driver exits, test failures and timeouts
after the driver begins remain failures. Recovery does not rebuild the APP or
retry failed assertions. The exact underlying failure in the original silent
launch remains unknown; new verbose attempt evidence makes recurrence diagnosable.

## 11 October: retained evidence identifies missed VM-service discovery

The complete PR verification passed, but the subsequent [main run
38142017784](https://github.com/getbible/app/actions/runs/38142017784) failed both
iOS runtime jobs. All seven package builds and the other platform checks passed.
The new watchdog retained evidence and stopped each unsuccessful launch attempt
after three minutes; it did not resolve the underlying connection problem.

On the first attempt, both apps actually started. The iPhone unified log records
the Dart VM service at 13:19:29 UTC; the iPad records it at 13:18:46 UTC. Flutter
continued waiting for that service in both cases and never invoked the host test
driver. The second attempts stalled inside `simctl launch`. No application test
assertion ran or failed in these jobs. Increasing the discovery timeout alone
does not address a service announcement missed by the live log listener.

Flutter 3.44.6 provides `drive --use-existing-app=<URL>` to attach directly to an
already-running application. The repair must discover the authenticated service
URL from retained unified logs scoped to the current launch, then use this
supported connection path while preserving all six acceptance tests and their
failure semantics. The already-published alpha 5 assets remain unchanged.
