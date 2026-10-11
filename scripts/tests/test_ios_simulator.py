"""Keep iOS infrastructure recovery bounded without retrying failed journeys."""

import contextlib
from datetime import datetime, timezone
import importlib.util
import io
import json
import os
from pathlib import Path
import plistlib
import signal
import subprocess
import tempfile
import unittest
from unittest.mock import patch


SOURCE = Path(__file__).resolve().parents[1] / 'testing/run_ios_acceptance.py'
SPEC = importlib.util.spec_from_file_location('ios_acceptance', SOURCE)
ios = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(ios)
VM_URI = 'http://127.0.0.1:50145/xHtX2JUvNj8=/'
STARTED = datetime(2026, 10, 11, 13, 18, 0, tzinfo=timezone.utc)
BUNDLE = 'life.getbible.acceptance'
PHONE_UUID = 'A1111111-1111-4111-8111-111111111111'
TABLET_UUID = 'B2222222-2222-4222-8222-222222222222'
UNAVAILABLE_UUID = 'D3333333-3333-4333-8333-333333333333'
OWNED_UUID = 'F4444444-4444-4444-8444-444444444444'
REPLACEMENT_UUID = 'E5555555-5555-4555-8555-555555555555'
RUNTIME = 'com.apple.CoreSimulator.SimRuntime.iOS-26-2'
PHONE_TYPE = 'com.apple.CoreSimulator.SimDeviceType.iPhone-17'
TABLET_TYPE = 'com.apple.CoreSimulator.SimDeviceType.iPad-mini-A17-Pro'


def vm_record(**changes):
    return {
        'processID': 10439,
        'processImagePath': '/Simulator/Containers/Runner.app/Runner',
        'timestamp': '2026-10-11 13:18:46.226000+0000',
        'eventMessage': f'flutter: The Dart VM service is listening on {VM_URI}',
        **changes,
    }


DRIVER_START = 'VMServiceFlutterDriver: Connecting to Flutter application at http://127.0.0.1:1234\n'


class FakeClock:
    def __init__(self):
        self.now = 0

    def __call__(self):
        return self.now

    def pause(self, seconds):
        self.now += seconds


class FakeChild:
    pid = 12345

    def __init__(self, clock, destination, *, events=(), end=None, code=0, ignore_term=False):
        self.clock, self.destination = clock, destination
        self.events = list(events)
        self.end, self.code = end, code
        self.ignore_term = ignore_term
        self.returncode = None
        self.signals = []
        self.waits = []

    def poll(self):
        while self.events and self.events[0][0] <= self.clock():
            _, data = self.events.pop(0)
            self.destination.write(data)
        if self.end is not None and self.clock() >= self.end:
            self.returncode = self.code
        return self.returncode

    def kill_group(self, pid, sig):
        self.assert_pid = pid
        self.signals.append(sig)
        if sig != signal.SIGTERM or not self.ignore_term:
            self.returncode = -sig

    def wait(self, timeout):
        self.waits.append(timeout)
        if self.returncode is None:
            self.clock.pause(timeout)
            raise subprocess.TimeoutExpired('fake', timeout)
        return self.returncode


@unittest.skipUnless(hasattr(os, 'killpg') and hasattr(signal, 'SIGKILL'),
                     'Process-group termination requires POSIX signals')
class ProcessRunnerTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.output = Path(self.directory.name)
        self.clock = FakeClock()
        self.console = io.StringIO()
        self.redirect = contextlib.redirect_stdout(self.console)
        self.redirect.__enter__()
        self.addCleanup(self.redirect.__exit__, None, None, None)

    def runner(self, **options):
        def popen(command, **kwargs):
            self.assertTrue(kwargs['start_new_session'])
            self.assertEqual(kwargs['stderr'], subprocess.STDOUT)
            self.child = FakeChild(self.clock, kwargs['stdout'], **options)
            return self.child
        return ios.ProcessRunner(
            self.output, clock=self.clock, pause=self.clock.pause, popen=popen,
            kill_group=lambda pid, sig: self.child.kill_group(pid, sig),
        )

    def test_silent_wait_preserves_partial_output_and_escalates_own_group(self):
        runner = self.runner(events=[(0, b'launch without newline')], ignore_term=True)
        with self.assertRaises(ios.StageTimeout):
            runner.run(['flutter', 'drive'], 'driver', 1)
        self.assertEqual((self.output / 'driver.log').read_bytes(), b'launch without newline')
        self.assertIn('launch without newline', self.console.getvalue())
        self.assertEqual(self.child.signals, [signal.SIGTERM, signal.SIGKILL])
        self.assertEqual(self.child.waits, [10, 5])
        self.assertEqual(self.child.assert_pid, self.child.pid)
        self.assertEqual(self.clock(), 11)
        events = [json.loads(line) for line in (self.output / 'stages.jsonl').read_text().splitlines()]
        self.assertEqual([event['status'] for event in events], ['started', 'failed'])

    def test_success_drains_output_without_signaling_completed_native_command(self):
        runner = self.runner(events=[(0, b'one\n'), (0.5, b'two\n')], end=0.5)
        self.assertEqual(runner.run(['command'], 'success', 2), 0)
        self.assertEqual((self.output / 'success.log').read_text(), 'one\ntwo\n')
        self.assertIn('two\n', self.console.getvalue())
        self.assertEqual(self.child.signals, [])

    def test_actual_nonzero_status_is_preserved(self):
        runner = self.runner(end=0, code=17)
        self.assertEqual(runner.run(['command'], 'failed-test', 2), 17)
        self.assertEqual(self.child.signals, [])

    def test_abort_while_draining_exited_leader_still_cleans_its_group(self):
        runner = self.runner(events=[(0, b'last output')], end=0)
        with self.assertRaises(ios.StageTimeout):
            runner.run(['command'], 'expired-during-drain', 0)
        self.assertEqual((self.output / 'expired-during-drain.log').read_bytes(), b'last output')
        self.assertEqual(self.child.signals, [signal.SIGTERM, signal.SIGKILL])

    def test_denied_cleanup_after_exit_retains_success_or_failure_without_escalation(self):
        for code in (0, 17):
            for denied_signal in (signal.SIGTERM, signal.SIGKILL):
                with self.subTest(code=code, denied_signal=denied_signal):
                    runner = self.runner(end=0, code=code)
                    signals = []

                    def signal_group(pid, sig):
                        signals.append(sig)
                        if sig == denied_signal:
                            raise PermissionError('protected simulator descendant')

                    runner.kill_group = signal_group
                    self.assertEqual(runner.run(['command'], 'completed', 2), code)
                    self.assertEqual(signals, [])
                    # An abort can race with leader exit. Directly exercise
                    # its cleanup path after the command has been reaped.
                    runner.stop(self.child)
                    expected = ([signal.SIGTERM] if denied_signal == signal.SIGTERM
                                else [signal.SIGTERM, signal.SIGKILL])
                    self.assertEqual(signals, expected)
                    event = json.loads((self.output / 'stages.jsonl').read_text().splitlines()[-1])
                    self.assertEqual(event['status'], 'permission_denied_after_exit')
                    self.assertEqual(event['pid'], self.child.pid)
                    self.assertEqual(event['returncode'], code)
                    self.assertEqual(event['signal'], denied_signal.name)

    def test_denied_cleanup_of_running_command_remains_fatal(self):
        for denied_signal in (signal.SIGTERM, signal.SIGKILL):
            with self.subTest(denied_signal=denied_signal):
                runner = self.runner(ignore_term=True)

                def denied(pid, sig):
                    if sig == denied_signal:
                        raise PermissionError('running process cannot be terminated')
                    self.child.kill_group(pid, sig)

                runner.kill_group = denied
                with self.assertRaisesRegex(PermissionError, 'running process'):
                    runner.run(['command'], 'running', 1)
                self.assertIsNone(self.child.poll())
                self.assertNotIn('permission_denied_after_exit',
                                 (self.output / 'stages.jsonl').read_text())

    def test_driver_start_changes_to_test_budget_without_resetting_on_each_line(self):
        runner = self.runner(events=[(0, DRIVER_START.encode()), (10, b'still working\n')])
        progress = ios.DriverProgress(self.clock)
        with self.assertRaises(ios.StageTimeout):
            runner.run(['flutter', 'drive'], 'driver', 1, progress=progress)
        self.assertEqual(self.clock(), progress.driver_started_at + ios.TEST_SECONDS)

    def test_global_deadline_wins_even_after_driver_starts(self):
        runner = self.runner(events=[(0, DRIVER_START.encode())])
        runner.deadline = 3
        with self.assertRaises(ios.StageTimeout) as caught:
            runner.run(['flutter', 'drive'], 'driver', 1, progress=ios.DriverProgress(self.clock))
        self.assertTrue(caught.exception.session_expired)
        self.assertEqual(self.clock(), 3)

    def test_interruption_cleans_process_group_and_records_reason(self):
        runner = self.runner()
        def interrupt(seconds):
            raise KeyboardInterrupt('cancelled')
        runner.pause = interrupt
        with self.assertRaises(KeyboardInterrupt):
            runner.run(['command'], 'interrupted', 2)
        self.assertEqual(self.child.signals, [signal.SIGTERM, signal.SIGKILL])
        self.assertIn('cancelled', (self.output / 'stages.jsonl').read_text())

    def test_process_spawn_failure_is_retained_without_cleanup_of_other_processes(self):
        runner = self.runner()
        def missing(*args, **kwargs):
            raise FileNotFoundError('flutter unavailable')
        runner.popen = missing
        with self.assertRaises(FileNotFoundError):
            runner.run(['flutter'], 'build', 2)
        self.assertIn('flutter unavailable', (self.output / 'stages.jsonl').read_text())
        self.assertFalse(hasattr(self, 'child'))


