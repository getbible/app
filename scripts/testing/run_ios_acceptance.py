#!/usr/bin/env python3
"""Build once and run iOS acceptance with bounded, diagnosable simulator waits.

Flutter 3.44.6 waits without a deadline for the simulator's VM service. Its
``drive --timeout`` starts only after launch, so it cannot cover that wait.
Only an observed pre-driver install/launch/VM wait may receive one reboot. Build
failures, driver failures and started test journeys are never retried.
"""

import codecs
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import time


OUTPUT = Path('build/runtime-evidence')
APPLICATION = 'build/ios/iphonesimulator/Runner.app'
TARGET = 'integration_test/platform_acceptance_test.dart'
DRIVER = 'test_driver/platform_acceptance.dart'
# Leave time for workflow setup and artifact upload inside the 50-minute job.
SESSION_SECONDS = 38 * 60
CLEANUP_SECONDS = 90
BUILD_SECONDS = 15 * 60
BOOT_SECONDS = 3 * 60
ATTACH_SECONDS = 3 * 60
TEST_SECONDS = 12 * 60


class CommandFailure(RuntimeError):
    def __init__(self, stage, returncode=1):
        self.returncode = returncode if returncode > 0 else 1
        super().__init__(f'{stage} failed (exit {returncode}); see runtime evidence.')


class StageTimeout(RuntimeError):
    def __init__(self, stage, *, session_expired=False):
        self.session_expired = session_expired
        super().__init__(f'{stage} exceeded its bounded runtime.')


class DriverProgress:
    """Conservative recovery boundary tied to the pinned Flutter SDK's output.

    Drive starts paused. Once its host driver is invoked it can resume the app;
    treat even its *connecting* message as started and never retry after it.
    Keep a small rolling tail so markers split across OS writes are recognized.
    """

    def __init__(self, clock=time.monotonic):
        self.clock = clock
        self.launch_observed = False
        self.driver_started_at = None
        self.saw_failure = False
        self.tail = ''

    def observe(self, text):
        observed = self.tail + text
        self.launch_observed |= (
            'Waiting for VM Service port to be available' in observed
            or bool(re.search(r'executing: [^\n]*\bxcrun\b[^\n]*\bsimctl '
                              r'(?:install|launch) ', observed))
        )
        started = (
            'Connecting to Flutter application at' in observed
            or 'Attempting to resume isolate' in observed
            or 'Connected to Flutter application.' in observed
            or re.search(r'\d{2}:\d{2} \+\d+', observed)
            # With --verbose, the host Dart command precedes its first message.
            or re.search(r'executing: [^\n]*\bdart\b[^\n]*' + re.escape(DRIVER), observed)
        )
        if started and self.driver_started_at is None:
            self.driver_started_at = self.clock()
        self.saw_failure |= bool(re.search(
            r'Unhandled exception|EXCEPTION CAUGHT|\[E\]|Some tests failed|'
            r'Error waiting for a debug connection|Application failed to start|'
            r'EXC_BAD_ACCESS|EXC_CRASH|Fatal signal|Lost connection to device|'
            r'Unable to (?:install|launch)|ProcessException|\b(?:Error|Exception):',
            observed,
        ))
        self.tail = observed[-8192:]

    @property
    def retryable(self):
        return (self.launch_observed and self.driver_started_at is None
                and not self.saw_failure)


