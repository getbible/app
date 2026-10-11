#!/usr/bin/env python3
"""Build once and run iOS acceptance with bounded, diagnosable simulator waits.

Flutter's live simulator log stream can miss the VM service announcement.
Install and launch the built app paused, discover its authenticated VM URI from
the durable system log, then attach the unchanged Flutter test driver. Only a
pre-driver startup timeout may receive one fresh device; failed tests are not retried.
"""

import codecs
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import plistlib
import re
import signal
import subprocess
import sys
import time
from urllib.parse import urlsplit
from uuid import UUID, uuid4


OUTPUT = Path('build/runtime-evidence')
APPLICATION = 'build/ios/iphonesimulator/Runner.app'
TARGET = 'integration_test/platform_acceptance_test.dart'
DRIVER = 'test_driver/platform_acceptance.dart'
# Leave time for workflow setup and artifact upload inside the 50-minute job.
SESSION_SECONDS = 38 * 60
CLEANUP_SECONDS = 90
BUILD_SECONDS = 15 * 60
BOOT_SECONDS = 3 * 60
STARTUP_SECONDS = 5 * 60
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
    """Recognize the host driver, including markers split across output writes."""

    def __init__(self, clock=time.monotonic):
        self.clock = clock
        self.driver_started_at = None
        self.tail = ''

    def observe(self, text):
        observed = self.tail + text
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
        self.tail = observed[-8192:]


class VmServiceDiscovery:
    """Read only this launch's authenticated loopback endpoint from Apple logs.

    Persisted logs avoid the race between app startup and ``log stream`` becoming
    ready. PID, executable and launch time prevent attaching to an earlier app.
    Authentication remains enabled, and the URL may never leave this host.
    """

    def __init__(self, pid, executable, started):
        self.pid, self.executable, self.started = pid, executable, started

    def find(self, text):
        # simctl can emit a getpwuid_r warning on stderr before the JSON array.
        # Keep that evidence, but parse the complete structured stdout payload.
        beginning = re.search(r'^\s*\[', text, flags=re.MULTILINE)
        if beginning is None:
            raise ValueError('Simulator log query did not return a JSON array.')
        records = json.loads(text[beginning.start():])
        if not isinstance(records, list):
            raise ValueError('Simulator log query must return an array.')
        for record in reversed(records):
            if (not isinstance(record, dict) or record.get('processID') != self.pid
                    or not isinstance(record.get('processImagePath'), str)
                    or Path(record['processImagePath']).name != self.executable):
                continue
            try:
                timestamp = datetime.fromisoformat(record.get('timestamp', ''))
            except (TypeError, ValueError):
                continue
            if timestamp.tzinfo is None or timestamp < self.started:
                continue
            message = record.get('eventMessage', '')
            if not isinstance(message, str):
                continue
            match = re.search(r'The Dart VM service is listening on (\S+)', message)
            if match is None:
                continue
            uri = match[1]
            try:
                parsed = urlsplit(uri)
                valid = (parsed.scheme == 'http' and parsed.hostname in ('127.0.0.1', '::1')
                         and parsed.port is not None and 0 < parsed.port < 65536
                         and parsed.username is None and parsed.password is None
                         and not parsed.query and not parsed.fragment
                         and re.fullmatch(r'/[A-Za-z0-9_=-]+/', parsed.path))
            except ValueError:
                valid = False
            if not valid:
                raise ValueError('Simulator announced an invalid authenticated loopback VM URI.')
            return uri
        return None


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
            if not self.signal_group(process, sig):
                return
            try:
                process.wait(timeout=seconds)
            except subprocess.TimeoutExpired:
                continue
            # A dead leader does not prove its descendants exited. SIGKILL the
            # remaining group after graceful shutdown without an unbounded wait.
            if sig == signal.SIGTERM:
                self.signal_group(process, signal.SIGKILL)
            return

    def signal_group(self, process, sig):
        try:
            self.kill_group(process.pid, sig)
        except ProcessLookupError:
            pass
        except PermissionError:
            code = process.poll()
            if code is None:
                # An owned command that is still running must remain a failure.
                raise
            # macOS may retain protected simulator descendants after the owned
            # command exits. Record the denied cleanup without replacing that
            # command's known result, and never escalate the denied signal.
            self.event(stage='process-cleanup', status='permission_denied_after_exit',
                       pid=process.pid, returncode=code, signal=sig.name)
            return False
        return True

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
        completed = False
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
                        completed = True
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
                           'driver_started': progress.driver_started_at is not None,
                       }))
            raise
        finally:
            # A completed simctl command can leave persistent CoreSimulator
            # services in its process group. Normal exit is not permission to
            # terminate those services. Only aborts require forced cleanup;
            # Flutter's --no-keep-app-running owns its normal driver shutdown.
            if process is not None and not completed:
                self.stop(process)


