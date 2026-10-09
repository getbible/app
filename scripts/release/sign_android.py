#!/usr/bin/env python3
"""Run a release build with a temporary Android keystore and always remove it."""

import argparse
import base64
import binascii
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile

from signing_configuration import REQUIRED, assess


def run_signed(command):
    if os.environ.get("GITHUB_EVENT_NAME", "").startswith("pull_request"):
        raise ValueError("Android signing is disabled for pull request jobs")
    available = [name for name in REQUIRED["android"] if os.environ.get(name)]
    if not assess(available)["android"]["configured"]:
        raise ValueError("Android signing configuration is incomplete")
    try:
        key_data = base64.b64decode(
            "".join(os.environ["ANDROID_KEYSTORE_BASE64"].split()), validate=True
        )
    except (ValueError, binascii.Error) as error:
        raise ValueError("Android keystore is not valid base64") from error
    if not key_data:
        raise ValueError("Android keystore is empty")
    with tempfile.TemporaryDirectory(
        prefix="getbible-signing-", dir=os.environ.get("RUNNER_TEMP")
    ) as directory:
        keystore = Path(directory) / "upload.jks"
        with keystore.open("xb") as output:
            if os.name != "nt":
                os.fchmod(output.fileno(), 0o600)
            output.write(key_data)
        environment = os.environ.copy()
        environment["ANDROID_KEYSTORE_PATH"] = str(keystore)
        environment.pop("ANDROID_KEYSTORE_BASE64", None)
        # Passwords stay in environment variables rather than command arguments.
        return subprocess.call(command, env=environment)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not command:
        parser.error("provide a release build command after --")

    # A normal runner cancellation must unwind the temporary-keystore context.
    # SIGKILL/power loss is handled by disposal of the ephemeral CI runner.
    def interrupted(signum, frame):
        raise SystemExit(128 + signum)

    signal.signal(signal.SIGTERM, interrupted)
    try:
        return run_signed(command)
    except (OSError, ValueError):
        print(
            "Android signing setup failed; check the complete secret set and base64 keystore. Pull request signing is prohibited.",
            file=sys.stderr,
        )
        return 1
    except KeyboardInterrupt:
        return 130


if __name__ == "__main__":
    sys.exit(main())
