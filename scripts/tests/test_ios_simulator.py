"""Keep iOS infrastructure recovery bounded without retrying failed journeys."""

import contextlib
import importlib.util
import io
import json
from pathlib import Path
import signal
import subprocess
import tempfile
import unittest


SOURCE = Path(__file__).resolve().parents[1] / 'testing/run_ios_acceptance.py'
SPEC = importlib.util.spec_from_file_location('ios_acceptance', SOURCE)
ios = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(ios)
VM_WAIT = 'Waiting for VM Service port to be available...\n'
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

    def test_success_drains_output_and_still_cleans_remaining_descendants(self):
        runner = self.runner(events=[(0, b'one\n'), (0.5, b'two\n')], end=0.5)
        self.assertEqual(runner.run(['command'], 'success', 2), 0)
        self.assertEqual((self.output / 'success.log').read_text(), 'one\ntwo\n')
        self.assertIn('two\n', self.console.getvalue())
        self.assertEqual(self.child.signals, [signal.SIGTERM, signal.SIGKILL])

    def test_actual_nonzero_status_is_preserved(self):
        runner = self.runner(end=0, code=17)
        self.assertEqual(runner.run(['command'], 'failed-test', 2), 17)

    def test_driver_start_changes_to_test_budget_without_resetting_on_each_line(self):
        runner = self.runner(events=[(0, DRIVER_START.encode()), (10, b'still working\n')])
        progress = ios.DriverProgress(self.clock)
        with self.assertRaises(ios.StageTimeout):
            runner.run(['flutter', 'drive'], 'driver', 1, progress=progress)
        self.assertEqual(self.clock(), progress.driver_started_at + ios.TEST_SECONDS)
        self.assertFalse(progress.retryable)

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
    def __init__(self, output, outcomes=None):
        self.output = output
        self.clock = FakeClock()
        self.deadline = ios.SESSION_SECONDS
        self.calls, self.events = [], []
        self.outcomes = outcomes or {}

    def event(self, **record):
        self.events.append(record)

    def run(self, command, stage, timeout, *, progress=None):
        self.calls.append((command, stage, timeout, self.deadline))
        path = self.output / f'{stage}.log'
        path.parent.mkdir(parents=True, exist_ok=True)
        if stage == 'available-devices':
            path.write_text(json.dumps({'devices': {
                'com.apple.CoreSimulator.SimRuntime.iOS-18-5': [
                    {'name': 'iPad Pro', 'udid': 'old', 'state': 'Shutdown', 'isAvailable': True}],
                'com.apple.CoreSimulator.SimRuntime.iOS-26-2': [
                    {'name': 'iPhone 17', 'udid': 'phone', 'state': 'Shutdown', 'isAvailable': True},
                    {'name': 'iPad mini (A17 Pro)', 'udid': 'tablet', 'state': 'Shutdown', 'isAvailable': True},
                ]}}))
        action = self.outcomes.get(stage, 0)
        if isinstance(action, tuple):
            message, action = action
            progress.observe(message)
        elif progress is not None:
            progress.observe(DRIVER_START)
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

    def runner(self, outcomes=None):
        return FakeRunner(self.output, outcomes)

    def test_build_once_then_use_exact_binary_on_selected_family(self):
        runner = self.runner()
        self.assertEqual(ios.SimulatorAcceptance(runner).run('iPad'), 0)
        self.assertEqual(runner.stages.count('build'), 1)
        build = next(command for command, stage, _, _ in runner.calls if stage == 'build')
        self.assertNotIn('--no-pub', build)
        drive = next(command for command, stage, _, _ in runner.calls if stage.endswith('/driver'))
        self.assertIn(f'--use-application-binary={ios.APPLICATION}', drive)
        self.assertIn('--no-pub', drive)
        self.assertIn('--start-paused', drive)
        self.assertEqual(drive[-1], 'tablet')
        self.assertEqual(json.loads((self.output / 'device.json').read_text())['udid'], 'tablet')
        self.assertEqual(runner.stages[-1], 'cleanup/shutdown')

    def test_only_observed_vm_stall_reboots_once_and_reuses_build(self):
        runner = self.runner({'attempt-1/driver': (VM_WAIT, ios.StageTimeout('driver'))})
        self.assertEqual(ios.SimulatorAcceptance(runner).run('iPad'), 0)
        self.assertEqual(runner.stages.count('build'), 1)
        self.assertEqual(runner.stages.count('recovery/shutdown'), 1)
        self.assertLess(runner.stages.index('attempt-1/screenshot'),
                        runner.stages.index('recovery/shutdown'))
        self.assertLess(runner.stages.index('recovery/shutdown'), runner.stages.index('attempt-2/boot'))
        self.assertIn('attempt-2/driver', runner.stages)
        self.assertIn('attempt-2/screenshot', runner.stages)

    def test_second_vm_stall_fails_and_cleanup_still_runs(self):
        runner = self.runner({f'attempt-{number}/driver': (VM_WAIT, ios.StageTimeout('driver'))
                              for number in (1, 2)})
        with self.assertRaises(ios.StageTimeout):
            ios.SimulatorAcceptance(runner).run('iPhone')
        self.assertEqual(runner.stages.count('recovery/shutdown'), 1)
        self.assertNotIn('attempt-3/driver', runner.stages)
        self.assertEqual(runner.stages[-1], 'cleanup/shutdown')

    def test_test_failure_is_never_retried(self):
        runner = self.runner({'attempt-1/driver': (VM_WAIT + DRIVER_START + 'Some tests failed', 7)})
        with self.assertRaises(ios.CommandFailure) as caught:
            ios.SimulatorAcceptance(runner).run('iPad')
        self.assertEqual(caught.exception.returncode, 7)
        self.assertNotIn('recovery/shutdown', runner.stages)
        self.assertEqual(runner.stages[-1], 'cleanup/shutdown')

    def test_no_retry_on_started_unknown_or_error_launch_timeouts(self):
        for message in (VM_WAIT + DRIVER_START, '', VM_WAIT + 'Unhandled exception: crash',
                        VM_WAIT + 'EXC_BAD_ACCESS', VM_WAIT + '00:01 +0: test started'):
            with self.subTest(message=message):
                runner = self.runner({'attempt-1/driver': (message, ios.StageTimeout('driver'))})
                with self.assertRaises(ios.StageTimeout):
                    ios.SimulatorAcceptance(runner).run('iPad')
                self.assertNotIn('recovery/shutdown', runner.stages)
                self.assertEqual(runner.stages[-1], 'cleanup/shutdown')

    def test_session_budget_expiry_never_starts_recovery(self):
        runner = self.runner({'attempt-1/driver': (
            VM_WAIT, ios.StageTimeout('driver', session_expired=True))})
        with self.assertRaises(ios.StageTimeout):
            ios.SimulatorAcceptance(runner).run('iPad')
        self.assertNotIn('recovery/shutdown', runner.stages)
        self.assertEqual(runner.stages[-1], 'cleanup/shutdown')

    def test_build_and_boot_failures_are_not_retried_and_always_cleanup(self):
        for stage in ('build', 'attempt-1/boot', 'attempt-1/bootstatus'):
            with self.subTest(stage=stage):
                runner = self.runner({stage: 5})
                with self.assertRaises(ios.CommandFailure):
                    ios.SimulatorAcceptance(runner).run('iPhone')
                self.assertNotIn('attempt-1/driver', runner.stages)
                self.assertNotIn('recovery/shutdown', runner.stages)
                self.assertEqual(runner.stages[-1], 'cleanup/shutdown')

    def test_cleanup_failures_preserve_test_failure_and_shutdown_is_attempted(self):
        runner = self.runner({'attempt-1/driver': 9,
                              'attempt-1/screenshot': ios.StageTimeout('screenshot'),
                              'attempt-1/simulator-console': OSError('simctl hung'),
                              'cleanup/shutdown': ios.StageTimeout('shutdown')})
        with self.assertRaises(ios.CommandFailure) as caught:
            ios.SimulatorAcceptance(runner).run('iPad')
        self.assertEqual(caught.exception.returncode, 9)
        self.assertEqual(runner.stages[-1], 'cleanup/shutdown')
        self.assertEqual(len([event for event in runner.events
                              if event['status'] == 'diagnostic_failed']), 3)
        screenshot = next(call for call in runner.calls if call[1].endswith('/screenshot'))
        self.assertGreater(runner.calls[-1][3], screenshot[3])

    def test_zero_exit_without_driver_evidence_fails_closed(self):
        runner = self.runner({'attempt-1/driver': ('', 0)})
        with self.assertRaisesRegex(RuntimeError, 'without evidence'):
            ios.SimulatorAcceptance(runner).run('iPad')
        self.assertNotIn('recovery/shutdown', runner.stages)

    def test_invalid_family_does_not_invoke_platform_tools(self):
        runner = self.runner()
        with self.assertRaises(ValueError):
            ios.SimulatorAcceptance(runner).run('watch')
        self.assertEqual(runner.calls, [])