class SimulatorAcceptance:
    def __init__(self, runner, *, application=APPLICATION,
                 utc_now=lambda: datetime.now(timezone.utc)):
        self.runner = runner
        self.application = Path(application)
        self.utc_now = utc_now
        self.identifier = None
        self.attempt = 0

    def create_device(self, family, runtime, template, reserved_identifiers):
        """Create an owned device with the selected image device's OS and type.

        The image-provided device is only a profile reference. Never adopt an
        identifier from the initial inventory, including unavailable devices,
        or a previous attempt. Never guess ownership after an ambiguous create.
        """
        if self.identifier is not None:
            raise RuntimeError('Delete the current owned simulator before creating another.')
        device_type = template.get('deviceTypeIdentifier')
        if (not isinstance(device_type, str)
                or not device_type.startswith('com.apple.CoreSimulator.SimDeviceType.')):
            raise ValueError('Selected simulator does not identify its device type.')
        name = f'getBible-acceptance-{family}-{uuid4().hex}'
        stage = f'attempt-{self.attempt}/create-device'
        self.required(['xcrun', 'simctl', 'create', name, device_type, runtime],
                      stage, BOOT_SECONDS)
        returned = (self.runner.output / f'{stage}.log').read_text().strip()
        try:
            identifier = str(UUID(returned))
        except ValueError as error:
            raise ValueError('Simulator creation did not return one canonical UUID.') from error
        if returned.lower() != identifier:
            raise ValueError('Simulator creation did not return one canonical UUID.')
        if identifier in {value.lower() for value in reserved_identifiers}:
            raise ValueError('Simulator creation returned an existing device; refusing ownership.')
        # Ownership is recorded only after successful creation and validation.
        self.identifier = identifier.upper()
        reserved_identifiers.add(self.identifier)
        metadata = json.dumps({
            'name': name, 'udid': self.identifier, 'runtime': runtime,
            'deviceTypeIdentifier': device_type, 'owned': True,
            'template_udid': template['udid'],
        }, indent=2) + '\n'
        (self.runner.output / 'device.json').write_text(metadata)
        (self.runner.output / f'attempt-{self.attempt}/device.json').write_text(metadata)
        self.runner.event(stage=stage, status='owned', udid=self.identifier)

    def application_identity(self):
        with (self.application / 'Info.plist').open('rb') as source:
            metadata = plistlib.load(source)
        bundle = metadata.get('CFBundleIdentifier')
        executable = metadata.get('CFBundleExecutable')
        if (not isinstance(bundle, str) or not re.fullmatch(r'[A-Za-z0-9.-]+', bundle)
                or not isinstance(executable, str)
                or not re.fullmatch(r'[A-Za-z0-9_.-]+', executable)):
            raise ValueError('Built iOS app has an invalid bundle identifier or executable.')
        return bundle, executable

    def start_application(self, bundle, executable):
        prefix = f'attempt-{self.attempt}'
        deadline = min(self.runner.clock() + STARTUP_SECONDS, self.runner.deadline)

        def startup(command, stage):
            remaining = deadline - self.runner.clock()
            if remaining <= 0:
                raise StageTimeout(stage, session_expired=self.runner.clock() >= self.runner.deadline)
            self.required(command, stage, remaining)

        startup(['xcrun', 'simctl', 'install', self.identifier, str(self.application)],
                f'{prefix}/install')
        # Apple log dates have subsecond precision. Filter the retained records
        # at this second boundary and the exact PID returned by this launch.
        started = self.utc_now().replace(microsecond=0)
        startup(['xcrun', 'simctl', 'launch', self.identifier, bundle,
                 '--enable-dart-profiling', '--disable-vm-service-publication',
                 '--start-paused', '--enable-checked-mode', '--verify-entry-points'],
                f'{prefix}/launch')
        output = (self.runner.output / f'{prefix}/launch.log').read_text()
        match = re.search(r'^' + re.escape(bundle) + r': ([1-9][0-9]*)\s*$', output, re.MULTILINE)
        if match is None:
            raise ValueError('simctl launch did not identify the started application process.')
        discovery = VmServiceDiscovery(int(match[1]), executable, started)
        query = 0
        self.runner.event(stage=f'{prefix}/discovery', status='started', pid=discovery.pid)
        while self.runner.clock() < deadline:
            query += 1
            stage = f'{prefix}/vm-service/{query:03d}'
            startup(['xcrun', 'simctl', 'spawn', self.identifier, 'log', 'show',
                     '--last', '5m',
                     '--style', 'json', '--predicate', f'process == "{executable}"'],
                    stage)
            uri = discovery.find((self.runner.output / f'{stage}.log').read_text())
            if uri is not None:
                self.runner.event(stage=f'{prefix}/discovery', status='ready', pid=discovery.pid)
                return uri
            remaining = deadline - self.runner.clock()
            if remaining > 0:
                self.runner.pause(min(1, remaining))
        raise StageTimeout(f'{prefix}/discovery',
                           session_expired=self.runner.clock() >= self.runner.deadline)

    def required(self, command, stage, timeout):
        code = self.runner.run(command, stage, timeout)
        if code:
            raise CommandFailure(stage, code)

    def best_effort(self, arguments, stage, timeout):
        self.diagnostic(['xcrun', 'simctl', *arguments], stage, timeout)

    def diagnostic(self, command, stage, timeout):
        try:
            code = self.runner.run(command, stage, timeout)
            if code:
                self.runner.event(stage=stage, status='diagnostic_failed', returncode=code)
        except (OSError, RuntimeError) as error:
            self.runner.event(stage=stage, status='diagnostic_failed', reason=str(error))

    def capture(self, *, failed=False):
        prefix = f'attempt-{self.attempt}'
        previous_deadline = self.runner.deadline
        self.runner.deadline = min(previous_deadline, self.runner.clock() + 30)
        try:
            if failed:
                # Device logs cannot explain a host CoreSimulator IPC stall.
                # This failure-only query shares the diagnostic budget and
                # cannot delay the reserved shutdown and deletion phases.
                self.diagnostic(['/usr/bin/log', 'show', '--last', '5m', '--style',
                                 'compact', '--predicate',
                                 'process CONTAINS "CoreSimulator" OR process == "simctl"'],
                                f'{prefix}/host-console', 10)
            self.best_effort(['io', self.identifier, 'screenshot',
                              str(self.runner.output / prefix / 'simulator.png')],
                             f'{prefix}/screenshot', 15)
            self.best_effort(['spawn', self.identifier, 'log', 'show', '--last', '5m',
                              '--style', 'compact', '--predicate',
                              'process == "Runner" OR process == "SpringBoard"'],
                             f'{prefix}/simulator-console', 30)
            self.best_effort(['list', 'devices', '--json'], f'{prefix}/devices', 10)
        finally:
            self.runner.deadline = previous_deadline

    def cleanup(self, *, failed):
        if self.identifier is None:
            return
        # Keep the existing 90-second reserve, assigning each phase 30 seconds.
        # An expired diagnostic or failed shutdown cannot consume deletion's
        # reserved phase. Every destructive command targets only our owned UUID.
        cleanup_deadline = self.runner.clock() + CLEANUP_SECONDS
        self.runner.deadline = cleanup_deadline - 60
        try:
            self.capture(failed=failed)
        finally:
            self.runner.deadline = cleanup_deadline - 30
            try:
                self.best_effort(['shutdown', self.identifier], 'cleanup/shutdown', 30)
            finally:
                self.runner.deadline = cleanup_deadline
                self.best_effort(['delete', self.identifier], 'cleanup/delete', 30)

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
        # First discovery starts CoreSimulator on a cold hosted runner; allow
        # its boot budget rather than treating it as a warmed-up metadata read.
        self.required(['xcrun', 'simctl', 'list', 'devices', '--json'],
                      'available-devices', BOOT_SECONDS)
        listing = json.loads((self.runner.output / 'available-devices.log').read_text())
        available = [(runtime, device) for runtime, devices in listing['devices'].items()
                     for device in devices if '.iOS-' in runtime
                     and device['name'].startswith(family) and device['isAvailable']]
        if not available:
            raise RuntimeError(f'No available {family} simulator installed by this Xcode')
        runtime, device = max(available, key=lambda item: (
            tuple(map(int, re.findall(r'\d+', item[0]))), item[1]['name']))
        existing_identifiers = {item['udid'] for devices in listing['devices'].values()
                                for item in devices}
        (self.runner.output / 'device-template.json').write_text(
            json.dumps({'runtime': runtime, **device}, indent=2) + '\n')
        accepted = False
        try:
            # Normal pub/native tooling regeneration is needed when switching to
            # the integration target. Drive then reuses exactly this built APP.
            self.required(['flutter', 'build', 'ios', '--simulator', '--debug',
                           f'--target={TARGET}'], 'build', BUILD_SECONDS)
            bundle, executable = self.application_identity()
            for attempt in (1, 2):
                self.attempt = attempt
                self.create_device(family, runtime, device, existing_identifiers)
                self.boot()
                try:
                    uri = self.start_application(bundle, executable)
                except StageTimeout as error:
                    if attempt != 1 or error.session_expired:
                        raise
                    self.runner.event(stage='recovery', status='replacing_device',
                                      reason='Simulator install/launch/VM wait expired before test driver started')
                    self.capture(failed=True)
                    self.best_effort(['shutdown', self.identifier], 'recovery/shutdown', 30)
                    # Do not create another device while a previous owned one
                    # remains. A failed deletion is a failure, not another retry.
                    self.required(['xcrun', 'simctl', 'delete', self.identifier],
                                  'recovery/delete', 30)
                    self.identifier = None
                    continue
                # This command may resume the paused app: no exception from
                # attachment or the test journey is eligible for a new attempt.
                progress = DriverProgress(self.runner.clock)
                code = self.runner.run([
                    'flutter', 'drive', '--verbose', '--no-pub', '--no-keep-app-running',
                    f'--driver={DRIVER}', f'--target={TARGET}',
                    f'--use-existing-app={uri}', '-d', self.identifier,
                ], f'attempt-{attempt}/driver', ATTACH_SECONDS, progress=progress)
                if code:
                    raise CommandFailure(f'attempt-{attempt}/driver', code)
                if progress.driver_started_at is None:
                    raise RuntimeError('Flutter exited without evidence of a test driver.')
                accepted = True
                return 0
            raise RuntimeError('Simulator attempts exhausted.')
        finally:
            self.cleanup(failed=not accepted)


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
