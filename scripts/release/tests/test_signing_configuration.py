"""Signing availability and private-key lifecycle regression tests."""

import base64
import contextlib
import io
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import sign_android
import signing_configuration as configuration


class SigningConfigurationTest(unittest.TestCase):
    def test_partial_credentials_disable_only_the_incomplete_target(self):
        names = [*configuration.REQUIRED["windows"], "ANDROID_KEYSTORE_BASE64"]
        report = configuration.assess(names)
        self.assertTrue(report["windows"]["configured"])
        self.assertFalse(report["android"]["configured"])
        self.assertIn("ANDROID_KEY_PASSWORD", report["android"]["missing"])

    def test_secret_and_variable_metadata_need_no_values(self):
        names = configuration.REQUIRED["macos"]
        metadata = {
            "secrets": [{"name": name} for name in names[:3]],
            "variables": [{"name": name} for name in names[3:]],
        }
        self.assertTrue(
            configuration.assess(configuration.metadata_names(metadata))["macos"][
                "configured"
            ]
        )

    def test_values_are_never_printed_by_the_checker(self):
        output = io.StringIO()
        secret = "PRIVATE-VALUE-DO-NOT-PRINT"
        with patch.dict(
            os.environ,
            dict.fromkeys(configuration.REQUIRED["android"], secret),
            clear=True,
        ), patch.object(
            sys, "argv", ["signing_configuration.py", "--require", "android"]
        ), contextlib.redirect_stdout(
            output
        ):
            self.assertEqual(configuration.main(), 0)
        self.assertNotIn(secret, output.getvalue())
        self.assertTrue(json.loads(output.getvalue())["android"]["configured"])

    def test_require_fails_without_credentials(self):
        with patch.dict(os.environ, {}, clear=True), patch.object(
            sys, "argv", ["signing_configuration.py", "--require", "windows"]
        ), contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(configuration.main(), 1)

    def test_github_outputs_contain_only_boolean_readiness(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "github-output"
            with patch.dict(
                os.environ, {"GITHUB_OUTPUT": str(output)}, clear=True
            ), patch.object(
                sys, "argv", ["signing_configuration.py", "--github-output"]
            ), contextlib.redirect_stdout(
                io.StringIO()
            ):
                self.assertEqual(configuration.main(), 0)
            self.assertIn("windows_signing=false\n", output.read_text())


class AndroidSigningTest(unittest.TestCase):
    def environment(self):
        return {
            "ANDROID_KEYSTORE_BASE64": base64.b64encode(
                b"private-key-fixture"
            ).decode(),
            "ANDROID_KEYSTORE_PASSWORD": "store-secret",
            "ANDROID_KEY_ALIAS": "upload",
            "ANDROID_KEY_PASSWORD": "key-secret",
        }

    def test_failed_build_removes_private_file_and_preserves_exit_code(self):
        paths = []

        def failed(command, env):
            keystore = Path(env["ANDROID_KEYSTORE_PATH"])
            paths.append(keystore)
            self.assertEqual(keystore.read_bytes(), b"private-key-fixture")
            self.assertNotIn("ANDROID_KEYSTORE_BASE64", env)
            self.assertEqual(command, ["flutter", "build", "apk"])
            if os.name != "nt":
                self.assertEqual(keystore.stat().st_mode & 0o777, 0o600)
            return 23

        with patch.dict(os.environ, self.environment(), clear=True), patch.object(
            sign_android.subprocess, "call", side_effect=failed
        ):
            self.assertEqual(sign_android.run_signed(["flutter", "build", "apk"]), 23)
        self.assertFalse(paths[0].exists())
        self.assertFalse(paths[0].parent.exists())

    def test_process_launch_exception_still_removes_private_file(self):
        paths = []

        def missing(command, env):
            paths.append(Path(env["ANDROID_KEYSTORE_PATH"]))
            raise OSError("flutter missing")

        with patch.dict(os.environ, self.environment(), clear=True), patch.object(
            sign_android.subprocess, "call", side_effect=missing
        ):
            with self.assertRaises(OSError):
                sign_android.run_signed(["flutter"])
        self.assertFalse(paths[0].parent.exists())

    def test_pull_request_and_pull_request_target_cannot_sign(self):
        for event in ("pull_request", "pull_request_target"):
            with self.subTest(event=event), patch.dict(
                os.environ,
                {**self.environment(), "GITHUB_EVENT_NAME": event},
                clear=True,
            ), patch.object(sign_android.subprocess, "call") as run:
                with self.assertRaisesRegex(ValueError, "pull request"):
                    sign_android.run_signed(["flutter"])
                run.assert_not_called()

    def test_invalid_base64_is_rejected_before_build(self):
        with patch.dict(
            os.environ,
            {**self.environment(), "ANDROID_KEYSTORE_BASE64": "invalid!!"},
            clear=True,
        ), patch.object(sign_android.subprocess, "call") as run:
            with self.assertRaisesRegex(ValueError, "base64"):
                sign_android.run_signed(["flutter"])
            run.assert_not_called()


if __name__ == "__main__":
    unittest.main()
