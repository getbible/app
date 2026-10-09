"""Regression tests for failed developer environments, without installing an SDK."""

import hashlib
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import bootstrap_flutter as bootstrap
import develop


class BootstrapTest(unittest.TestCase):
    def test_release_selection_never_substitutes_version_or_architecture(self):
        manifest = {
            "releases": [
                {
                    "version": "3.44.6",
                    "channel": "stable",
                    "dart_sdk_arch": "x64",
                    "archive": "stable/linux/flutter_linux_3.44.6-stable.tar.xz",
                    "sha256": "a" * 64,
                },
                {
                    "version": "3.44.6",
                    "channel": "stable",
                    "dart_sdk_arch": "arm64",
                    "archive": "stable/macos/flutter_macos_arm64_3.44.6-stable.zip",
                    "sha256": "b" * 64,
                },
            ]
        }
        self.assertEqual(
            bootstrap.select_release(manifest, "3.44.6", "arm64")["sha256"], "b" * 64
        )
        with self.assertRaisesRegex(ValueError, "No unique"):
            bootstrap.select_release(manifest, "3.44.7", "x64")

    def test_corrupted_download_is_removed_before_extraction(self):
        with tempfile.TemporaryDirectory() as directory:
            archive = Path(directory) / "flutter.tar.xz"
            with patch.object(
                bootstrap.urllib.request,
                "urlopen",
                return_value=io.BytesIO(b"truncated"),
            ):
                with self.assertRaisesRegex(ValueError, "SHA-256 mismatch"):
                    bootstrap.download_verified(
                        "https://example.invalid/sdk", archive, "a" * 64
                    )
            self.assertFalse(archive.exists())

    def test_verified_download_retains_exact_bytes(self):
        content = b"sdk-bytes\x00\xff"
        with tempfile.TemporaryDirectory() as directory:
            archive = Path(directory) / "flutter.tar.xz"
            with patch.object(
                bootstrap.urllib.request, "urlopen", return_value=io.BytesIO(content)
            ):
                bootstrap.download_verified(
                    "https://example.invalid/sdk",
                    archive,
                    hashlib.sha256(content).hexdigest(),
                )
            self.assertEqual(archive.read_bytes(), content)

    def test_existing_directory_is_never_replaced(self):
        with tempfile.TemporaryDirectory() as directory:
            marker = Path(directory) / "keep.txt"
            marker.write_text("developer data")
            with patch.object(
                bootstrap.platform, "system", return_value="Linux"
            ), patch.object(bootstrap.platform, "machine", return_value="x86_64"):
                with self.assertRaisesRegex(ValueError, "Destination exists"):
                    bootstrap.install(Path(directory))
            self.assertEqual(marker.read_text(), "developer data")


class DevelopmentDoctorTest(unittest.TestCase):
    def setUp(self):
        self.doctor = develop.DevelopmentDoctor()

    def test_missing_clang_is_detected_before_application_build(self):
        def find(name):
            return None if name == "clang++" else f"/usr/bin/{name}"

        with patch.dict(os.environ, {}, clear=True), patch.object(
            develop.platform, "system", return_value="Linux"
        ), patch.object(develop.shutil, "which", side_effect=find):
            with self.assertRaisesRegex(
                develop.DevelopmentError, "Linux tools missing: clang\\+\\+"
            ) as caught:
                self.doctor.check_linux()
            self.assertIn("apt-get install clang", str(caught.exception))

    def test_stale_compiler_override_is_not_silently_ignored(self):
        with patch.dict(os.environ, {"CXX": "/old/clang++"}), patch.object(
            develop.platform, "system", return_value="Linux"
        ), patch.object(develop.shutil, "which", return_value=None):
            with self.assertRaisesRegex(develop.DevelopmentError, "/old/clang"):
                self.doctor.check_linux()

    def test_gtk_link_failure_has_targeted_repair_command(self):
        with patch.object(
            develop.platform, "system", return_value="Linux"
        ), patch.object(
            develop.shutil, "which", return_value="/usr/bin/tool"
        ), patch.object(
            self.doctor,
            "command",
            side_effect=[
                "-I/usr/include/gtk-3.0 -lgtk-3",
                develop.DevelopmentError("cannot find -lgtk-3"),
            ],
        ):
            with self.assertRaisesRegex(
                develop.DevelopmentError, "compilation or linking failed"
            ) as caught:
                self.doctor.check_linux()
            self.assertIn("libgtk-3-dev", str(caught.exception))

    def test_flutter_snap_is_rejected_before_invoking_it(self):
        with patch.dict(
            os.environ, {"FLUTTER_ROOT": "/snap/flutter/current"}
        ), patch.object(Path, "is_file", return_value=True), patch.object(
            self.doctor, "command"
        ) as command:
            with self.assertRaisesRegex(develop.DevelopmentError, "Flutter Snap"):
                self.doctor.check_flutter()
            command.assert_not_called()

    def test_different_sdk_version_fails_with_exact_pin(self):
        with patch.dict(
            os.environ, {"FLUTTER_ROOT": "/opt/flutter", "SNAP_NAME": ""}
        ), patch.object(Path, "is_file", return_value=True), patch.object(
            self.doctor,
            "command",
            return_value=json.dumps({"frameworkVersion": "3.99.0"}),
        ):
            with self.assertRaisesRegex(
                develop.DevelopmentError, f"requires {bootstrap.pinned_version()}"
            ):
                self.doctor.check_flutter()

    def test_browser_crash_is_reported_without_disabling_sandbox(self):
        with patch.dict(os.environ, {"CHROME_EXECUTABLE": "/opt/chrome"}), patch.object(
            self.doctor,
            "command",
            side_effect=[
                "Google Chrome",
                develop.DevelopmentError("Portal operation not allowed"),
            ],
        ) as command:
            with self.assertRaisesRegex(
                develop.DevelopmentError, "sandboxed launch check"
            ) as caught:
                self.doctor.check_chrome()
            launch = command.call_args.args[0]
            self.assertNotIn("--no-sandbox", launch)
            self.assertIn("Portal operation not allowed", str(caught.exception))
            self.assertIn("run web-server", str(caught.exception))

    def test_web_check_does_not_require_linux_toolchain_or_browser(self):
        with patch.object(self.doctor, "check_flutter"), patch.object(
            self.doctor, "check_linux"
        ) as linux, patch.object(self.doctor, "check_chrome") as chrome:
            self.doctor.check("web")
            linux.assert_not_called()
            chrome.assert_not_called()

    def test_browser_timeout_remains_an_actionable_failure(self):
        with patch.object(
            develop.subprocess,
            "run",
            side_effect=subprocess.TimeoutExpired("chrome", 30),
        ):
            with self.assertRaisesRegex(
                develop.DevelopmentError, "Could not run chrome"
            ):
                self.doctor.command(["chrome"])

    def test_flutter_failure_is_returned_to_ci_or_caller(self):
        def checked(doctor, target):
            doctor.flutter = "/opt/flutter/bin/flutter"

        with patch.object(
            sys, "argv", ["develop.py", "build", "web", "--release"]
        ), patch.object(develop.DevelopmentDoctor, "check", checked), patch.object(
            develop.subprocess, "call", return_value=17
        ) as launch:
            self.assertEqual(develop.main(), 17)
            self.assertEqual(
                launch.call_args.args[0],
                ["/opt/flutter/bin/flutter", "build", "web", "--release"],
            )


if __name__ == "__main__":
    unittest.main()