class FakeRunner:
    def __init__(self, output, outcomes=None, *, query_records=None, delays=None):
        self.output = output
        self.clock = FakeClock()
        self.pause = self.clock.pause
        self.deadline = ios.SESSION_SECONDS
        self.calls, self.events = [], []
        self.outcomes = outcomes or {}
        self.delays = delays or {}
        self.query_records = [vm_record()] if query_records is None else query_records
        self.application = self.output / 'Runner.app'
        self.application.mkdir()
        with (self.application / 'Info.plist').open('wb') as destination:
            plistlib.dump({'CFBundleIdentifier': BUNDLE, 'CFBundleExecutable': 'Runner'}, destination)

    def event(self, **record):
        self.events.append(record)

    def run(self, command, stage, timeout, *, progress=None):
        self.calls.append((command, stage, timeout, self.deadline))
        if self.clock() >= self.deadline:
            raise ios.StageTimeout(stage, session_expired=True)
        path = self.output / f'{stage}.log'
        path.parent.mkdir(parents=True, exist_ok=True)
        message = ''
        if stage == 'available-devices':
            message = json.dumps({'devices': {
                'com.apple.CoreSimulator.SimRuntime.iOS-18-5': [
                    {'name': 'iPad Pro', 'udid': 'C6666666-6666-4666-8666-666666666666',
                     'state': 'Shutdown', 'isAvailable': True, 'deviceTypeIdentifier': TABLET_TYPE}],
                RUNTIME: [
                    {'name': 'iPhone 17', 'udid': PHONE_UUID, 'state': 'Shutdown',
                     'isAvailable': True, 'deviceTypeIdentifier': PHONE_TYPE},
                    {'name': 'iPad mini (A17 Pro)', 'udid': TABLET_UUID, 'state': 'Booted',
                     'isAvailable': True, 'deviceTypeIdentifier': TABLET_TYPE},
                    {'name': 'iPad unavailable', 'udid': UNAVAILABLE_UUID, 'state': 'Shutdown',
                     'isAvailable': False, 'deviceTypeIdentifier': TABLET_TYPE},
                ]}})
        elif stage.endswith('/create-device'):
            message = (OWNED_UUID if stage.startswith('attempt-1/') else REPLACEMENT_UUID) + '\n'
        elif stage.endswith('/launch'):
            message = f'{BUNDLE}: 10439\n'
        elif '/vm-service/' in stage:
            message = ('getpwuid_r did not find a match for uid 501\n'
                       + json.dumps(self.query_records))
        elif stage.endswith('/driver'):
            message = DRIVER_START
        action = self.outcomes.get(stage, 0)
        if isinstance(action, tuple):
            message, action = action
        path.write_text(message)
        if progress is not None:
            progress.observe(message)
        delay = self.delays.get(stage, 0)
        limit = min(timeout, self.deadline - self.clock())
        self.pause(min(delay, limit))
        if delay >= limit:
            raise ios.StageTimeout(stage, session_expired=self.clock() >= self.deadline)
        if isinstance(action, BaseException):
            raise action
        return action

    @property
    def stages(self):
        return [call[1] for call in self.calls]


class SimulatorAcceptanceTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.output = Path(self.directory.name)
        self.runner_count = 0

    def runner(self, outcomes=None, **options):
        self.runner_count += 1
        output = self.output / str(self.runner_count)
        output.mkdir()
        return FakeRunner(output, outcomes, **options)

    def acceptance(self, runner):
        return ios.SimulatorAcceptance(runner, application=runner.application, utc_now=lambda: STARTED)

    def test_build_once_install_exact_binary_and_attach_to_durable_vm_announcement(self):
        runner = self.runner()
        self.assertEqual(self.acceptance(runner).run('iPad'), 0)
        self.assertEqual(runner.stages.count('build'), 1)
        commands = {stage: command for command, stage, _, _ in runner.calls}
        self.assertNotIn('--no-pub', commands['build'])
        self.assertEqual(commands['attempt-1/install'],
                         ['xcrun', 'simctl', 'install', OWNED_UUID, str(runner.application)])
        launch = commands['attempt-1/launch']
        self.assertEqual(launch[:5], ['xcrun', 'simctl', 'launch', OWNED_UUID, BUNDLE])
        for flag in ('--start-paused', '--disable-vm-service-publication',
                     '--enable-checked-mode', '--verify-entry-points'):
            self.assertIn(flag, launch)
        self.assertNotIn('--disable-service-auth-codes', launch)
        query = commands['attempt-1/vm-service/001']
        self.assertIn('show', query)
        self.assertIn('--last', query)
        self.assertIn('5m', query)
        drive = commands['attempt-1/driver']
        self.assertIn(f'--use-existing-app={VM_URI}', drive)
        self.assertIn('--no-pub', drive)
        self.assertIn('--no-keep-app-running', drive)
        self.assertFalse(any(arg.startswith('--use-application-binary') for arg in drive))
        self.assertEqual(drive[-1], OWNED_UUID)
        self.assertEqual(json.loads((runner.output / 'device.json').read_text())['udid'], OWNED_UUID)
        self.assertEqual(runner.stages[-1], 'cleanup/delete')

    def test_owned_device_preserves_family_runtime_and_type_without_using_image_device(self):
        for family, template_uuid, device_type in (
                ('iPhone', PHONE_UUID, PHONE_TYPE), ('iPad', TABLET_UUID, TABLET_TYPE)):
            with self.subTest(family=family):
                runner = self.runner()
                self.assertEqual(self.acceptance(runner).run(family), 0)
                commands = {stage: command for command, stage, _, _ in runner.calls}
                create = commands['attempt-1/create-device']
                self.assertEqual(create[:3], ['xcrun', 'simctl', 'create'])
                self.assertTrue(create[3].startswith(f'getBible-acceptance-{family}-'))
                self.assertEqual(create[-2:], [device_type, RUNTIME])
                self.assertLess(runner.stages.index('build'),
                                runner.stages.index('attempt-1/create-device'))
                self.assertEqual(commands['attempt-1/boot'][-1], OWNED_UUID)
                self.assertEqual(commands['cleanup/shutdown'][-1], OWNED_UUID)
                self.assertEqual(commands['cleanup/delete'], ['xcrun', 'simctl', 'delete', OWNED_UUID])
                for command in commands.values():
                    self.assertNotIn(template_uuid, command)
                    self.assertNotIn('erase', command)
                self.assertNotIn('available', commands['available-devices'])
                metadata = json.loads((runner.output / 'device.json').read_text())
                self.assertTrue(metadata['owned'])
                self.assertEqual(metadata['template_udid'], template_uuid)
                self.assertEqual(metadata['deviceTypeIdentifier'], device_type)
                self.assertNotIn('attempt-1/host-console', runner.stages)

    def test_build_or_creation_failure_never_cleans_an_image_device(self):
        for stage, failure in (('build', 7), ('attempt-1/create-device', 8),
                               ('attempt-1/create-device', ios.StageTimeout('create-device'))):
            with self.subTest(stage=stage, failure=failure):
                runner = self.runner({stage: failure})
                with self.assertRaises((ios.CommandFailure, ios.StageTimeout)):
                    self.acceptance(runner).run('iPad')
                self.assertNotIn('attempt-1/boot', runner.stages)
                self.assertNotIn('cleanup/shutdown', runner.stages)
                self.assertNotIn('cleanup/delete', runner.stages)
                if stage == 'build':
                    self.assertNotIn('attempt-1/create-device', runner.stages)

    def test_creating_another_device_cannot_overwrite_existing_ownership(self):
        runner = self.runner()
        acceptance = self.acceptance(runner)
        acceptance.attempt = 1
        template = {'udid': TABLET_UUID, 'deviceTypeIdentifier': TABLET_TYPE}
        reserved = {TABLET_UUID}
        acceptance.create_device('iPad', RUNTIME, template, reserved)
        initial_calls = list(runner.calls)
        acceptance.attempt = 2
        with self.assertRaisesRegex(RuntimeError, 'Delete the current owned simulator'):
            acceptance.create_device('iPad', RUNTIME, template, reserved)
        self.assertEqual(runner.calls, initial_calls)
        self.assertEqual(acceptance.identifier, OWNED_UUID)
        self.assertEqual(reserved, {TABLET_UUID, OWNED_UUID})

    def test_malformed_or_preexisting_uuid_never_establishes_ownership(self):
        for value in ('', 'not-a-uuid', OWNED_UUID.replace('-', ''),
                      OWNED_UUID + '\n' + REPLACEMENT_UUID,
                      PHONE_UUID, TABLET_UUID.lower(), UNAVAILABLE_UUID):
            with self.subTest(value=value):
                runner = self.runner({'attempt-1/create-device': (value, 0)})
                with self.assertRaises(ValueError):
                    self.acceptance(runner).run('iPad')
                self.assertNotIn('attempt-1/boot', runner.stages)
                self.assertFalse(any(stage.startswith('cleanup/') for stage in runner.stages))
                self.assertFalse((runner.output / 'device.json').exists())

    def test_pre_driver_startup_stall_replaces_owned_device_once_and_reuses_build(self):
        for failed_stage in ('install', 'launch', 'vm-service/001'):
            with self.subTest(stage=failed_stage):
                runner = self.runner({f'attempt-1/{failed_stage}': ios.StageTimeout(failed_stage)})
                self.assertEqual(self.acceptance(runner).run('iPad'), 0)
                self.assertEqual(runner.stages.count('build'), 1)
                self.assertEqual(runner.stages.count('recovery/shutdown'), 1)
                self.assertEqual(runner.stages.count('recovery/delete'), 1)
                self.assertLess(runner.stages.index('attempt-1/screenshot'),
                                runner.stages.index('recovery/shutdown'))
                self.assertNotIn('attempt-1/driver', runner.stages)
                self.assertIn('attempt-2/driver', runner.stages)
                self.assertLess(runner.stages.index('recovery/delete'),
                                runner.stages.index('attempt-2/create-device'))
                commands = {stage: command for command, stage, _, _ in runner.calls}
                self.assertEqual(commands['recovery/delete'][-1], OWNED_UUID)
                self.assertEqual(commands['attempt-2/boot'][-1], REPLACEMENT_UUID)
                self.assertEqual(commands['attempt-2/driver'][-1], REPLACEMENT_UUID)
                self.assertEqual(commands['cleanup/delete'][-1], REPLACEMENT_UUID)
                self.assertEqual(commands['attempt-1/create-device'][-2:],
                                 commands['attempt-2/create-device'][-2:])

    def test_replacement_requires_confirmed_deletion_and_a_new_identifier(self):
        for outcomes in ({'recovery/delete': 9},
                         {'attempt-2/create-device': (OWNED_UUID, 0)}):
            with self.subTest(outcomes=outcomes):
                runner = self.runner({'attempt-1/launch': ios.StageTimeout('launch'), **outcomes})
                with self.assertRaises((ios.CommandFailure, ValueError)):
                    self.acceptance(runner).run('iPad')
                self.assertNotIn('attempt-2/boot', runner.stages)
                if 'recovery/delete' in outcomes:
                    self.assertNotIn('attempt-2/create-device', runner.stages)
                else:
                    self.assertNotIn('cleanup/delete', runner.stages)

    def test_failed_recovery_shutdown_still_deletes_owned_device_before_replacement(self):
        runner = self.runner({'attempt-1/launch': ios.StageTimeout('launch'),
                              'recovery/shutdown': OSError('shutdown failed')})
        self.assertEqual(self.acceptance(runner).run('iPad'), 0)
        self.assertLess(runner.stages.index('recovery/delete'),
                        runner.stages.index('attempt-2/create-device'))

    def test_cleanup_reserves_deletion_budget_despite_stalled_diagnostics_and_shutdown(self):
        runner = self.runner({'attempt-1/driver': 9}, delays={
            'attempt-1/host-console': 100, 'attempt-1/screenshot': 100,
            'attempt-1/simulator-console': 100, 'attempt-1/devices': 100,
            'cleanup/shutdown': 100, 'cleanup/delete': 100})
        with self.assertRaises(ios.CommandFailure) as caught:
            self.acceptance(runner).run('iPad')
        self.assertEqual(caught.exception.returncode, 9)
        self.assertEqual(runner.clock(), ios.CLEANUP_SECONDS)
        calls = {stage: (command, timeout, deadline)
                 for command, stage, timeout, deadline in runner.calls}
        self.assertEqual(calls['attempt-1/host-console'][0][0], '/usr/bin/log')
        self.assertEqual(calls['attempt-1/host-console'][1], 10)
        self.assertEqual(calls['attempt-1/host-console'][2], 30)
        self.assertEqual(calls['cleanup/shutdown'][2], 60)
        self.assertEqual(calls['cleanup/delete'][2], 90)
        self.assertEqual(calls['cleanup/delete'][0][-1], OWNED_UUID)

    def test_host_diagnostic_failure_preserves_failure_and_owned_deletion(self):
        for failure in (OSError('host logging unavailable'), ios.StageTimeout('host-console'), 7):
            with self.subTest(failure=failure):
                runner = self.runner({'attempt-1/driver': 9, 'attempt-1/host-console': failure})
                with self.assertRaises(ios.CommandFailure) as caught:
                    self.acceptance(runner).run('iPad')
                self.assertEqual(caught.exception.returncode, 9)
                self.assertEqual(runner.stages[-1], 'cleanup/delete')
                self.assertLess(runner.stages.index('attempt-1/host-console'),
                                runner.stages.index('attempt-1/simulator-console'))

    def test_second_startup_stall_fails_and_cleanup_still_runs(self):
        runner = self.runner({f'attempt-{number}/launch': ios.StageTimeout('launch')
                              for number in (1, 2)})
        with self.assertRaises(ios.StageTimeout):
            self.acceptance(runner).run('iPhone')
        self.assertEqual(runner.stages.count('recovery/shutdown'), 1)
        self.assertNotIn('attempt-3/driver', runner.stages)
        self.assertEqual(runner.stages[-1], 'cleanup/delete')

    def test_nonzero_stage_failures_are_never_retried(self):
        for stage in ('build', 'attempt-1/create-device', 'attempt-1/boot', 'attempt-1/bootstatus',
                      'attempt-1/install', 'attempt-1/launch',
                      'attempt-1/vm-service/001', 'attempt-1/driver'):
            with self.subTest(stage=stage):
                runner = self.runner({stage: 7})
                with self.assertRaises(ios.CommandFailure) as caught:
                    self.acceptance(runner).run('iPad')
                self.assertEqual(caught.exception.returncode, 7)
                self.assertNotIn('recovery/shutdown', runner.stages)
                if stage in ('build', 'attempt-1/create-device'):
                    self.assertNotIn('cleanup/shutdown', runner.stages)
                    self.assertNotIn('cleanup/delete', runner.stages)
                else:
                    self.assertEqual(runner.stages[-1], 'cleanup/delete')

    def test_driver_timeout_is_never_retried_even_before_host_driver_output(self):
        for message in (DRIVER_START, '', 'Unhandled exception: crash', '00:01 +0: test started'):
            with self.subTest(message=message):
                runner = self.runner({'attempt-1/driver': (message, ios.StageTimeout('driver'))})
                with self.assertRaises(ios.StageTimeout):
                    self.acceptance(runner).run('iPad')
                self.assertNotIn('recovery/shutdown', runner.stages)
                self.assertEqual(runner.stages[-1], 'cleanup/delete')

    def test_session_budget_expiry_never_starts_recovery(self):
        runner = self.runner({'attempt-1/launch': ios.StageTimeout('launch', session_expired=True)})
        with self.assertRaises(ios.StageTimeout):
            self.acceptance(runner).run('iPad')
        self.assertNotIn('recovery/shutdown', runner.stages)
        self.assertEqual(runner.stages[-1], 'cleanup/delete')

    def test_discovery_polling_shares_startup_budget_and_never_resets_deadline(self):
        runner = self.runner(query_records=[], delays={
            'attempt-1/install': 120, 'attempt-1/launch': 120,
            'attempt-2/install': 120, 'attempt-2/launch': 120})
        with self.assertRaisesRegex(ios.StageTimeout, 'discovery'):
            self.acceptance(runner).run('iPad')
        self.assertEqual(runner.clock(), 2 * ios.STARTUP_SECONDS)
        self.assertNotIn('attempt-1/driver', runner.stages)
        queries = [call for call in runner.calls if '/vm-service/' in call[1]]
        self.assertTrue(queries)
        self.assertEqual(queries[0][2], 60)
        self.assertLessEqual(max(call[2] for call in queries), 60)
        self.assertEqual(queries[-1][2], 1)

    def test_slow_log_query_uses_remaining_startup_budget_without_unnecessary_replacement(self):
        runner = self.runner(delays={'attempt-1/install': 24, 'attempt-1/launch': 31,
                                     'attempt-1/vm-service/001': 45})
        self.assertEqual(self.acceptance(runner).run('iPhone'), 0)
        query = next(call for call in runner.calls if call[1] == 'attempt-1/vm-service/001')
        self.assertEqual(query[2], ios.STARTUP_SECONDS - 24 - 31)
        self.assertEqual(runner.clock(), 100)
        self.assertNotIn('recovery/shutdown', runner.stages)
        self.assertIn('attempt-1/driver', runner.stages)

    def test_observed_cold_host_stage_costs_fit_shared_startup_budget(self):
        runner = self.runner(delays={'attempt-1/install': 123, 'attempt-1/launch': 89.5,
                                     'attempt-1/vm-service/001': 43.7})
        self.assertEqual(self.acceptance(runner).run('iPad'), 0)
        self.assertAlmostEqual(runner.clock(), 256.2)
        self.assertNotIn('recovery/shutdown', runner.stages)
        self.assertNotIn('attempt-2/create-device', runner.stages)
        calls = {stage: timeout for _, stage, timeout, _ in runner.calls}
        self.assertEqual(calls['attempt-1/install'], 300)
        self.assertEqual(calls['attempt-1/launch'], 177)
        self.assertEqual(calls['attempt-1/vm-service/001'], 87.5)
        self.assertEqual(calls['attempt-1/driver'], 180)

    def test_slow_log_query_cannot_exceed_remaining_startup_budget(self):
        runner = self.runner(delays={
            f'attempt-{attempt}/{stage}': delay
            for attempt in (1, 2)
            for stage, delay in (('install', 120), ('launch', 120), ('vm-service/001', 70))})
        with self.assertRaises(ios.StageTimeout):
            self.acceptance(runner).run('iPad')
        self.assertEqual(runner.clock(), 2 * ios.STARTUP_SECONDS)
        queries = [call for call in runner.calls if '/vm-service/' in call[1]]
        self.assertEqual([call[2] for call in queries], [60, 60])
        self.assertNotIn('attempt-1/driver', runner.stages)
        self.assertNotIn('attempt-2/driver', runner.stages)

    def test_slow_log_query_cannot_exceed_global_deadline_or_start_recovery(self):
        runner = self.runner(delays={'attempt-1/vm-service/001': 20})
        runner.deadline = 10
        with self.assertRaises(ios.StageTimeout) as caught:
            self.acceptance(runner).run('iPad')
        self.assertTrue(caught.exception.session_expired)
        self.assertEqual(runner.clock(), 10)
        query = next(call for call in runner.calls if '/vm-service/' in call[1])
        self.assertEqual(query[2], 10)
        self.assertNotIn('recovery/shutdown', runner.stages)

    def test_discovery_polling_respects_global_budget(self):
        runner = self.runner(query_records=[])
        runner.deadline = 2.5
        with self.assertRaises(ios.StageTimeout) as caught:
            self.acceptance(runner).run('iPad')
        self.assertTrue(caught.exception.session_expired)
        self.assertEqual(runner.clock(), 2.5)
        self.assertNotIn('recovery/shutdown', runner.stages)

    def test_malformed_identity_launch_or_log_output_fails_without_retry(self):
        for stage, output in (('attempt-1/launch', 'other.bundle: 123\n'),
                              ('attempt-1/launch', f'{BUNDLE}: 0\n'),
                              ('attempt-1/vm-service/001', 'not JSON')):
            with self.subTest(stage=stage, output=output):
                runner = self.runner({stage: (output, 0)})
                with self.assertRaises(ValueError):
                    self.acceptance(runner).run('iPad')
                self.assertNotIn('recovery/shutdown', runner.stages)
                self.assertNotIn('attempt-1/driver', runner.stages)
        runner = self.runner()
        with (runner.application / 'Info.plist').open('wb') as target:
            plistlib.dump({'CFBundleIdentifier': BUNDLE, 'CFBundleExecutable': '../Runner'}, target)
        with self.assertRaises(ValueError):
            self.acceptance(runner).run('iPad')
        self.assertNotIn('attempt-1/install', runner.stages)

    def test_cleanup_failures_preserve_test_failure_and_shutdown_is_attempted(self):
        runner = self.runner({'attempt-1/driver': 9,
                              'attempt-1/screenshot': ios.StageTimeout('screenshot'),
                              'attempt-1/simulator-console': OSError('simctl hung'),
                              'cleanup/shutdown': ios.StageTimeout('shutdown')})
        with self.assertRaises(ios.CommandFailure) as caught:
            self.acceptance(runner).run('iPad')
        self.assertEqual(caught.exception.returncode, 9)
        self.assertEqual(runner.stages[-1], 'cleanup/delete')
        self.assertEqual(len([event for event in runner.events
                              if event['status'] == 'diagnostic_failed']), 3)
        screenshot = next(call for call in runner.calls if call[1].endswith('/screenshot'))
        self.assertGreater(runner.calls[-1][3], screenshot[3])

    def test_zero_exit_without_driver_evidence_fails_closed(self):
        runner = self.runner({'attempt-1/driver': ('', 0)})
        with self.assertRaisesRegex(RuntimeError, 'without evidence'):
            self.acceptance(runner).run('iPad')
        self.assertNotIn('recovery/shutdown', runner.stages)

    def test_invalid_family_does_not_invoke_platform_tools(self):
        runner = self.runner()
        with self.assertRaises(ValueError):
            self.acceptance(runner).run('watch')
        self.assertEqual(runner.calls, [])


