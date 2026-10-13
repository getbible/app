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
already-running application. The launcher now installs and launches the built
APP paused, obtains its process ID, and discovers the authenticated service URL
from retained unified logs scoped to that process, executable and launch time.
It uses the supported explicit connection path to run the same six acceptance
tests. Install, launch and discovery share one three-minute startup budget;
driver attachment and test failures never enter the reboot path. The published
alpha 5 assets remain unchanged.

Native verification of this connection path succeeded on iPhone on its first
attempt: retained-log discovery took 9.29 seconds and all six tests passed. It
also exposed a separate post-exit cleanup error: macOS rejected a process-group
signal after the driver had exited successfully. The existing-app command now
explicitly requests Flutter's application/device cleanup. A denied group signal
is recorded as a warning only when the command has already exited; it cannot
replace a completed command's result. Denied signals for running commands remain
errors, and the final simulator shutdown is still attempted.

The same [verification run
38153311245](https://github.com/getbible/app/actions/runs/38153311245) retained a
different iPad failure: installation and boot completed, but both `simctl launch`
attempts timed out without a process ID, Runner log or VM-service announcement.
The simulator screenshots show an unlocked home screen and the installed app.
This establishes a failure before application execution; it does not identify
the underlying CoreSimulator cause.

Review also found that the runner sent TERM/KILL to every command's process
group after normal exit, including simulator discovery, boot and installation.
Normal command completion does not authorize terminating persistent platform
services initialized by that command. The runner now reaps naturally completed
commands without signalling their groups, regardless of exit code. Bounded
group termination still runs after timeouts or interruptions. Regression tests
cover both natural completion and aborted-command cleanup. Native CI is needed
to determine whether this lifecycle correction also resolves the iPad launch
stall; the recorded iPad evidence alone cannot prove that causal connection.

The next [verification run
38154773547](https://github.com/getbible/app/actions/runs/38154773547) passed iPad
acceptance on its first attempt, including all six tests and shutdown. The iPhone
launched PID 9094 and announced its VM service at 16:25:36.991 UTC. Its first
retained-log query was then aborted by an independent 30-second query limit,
while about 90 seconds remained in the shared startup budget. That premature
timeout triggered a reboot; the second launch stalled before application startup.
Log discovery now uses the remaining shared budget, just like install and
launch. The overall three-minute startup bound is unchanged. Regressions cover
a log query taking more than 30 seconds, shared-deadline exhaustion and the
shorter overall session deadline.

## 11 October: isolate the remaining native simulator launch stall

[PR 9 verification](https://github.com/getbible/app/actions/runs/38155966677)
passed both iOS families on their first attempt. The iPad log query took 43.73
seconds, directly exercising the corrected shared timeout. The subsequent
[main run](https://github.com/getbible/app/actions/runs/38157448974) passed iPhone
and every other platform, but iPad again stalled before application execution.
Both `simctl launch` attempts timed out without a process ID or test driver.
Rebooting the same image-provided device did not recover it. Initial device
discovery also took 163.71 seconds on that host; the evidence does not establish
a single underlying CoreSimulator cause.

The next correction isolates acceptance from image-provided device state.
Flutter 3.44.6's `dev/devicelab/lib/framework/ios.dart` provides the reference
lifecycle: create a simulator for the test, boot it, then shut down and delete
that simulator during teardown. The selected iOS runtime and device type must
remain unchanged. Only a validated, newly created device ID may establish
ownership; pre-existing devices must never become cleanup targets. Application
code, package versions and failed-test retry restrictions remain unchanged.
The single pre-driver recovery replaces the owned device after successful
deletion, rather than rebooting that same stalled device. Both attempts reuse
the built APP, runtime and device type. Final teardown reserves bounded time
for both shutdown and deletion, even if earlier diagnostics fail.
Successful stages across the observed runs took up to 123.17 seconds to install,
89.53 seconds to launch and 43.73 seconds to query retained logs. These were
separate observations, not one measured startup, but their plausible combination
exceeds the previous three-minute shared budget. Install/launch/discovery now
share five minutes; a regression exercises that combination without a recovery.
Flutter driver attachment retains three minutes, tests retain twelve minutes,
and the overall execution limit remains 38 minutes. The number of attempts is
unchanged. Failures also retain a bounded host unified-log excerpt for
CoreSimulator/simctl, supplementing the simulated device's logs without delaying
the reserved shutdown and deletion phases.
Native PR and post-merge verification are still required before this remaining
launch failure can be considered resolved.

## 13 October: WebKit catalogue input blocked the next release

[Main CI run 38288406126](https://github.com/getbible/app/actions/runs/38288406126)
compiled the production Web application successfully. Chromium and Firefox
passed both hosting modes, and WebKit passed ordinary hosting. In WebKit's
cross-origin-isolated journey, `run.mjs` timed out after 45 seconds waiting for
`input:focus, textarea:focus` while filling **Find a resource**. The preceding
reader, private-note, backup and automatic-installation checks had succeeded.
This failure identifies the focus-dependent browser interaction, not a Web
compilation failure or an unavailable public service. The separate live probe
reported all six public services available with browser CORS.

The browser harness now addresses the intended editable field directly and
retains the existing filter-value and resource-restoration assertions. All six
browser/hosting journeys remain required, with no failed-journey retry or
ignored assertion. Exact-run verification belongs in [Testing](TESTING.md).

All native package builds, native runtime journeys and the main test job passed.
The six native package archives remain attached to that run. Web packaging is
after browser acceptance, so the failed run has no Web package; its failed
conclusion correctly prevents publication of an incomplete release.

That run still used `1.0.0-alpha.5+6`, already published on 11 October from commit
`b1bc3db21052ce18a7df695aa6af163be19cfc84`. Published assets are immutable, and
rerunning that version would not distribute the newer reader changes. The next
candidate is therefore `1.0.0-alpha.6+7`. Its successful main CI must build and
verify a complete new inventory before automatic publication. Version, source,
checksum, signing and runtime gates remain unchanged; earlier successful native
packages do not replace validation of the new candidate.
