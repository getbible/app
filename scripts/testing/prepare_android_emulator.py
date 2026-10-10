#!/usr/bin/env python3
"""Require a usable native HOME window before starting Android acceptance.

API 35's Pixel Launcher can show an ANR during emulator boot. A resumed test
activity behind that system dialog cannot read Android's clipboard. Preserve
the evidence and recover that specific boot failure once; never dismiss an
application ANR or turn a failed clipboard assertion into a retry.
"""

import argparse
from pathlib import Path
import re
import subprocess
import time


RECOVERABLE_LAUNCHER = "com.google.android.apps.nexuslauncher"
COMPONENT = re.compile(r"[A-Za-z0-9_.]+/[A-Za-z0-9_.$]+")


class EmulatorReadinessError(RuntimeError):
    """The dedicated emulator cannot provide a healthy foreground window."""


def current_window(dump):
    """Read current focus, not the historical last-ANR section of dumpsys."""
    matches = re.findall(r"^\s*mCurrentFocus=(.+)$", dump, flags=re.MULTILINE)
    if len(matches) != 1:
        raise EmulatorReadinessError("Expected one current Android focus record.")
    match = re.fullmatch(r"Window\{\S+ u\d+ (.+)\}", matches[0].strip())
    if match:
        return match[1]
    if matches[0].strip() == "null":
        return None
    raise EmulatorReadinessError("Unrecognized Android current-focus record.")


def home_component(response):
    candidates = [line.strip() for line in response.splitlines()
                  if COMPONENT.fullmatch(line.strip())]
    if len(candidates) != 1:
        raise EmulatorReadinessError("Could not resolve one Android HOME activity.")
    package, activity = candidates[0].split("/")
    if activity.startswith("."):
        activity = package + activity
    return package, f"{package}/{activity}"


class AdbDevice:
    def __init__(self, serial):
        self.prefix = ["adb", "-s", serial]

    def command(self, *arguments):
        return subprocess.check_output(
            [*self.prefix, *arguments], text=True, stderr=subprocess.STDOUT,
            timeout=15,
        )

    def screenshot(self, path):
        with path.open("wb") as image:
            subprocess.run(
                [*self.prefix, "exec-out", "screencap", "-p"], stdout=image,
                check=True, timeout=15,
            )


class EmulatorReadiness:
    def __init__(self, device, output, *, timeout=30,
                 clock=time.monotonic, pause=time.sleep):
        self.device = device
        self.output = output
        self.timeout = timeout
        self.clock = clock
        self.pause = pause

    def prepare(self):
        self.output.mkdir(parents=True, exist_ok=True)
        package, home = home_component(self.device.command(
            "shell", "cmd", "package", "resolve-activity", "--brief",
            "-a", "android.intent.action.MAIN",
            "-c", "android.intent.category.HOME",
        ))
        dump = self.device.command("shell", "dumpsys", "window")
        (self.output / "window-before-readiness.txt").write_text(dump)
        focus = current_window(dump)
        recovered = False

        def reject_error(window):
            if window and (window.startswith("Application Not Responding:") or
                           window.startswith("Application Error:")):
                raise EmulatorReadinessError(
                    f"Android system error dialog prevents acceptance: {window}"
                )

        if (package == RECOVERABLE_LAUNCHER and
                focus == f"Application Not Responding: {package}"):
            # Save proof before altering this dedicated test device. Do not
            # disable ANR dialogs globally or recover any other package.
            self.device.screenshot(self.output / "launcher-anr-before-recovery.png")
            (self.output / "launcher-anr-logcat.txt").write_text(
                self.device.command("logcat", "-b", "all", "-d"))
            print(f"Recovering observed boot ANR for {package} once.", flush=True)
            self.device.command("shell", "am", "force-stop", package)
            recovered = True
        else:
            reject_error(focus)

        # Native focus, rather than Activity lifecycle, is the readiness signal.
        self.device.command("shell", "am", "start", "-W", "-n", home,
                            "-a", "android.intent.action.MAIN",
                            "-c", "android.intent.category.HOME")
        deadline = self.clock() + self.timeout
        stable = 0
        while True:
            dump = self.device.command("shell", "dumpsys", "window")
            (self.output / "window-ready-for-launch.txt").write_text(dump)
            focus = current_window(dump)
            reject_error(focus)
            stable = stable + 1 if focus == home else 0
            if stable == 2:
                print(f"Android HOME has native input focus: {home}; "
                      f"launcher recovery={recovered}.", flush=True)
                return
            if self.clock() >= deadline:
                raise EmulatorReadinessError(
                    f"Android HOME did not obtain stable input focus; current={focus!r}"
                )
            self.pause(0.5)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--device", default="emulator-5554")
    parser.add_argument("--output", type=Path, default=Path("build/runtime-evidence"))
    args = parser.parse_args()
    EmulatorReadiness(AdbDevice(args.device), args.output).prepare()


if __name__ == "__main__":
    main()