class VmServiceDiscoveryTests(unittest.TestCase):
    def setUp(self):
        self.discovery = ios.VmServiceDiscovery(10439, 'Runner', STARTED)

    def test_persisted_announcement_with_simctl_warning_needs_no_live_stream(self):
        output = 'getpwuid_r did not find a match for uid 501\n' + json.dumps([vm_record()])
        self.assertEqual(self.discovery.find(output), VM_URI)

    def test_ignores_other_pids_executables_stale_records_and_malformed_metadata(self):
        for changes in ({'processID': 10440}, {'processID': '10439'},
                        {'processImagePath': '/another/App'}, {'processImagePath': None},
                        {'timestamp': '2026-10-11 13:17:59.999+0000'},
                        {'timestamp': '2026-10-11 13:18:46'}, {'timestamp': 'invalid'},
                        {'eventMessage': None}):
            with self.subTest(changes=changes):
                self.assertIsNone(self.discovery.find(json.dumps([vm_record(**changes)])))
        self.assertEqual(self.discovery.find(json.dumps([vm_record(processID=9), vm_record()])), VM_URI)

    def test_rejects_nonlocal_unauthenticated_and_malformed_announcements(self):
        for uri in ('https://example.com:1234/auth=/', 'http://example.com:1234/auth=/',
                    'http://127.0.0.1:1234/', 'http://127.0.0.1:0/auth=/',
                    'http://127.0.0.1:99999/auth=/', 'http://127.0.0.1:port/auth=/',
                    'http://127.0.0.1/auth=/', 'http://user@127.0.0.1:1234/auth=/',
                    'http://127.0.0.1:1234/auth=/?redirect=1',
                    'http://127.0.0.1:1234/auth=/#fragment', 'http://[::1'):
            with self.subTest(uri=uri):
                record = vm_record(eventMessage=f'The Dart VM service is listening on {uri}')
                with self.assertRaises(ValueError):
                    self.discovery.find(json.dumps([record]))

    def test_accepts_authenticated_ipv6_loopback(self):
        uri = 'http://[::1]:50145/a_token-=/'
        record = vm_record(eventMessage=f'The Dart VM service is listening on {uri}')
        self.assertEqual(self.discovery.find(json.dumps([record])), uri)

    def test_malformed_structured_output_fails_explicitly(self):
        for output in ('not json', '{}', '[broken]', '[] trailing failure'):
            with self.subTest(output=output):
                with self.assertRaises(ValueError):
                    self.discovery.find(output)