class DriverProgressTests(unittest.TestCase):
    def test_large_output_chunk_cannot_hide_prior_driver_start_or_failure(self):
        for prefix in (DRIVER_START, 'Unhandled exception: test failure\n'):
            with self.subTest(prefix=prefix):
                progress = ios.DriverProgress()
                progress.observe(prefix + 'output\n' * 10000 + VM_WAIT)
                self.assertFalse(progress.retryable)
                self.assertLessEqual(len(progress.tail), 8192)

    def test_only_observed_install_launch_or_vm_wait_allows_recovery(self):
        for command in ('/usr/bin/xcrun simctl install tablet Runner.app',
                        '/usr/bin/xcrun simctl launch tablet life.getbible.mobile --start-paused'):
            with self.subTest(command=command):
                progress = ios.DriverProgress()
                progress.observe('[+5 ms] executing: ' + command + '\n')
                self.assertTrue(progress.retryable)
                progress.observe('Unable to launch life.getbible.mobile')
                self.assertFalse(progress.retryable)
        progress = ios.DriverProgress()
        progress.observe('Waiting for another flutter command to release the startup lock')
        self.assertFalse(progress.retryable)

    def test_split_markers_and_verbose_host_driver_execution(self):
        progress = ios.DriverProgress()
        progress.observe(VM_WAIT[:10])
        progress.observe(VM_WAIT[10:])
        self.assertTrue(progress.retryable)
        progress.observe('[+4 ms] executing: /opt/flutter/bin/cache/dart-sdk/bin/dart '
                         '--packages=.dart_tool/package_config.json test_driver/platform_')
        progress.observe('acceptance.dart\n')
        self.assertFalse(progress.retryable)
        self.assertIsNotNone(progress.driver_started_at)


if __name__ == '__main__':
    unittest.main()