class ProcessRunner:
    """Own each command's process group and persist output before echoing it.

    Children write directly to an unbuffered file, so abrupt runner termination
    cannot leave a Python-buffered, empty artifact. Reading the file in bounded
    chunks avoids blocking forever on a silent pipe or an incomplete line.
    """

    def __init__(self, output, *, clock=time.monotonic, pause=time.sleep,
                 popen=subprocess.Popen, kill_group=None):
        self.output = output
        self.output.mkdir(parents=True, exist_ok=True)
        self.clock, self.pause = clock, pause
        # Keep this module importable by the cross-platform Python test suite.
        # Actual simulator execution still requires the POSIX/Xcode host.
        if kill_group is None:
            kill_group = getattr(os, 'killpg', None)
            if kill_group is None or not hasattr(signal, 'SIGKILL'):
                raise RuntimeError('iOS simulator acceptance requires a POSIX host with Xcode.')
        self.popen, self.kill_group = popen, kill_group
        self.deadline = clock() + SESSION_SECONDS

    def event(self, **record):
        record['time'] = time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())
        message = json.dumps(record, sort_keys=True)
        with (self.output / 'stages.jsonl').open('a', encoding='utf-8') as evidence:
            evidence.write(message + '\n')
            evidence.flush()
        print(message, flush=True)

    def stop(self, process):
        # Signal the group even if its leader exited: xcrun/Dart may leave a
        # descendant holding resources. Never kill unrelated runner processes.
        for sig, seconds in ((signal.SIGTERM, 10), (signal.SIGKILL, 5)):
            try:
                self.kill_group(process.pid, sig)
            except ProcessLookupError:
                pass
            try:
                process.wait(timeout=seconds)
            except subprocess.TimeoutExpired:
                continue
            # A dead leader does not prove its descendants exited. SIGKILL the
            # remaining group after graceful shutdown without an unbounded wait.
            if sig == signal.SIGTERM:
                try:
                    self.kill_group(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
            return

    def run(self, command, stage, timeout, *, progress=None):
        started = self.clock()
        stage_deadline = started + timeout
        if started >= self.deadline:
            raise StageTimeout(stage, session_expired=True)
        path = self.output / f'{stage}.log'
        path.parent.mkdir(parents=True, exist_ok=True)
        self.event(stage=stage, status='started', command=command,
                   timeout_seconds=min(timeout, self.deadline - started))
        process = None
        try:
            with path.open('wb', buffering=0) as destination, path.open('rb') as source:
                process = self.popen(command, stdout=destination,
                                     stderr=subprocess.STDOUT, start_new_session=True)
                decoder = codecs.getincrementaldecoder('utf-8')(errors='replace')
                while True:
                    # Poll before reading: after the child exits, drain bytes it
                    # wrote immediately before exit before accepting its result.
                    code = process.poll()
                    chunk = source.read(65536)
                    if chunk:
                        text = decoder.decode(chunk)
                        print(text, end='', flush=True)
                        if progress is not None:
                            progress.observe(text)
                    if code is not None and not chunk:
                        self.event(stage=stage, status='exited', returncode=code,
                                   elapsed_seconds=round(self.clock() - started, 2))
                        return code
                    if progress is not None and progress.driver_started_at is not None:
                        stage_deadline = progress.driver_started_at + TEST_SECONDS
                    now = self.clock()
                    if now >= min(stage_deadline, self.deadline):
                        raise StageTimeout(stage, session_expired=now >= self.deadline)
                    if not chunk:
                        self.pause(min(0.25, stage_deadline - now, self.deadline - now))
        except BaseException as error:
            self.event(stage=stage, status='failed', reason=str(error),
                       elapsed_seconds=round(self.clock() - started, 2),
                       **({} if progress is None else {
                           'launch_observed': progress.launch_observed,
                           'driver_started': progress.driver_started_at is not None,
                           'failure_observed': progress.saw_failure,
                       }))
            raise
        finally:
            if process is not None:
                self.stop(process)


class SimulatorAcceptance:
    def __init__(self, runner):
        self.runner = runner
        self.identifier = None
        self.attempt = 0

    def required(self, command, stage, timeout):
        code = self.runner.run(command, stage, timeout)
        if code:
            raise CommandFailure(stage, code)

    def best_effort(self, arguments, stage, timeout):
        try:
            code = self.runner.run(['xcrun', 'simctl', *arguments], stage, timeout)
            if code:
                self.runner.event(stage=stage, status='diagnostic_failed', returncode=code)
        except (OSError, RuntimeError) as error:
            self.runner.event(stage=stage, status='diagnostic_failed', reason=str(error))

    def capture(self):
        prefix = f'attempt-{self.attempt}'
        self.best_effort(['io', self.identifier, 'screenshot',
                          str(self.runner.output / prefix / 'simulator.png')],
                         f'{prefix}/screenshot', 15)
        self.best_effort(['spawn', self.identifier, 'log', 'show', '--last', '5m',
                          '--style', 'compact', '--predicate',
                          'process == "Runner" OR process == "SpringBoard"'],
                         f'{prefix}/simulator-console', 30)
        self.best_effort(['list', 'devices', '--json'], f'{prefix}/devices', 10)

    def boot(self):
        self.required(['xcrun', 'simctl', 'boot', self.identifier],
                      f'attempt-{self.attempt}/boot', 30)
        self.ready()

    def ready(self):
        self.required(['xcrun', 'simctl', 'bootstatus', self.identifier, '-b'],
                      f'attempt-{self.attempt}/bootstatus', BOOT_SECONDS)

    def run(self, family):
        if family not in ('iPhone', 'iPad'):
            raise ValueError('SIMULATOR_FAMILY must be iPhone or iPad.')
        self.required(['xcrun', 'simctl', 'list', 'devices', 'available', '--json'],
                      'available-devices', 30)
        listing = json.loads((self.runner.output / 'available-devices.log').read_text())
        available = [(runtime, device) for runtime, devices in listing['devices'].items()
                     for device in devices if '.iOS-' in runtime
                     and device['name'].startswith(family) and device['isAvailable']]
        if not available:
            raise RuntimeError(f'No available {family} simulator installed by this Xcode')
        runtime, device = max(available, key=lambda item: (
            tuple(map(int, re.findall(r'\d+', item[0]))), item[1]['name']))
        self.identifier = device['udid']
        (self.runner.output / 'device.json').write_text(
            json.dumps({'runtime': runtime, **device}, indent=2) + '\n')
        try:
            # Normal pub/native tooling regeneration is needed when switching to
            # the integration target. Drive then reuses exactly this built APP.
            self.required(['flutter', 'build', 'ios', '--simulator', '--debug',
                           f'--target={TARGET}'], 'build', BUILD_SECONDS)
            for attempt in (1, 2):
                self.attempt = attempt
                if attempt == 1 and device['state'] == 'Booted':
                    self.ready()
                else:
                    self.boot()
                progress = DriverProgress(self.runner.clock)
                try:
                    code = self.runner.run([
                        'flutter', 'drive', '--verbose', '--no-pub', '--start-paused',
                        f'--driver={DRIVER}', f'--target={TARGET}',
                        f'--use-application-binary={APPLICATION}', '-d', self.identifier,
                    ], f'attempt-{attempt}/driver', ATTACH_SECONDS, progress=progress)
                    if code:
                        raise CommandFailure(f'attempt-{attempt}/driver', code)
                    if progress.driver_started_at is None:
                        raise RuntimeError('Flutter exited without evidence of a test driver.')
                    return 0
                except StageTimeout as error:
                    if attempt != 1 or error.session_expired or not progress.retryable:
                        raise
                    self.runner.event(stage='recovery', status='rebooting',
                                      reason='Simulator install/launch/VM wait expired before test driver started')
                    self.capture()
                    self.required(['xcrun', 'simctl', 'shutdown', self.identifier],
                                  'recovery/shutdown', 30)
            raise RuntimeError('Simulator attempts exhausted.')
        finally:
            # Separate bounded cleanup reserve, including failure during boot or
            # build. No simulator command can starve the workflow's artifact step.
            cleanup_deadline = self.runner.clock() + CLEANUP_SECONDS
            self.runner.deadline = cleanup_deadline - 45
            try:
                self.capture()
            finally:
                self.runner.deadline = cleanup_deadline
                self.best_effort(['shutdown', self.identifier], 'cleanup/shutdown', 30)


def main():
    runner = ProcessRunner(OUTPUT)

    def interrupted(signum, frame):
        raise KeyboardInterrupt(f'Interrupted by signal {signum}')

    previous = {sig: signal.signal(sig, interrupted) for sig in (signal.SIGINT, signal.SIGTERM)}
    try:
        return SimulatorAcceptance(runner).run(os.environ.get('SIMULATOR_FAMILY', ''))
    except KeyboardInterrupt as error:
        runner.event(stage='acceptance', status='interrupted', reason=str(error))
        return 130
    except (OSError, RuntimeError, ValueError, KeyError) as error:
        runner.event(stage='acceptance', status='failed', reason=str(error))
        return error.returncode if isinstance(error, CommandFailure) else 1
    finally:
        for sig, handler in previous.items():
            signal.signal(sig, handler)


if __name__ == '__main__':
    sys.exit(main())
