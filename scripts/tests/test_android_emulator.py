"""Guard recovery boundaries for the native Android acceptance environment."""

import importlib.util
from pathlib import Path
import tempfile
import unittest


SOURCE = Path(__file__).resolve().parents[1] / "testing/prepare_android_emulator.py"
SPEC = importlib.util.spec_from_file_location("android_readiness", SOURCE)
readiness = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(readiness)
LAUNCHER = "com.google.android.apps.nexuslauncher"
HOME = f"{LAUNCHER}/{LAUNCHER}.NexusLauncherActivity"
LAUNCHER_ANR = f"Application Not Responding: {LAUNCHER}"


def window(title):
    focus = "null" if title is None else f"Window{{9351e59 u0 {title}}}"
    return f"WINDOW MANAGER WINDOWS\n  mCurrentFocus={focus}\n"


class FakeDevice:
    def __init__(self, focuses, *, launcher=HOME):
        self.focuses = list(focuses)
        self.launcher = launcher
        self.calls = []

    def command(self, *arguments):
        self.calls.append(arguments)
        if arguments[:4] == ("shell", "cmd", "package", "resolve-activity"):
            return self.launcher
        if arguments == ("shell", "dumpsys", "window"):
            if len(self.focuses) > 1:
                return window(self.focuses.pop(0))
            return window(self.focuses[0])
        if arguments == ("logcat", "-b", "all", "-d"):
            return "Observed launcher boot ANR before app launch."
        return ""

    def screenshot(self, path):
        self.calls.append(("screenshot",))
        path.write_bytes(b"retained screenshot")

    @property
    def stopped_packages(self):
        return [call[-1] for call in self.calls
                if call[:3] == ("shell", "am", "force-stop")]


class EmulatorReadinessTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.output = Path(self.directory.name)
        self.now = 0

    def prepare(self, device):
        def pause(seconds):
            self.now += seconds
        readiness.EmulatorReadiness(
            device, self.output, timeout=2, clock=lambda: self.now, pause=pause,
        ).prepare()

    def test_healthy_home_preserves_process_and_records_native_focus(self):
        device = FakeDevice([HOME, HOME, HOME])
        self.prepare(device)
        self.assertEqual(device.stopped_packages, [])
        self.assertIn(HOME, (self.output / "window-ready-for-launch.txt").read_text())

    def test_known_boot_launcher_anr_is_captured_then_recovered_once(self):
        device = FakeDevice([LAUNCHER_ANR, None, HOME, HOME])
        self.prepare(device)
        self.assertEqual(device.stopped_packages, [LAUNCHER])
        self.assertLess(device.calls.index(("screenshot",)),
                        device.calls.index(("shell", "am", "force-stop", LAUNCHER)))
        self.assertIn(LAUNCHER_ANR, (self.output / "window-before-readiness.txt").read_text())
        self.assertTrue((self.output / "launcher-anr-before-recovery.png").exists())
        self.assertTrue((self.output / "launcher-anr-logcat.txt").exists())

    def test_getbible_or_other_system_errors_fail_without_dismissal(self):
        for dialog in ("Application Not Responding: life.getbible.mobile",
                       "Application Not Responding: com.android.systemui",
                       f"Application Error: {LAUNCHER}"):
            with self.subTest(dialog=dialog):
                device = FakeDevice([dialog])
                with self.assertRaisesRegex(readiness.EmulatorReadinessError,
                                            "system error dialog"):
                    self.prepare(device)
                self.assertEqual(device.stopped_packages, [])

    def test_recovery_requires_the_known_package_to_be_the_resolved_home(self):
        device = FakeDevice([LAUNCHER_ANR], launcher="other.launcher/.Home")
        with self.assertRaises(readiness.EmulatorReadinessError):
            self.prepare(device)
        self.assertEqual(device.stopped_packages, [])

    def test_reappearing_launcher_anr_fails_without_recovery_loop(self):
        device = FakeDevice([LAUNCHER_ANR, LAUNCHER_ANR])
        with self.assertRaises(readiness.EmulatorReadinessError):
            self.prepare(device)
        self.assertEqual(device.stopped_packages, [LAUNCHER])

    def test_transient_home_focus_is_not_enough_and_wait_is_bounded(self):
        device = FakeDevice([None, HOME, None])
        with self.assertRaisesRegex(readiness.EmulatorReadinessError, "stable input focus"):
            self.prepare(device)
        self.assertEqual(self.now, 2)
        self.assertEqual(device.stopped_packages, [])

    def test_historical_anr_does_not_override_current_native_focus(self):
        dump = ("WINDOW MANAGER LAST ANR\n"
                f"  Display #0 currentFocus=Window{{old u0 {LAUNCHER_ANR}}}\n"
                + window(HOME))
        self.assertEqual(readiness.current_window(dump), HOME)

    def test_unrecognized_device_output_fails_closed(self):
        for dump in ("", "mCurrentFocus=unknown", window(HOME) + window(HOME)):
            with self.subTest(dump=dump):
                with self.assertRaises(readiness.EmulatorReadinessError):
                    readiness.current_window(dump)
        self.assertEqual(readiness.home_component(f"{LAUNCHER}/.NexusLauncherActivity"),
                         (LAUNCHER, HOME))
        with self.assertRaises(readiness.EmulatorReadinessError):
            readiness.home_component("No activity found")


if __name__ == "__main__":
    unittest.main()
