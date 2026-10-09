#!/usr/bin/env python3
"""Check Linux/browser prerequisites before running the pinned Flutter SDK."""

import argparse
import json
import os
from pathlib import Path
import platform
import shlex
import shutil
import subprocess
import sys
import tempfile

from bootstrap_flutter import ROOT, default_destination, pinned_version

LINUX_INSTALL = (
    "sudo apt-get install clang cmake ninja-build pkg-config libgtk-3-dev g++"
)


class DevelopmentError(Exception):
    """An actionable host setup failure, before application compilation."""


class DevelopmentDoctor:
    """Validate the selected target without requiring unrelated platform SDKs."""

    def __init__(self):
        self.flutter = None

    def command(self, arguments, timeout=30):
        try:
            result = subprocess.run(
                arguments, text=True, capture_output=True, timeout=timeout
            )
        except (OSError, subprocess.TimeoutExpired) as error:
            raise DevelopmentError(f"Could not run {arguments[0]}: {error}") from error
        if result.returncode:
            output = (result.stderr + result.stdout).strip()
            raise DevelopmentError(
                f"{arguments[0]} exited {result.returncode}:\n{output[-5000:]}"
            )
        return result.stdout

    def check_flutter(self):
        version = pinned_version()
        explicit = os.environ.get("FLUTTER_ROOT")
        cached = default_destination(version) / "bin" / "flutter"
        found = (
            str(Path(explicit).expanduser() / "bin" / "flutter")
            if explicit
            else (str(cached) if cached.is_file() else shutil.which("flutter"))
        )
        if not found or not Path(found).is_file():
            raise DevelopmentError(
                "Flutter SDK not found. Run: python3 scripts/bootstrap_flutter.py"
            )
        executable = Path(found).resolve()
        if (
            "/snap/" in str(Path(found).absolute())
            or "/snap/" in str(executable)
            or os.environ.get("SNAP_NAME") == "flutter"
        ):
            raise DevelopmentError(
                "Flutter Snap selected. Use the pinned official SDK with python3 scripts/bootstrap_flutter.py, then run from a normal host terminal. See docs/LOCAL_DEVELOPMENT.md."
            )
        self.flutter = str(executable)
        try:
            actual = json.loads(
                self.command([self.flutter, "--version", "--machine"], timeout=120)
            )["frameworkVersion"]
        except (ValueError, KeyError) as error:
            raise DevelopmentError(
                "Flutter could not report its SDK version; repair the SDK installation"
            ) from error
        if actual != version:
            raise DevelopmentError(
                f"Flutter {actual} selected; this checkout requires {version}. Run python3 scripts/bootstrap_flutter.py and select its SDK in the IDE."
            )
        print(f"Flutter {actual}: {self.flutter}", flush=True)

    def check_linux(self):
        if platform.system() != "Linux":
            raise DevelopmentError("Build/run the Linux target on a Linux host")
        # Respect an explicit compiler, but never interpret environment text as shell code.
        compiler = shlex.split(os.environ.get("CXX") or "clang++")
        if not compiler:
            raise DevelopmentError("CXX is empty; unset CXX to select clang++")
        missing = [
            item
            for item in (compiler[0], "cmake", "ninja", "pkg-config")
            if not shutil.which(item)
        ]
        if missing:
            raise DevelopmentError(
                f"Linux tools missing: {', '.join(missing)}. On Ubuntu/Debian run:\n{LINUX_INSTALL}\nIf CXX points to an old compiler, correct it or unset CXX."
            )
        try:
            flags = shlex.split(
                self.command(["pkg-config", "--cflags", "--libs", "gtk+-3.0"])
            )
            with tempfile.TemporaryDirectory(prefix="getbible-toolchain-") as directory:
                source = Path(directory) / "probe.cpp"
                source.write_text(
                    '#include <gtk/gtk.h>\n#include <string>\nint main(int argc, char** argv) { std::string name("getBible"); gtk_init(&argc, &argv); return name.empty(); }\n'
                )
                self.command(
                    [
                        *compiler,
                        str(source),
                        "-o",
                        str(Path(directory) / "probe"),
                        *flags,
                    ]
                )
        except DevelopmentError as error:
            raise DevelopmentError(
                f"Linux C++/GTK compilation or linking failed:\n{error}\nInstall the host development libraries:\n{LINUX_INSTALL}"
            ) from error
        print("Linux C++/GTK compile and link: passed", flush=True)

    def check_chrome(self):
        chrome = os.environ.get("CHROME_EXECUTABLE")
        if not chrome:
            chrome = next(
                (
                    path
                    for name in (
                        "google-chrome",
                        "google-chrome-stable",
                        "chromium",
                        "chromium-browser",
                    )
                    if (path := shutil.which(name))
                ),
                None,
            )
        if not chrome:
            raise DevelopmentError(
                "Chrome not found. Install Google Chrome or set CHROME_EXECUTABLE to its executable. To use an already open browser: python3 scripts/develop.py run web-server"
            )
        try:
            self.command([chrome, "--version"])
            with tempfile.TemporaryDirectory(prefix="getbible-chrome-") as profile:
                document = self.command(
                    [
                        chrome,
                        "--headless",
                        f"--user-data-dir={profile}",
                        "--no-first-run",
                        "--no-default-browser-check",
                        "--dump-dom",
                        "about:blank",
                    ],
                    timeout=30,
                )
                if "<html" not in document.lower():
                    raise DevelopmentError(
                        "Chrome exited without rendering the blank test document"
                    )
        except DevelopmentError as error:
            raise DevelopmentError(
                f"Chrome failed its sandboxed launch check:\n{error}\nUse a normal host terminal and the official Flutter SDK. Check Chrome opens independently; keep its sandbox enabled. For manual browser launching use: python3 scripts/develop.py run web-server\nSee docs/LOCAL_DEVELOPMENT.md for the Snap/portal diagnosis."
            ) from error
        os.environ["CHROME_EXECUTABLE"] = chrome
        print(f"Chrome sandboxed headless launch: passed ({chrome})", flush=True)

    def check(self, target):
        self.check_flutter()
        if target == "linux":
            self.check_linux()
        elif target == "chrome":
            self.check_chrome()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("check", "run", "build"))
    parser.add_argument("target", choices=("linux", "chrome", "web", "web-server"))
    parser.add_argument("flutter_args", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    if args.action == "check" and args.flutter_args:
        parser.error("check accepts no additional Flutter arguments")
    doctor = DevelopmentDoctor()
    try:
        # Compiling static web assets does not require a browser or Linux GTK.
        doctor.check(
            "web" if args.action == "build" and args.target != "linux" else args.target
        )
        if args.action == "check":
            return 0
        if args.action == "run":
            target = "web-server" if args.target == "web" else args.target
            command = [doctor.flutter, "run", "-d", target]
        else:
            command = [
                doctor.flutter,
                "build",
                "linux" if args.target == "linux" else "web",
            ]
        extras = (
            args.flutter_args[1:]
            if args.flutter_args[:1] == ["--"]
            else args.flutter_args
        )
        return subprocess.call([*command, *extras], cwd=ROOT)
    except (DevelopmentError, OSError, ValueError) as error:
        print(f"Development check failed: {error}", file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        return 130


if __name__ == "__main__":
    sys.exit(main())