class PortabilityTests(unittest.TestCase):
    def test_import_without_killpg_preserves_pure_checks_and_rejects_native_execution(self):
        spec = importlib.util.spec_from_file_location('ios_acceptance_without_posix', SOURCE)
        module = importlib.util.module_from_spec(spec)
        with patch.dict(os.__dict__):
            os.__dict__.pop('killpg', None)
            spec.loader.exec_module(module)
            discovery = module.VmServiceDiscovery(10439, 'Runner', STARTED)
            self.assertEqual(discovery.find(json.dumps([vm_record()])), VM_URI)
            with tempfile.TemporaryDirectory() as directory:
                with self.assertRaisesRegex(RuntimeError, 'POSIX host with Xcode'):
                    module.ProcessRunner(Path(directory))


class DriverProgressTests(unittest.TestCase):
    def test_large_output_chunk_cannot_hide_prior_driver_start(self):
        progress = ios.DriverProgress()
        progress.observe(DRIVER_START + 'output\n' * 10000)
        self.assertIsNotNone(progress.driver_started_at)
        self.assertLessEqual(len(progress.tail), 8192)

    def test_split_markers_and_verbose_host_driver_execution(self):
        progress = ios.DriverProgress()
        progress.observe('[+4 ms] executing: /opt/flutter/bin/cache/dart-sdk/bin/dart '
                         '--packages=.dart_tool/package_config.json test_driver/platform_')
        self.assertIsNone(progress.driver_started_at)
        progress.observe('acceptance.dart\n')
        self.assertIsNotNone(progress.driver_started_at)


if __name__ == '__main__':
    unittest.main()
