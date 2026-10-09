#!/usr/bin/env python3
"""Install this project's exact official Flutter SDK without changing the host."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import urllib.request

ROOT = Path(__file__).resolve().parent.parent
RELEASES = "https://storage.googleapis.com/flutter_infra_release/releases"


def pinned_version():
    version = (ROOT / ".flutter-version").read_text().strip()
    if not re.fullmatch(r"\d+\.\d+\.\d+", version):
        raise ValueError(".flutter-version must contain one stable x.y.z version")
    return version


def default_destination(version):
    cache = Path(os.environ.get("XDG_CACHE_HOME", Path.home() / ".cache"))
    return cache / "getbible" / "flutter" / version


def select_release(manifest, version, architecture):
    """Select an exact stable archive; never silently substitute a CPU or release."""
    matches = [
        release
        for release in manifest["releases"]
        if release.get("version") == version
        and release.get("channel") == "stable"
        and release.get("dart_sdk_arch", "x64") == architecture
    ]
    if len(matches) != 1:
        raise ValueError(
            f"No unique official Flutter {version} archive for {architecture}"
        )
    release = matches[0]
    archive = release["archive"]
    if ".." in Path(archive).parts or not re.fullmatch(
        r"stable/[a-z0-9_./-]+", archive
    ):
        raise ValueError("Unexpected official archive path")
    if not re.fullmatch(r"[a-f0-9]{64}", release["sha256"]):
        raise ValueError("Official archive has no valid SHA-256")
    return release


def download_verified(url, destination, expected_sha256):
    """Stream to temporary storage and reject corrupt or incomplete archives."""
    digest = hashlib.sha256()
    with urllib.request.urlopen(url, timeout=60) as response, destination.open(
        "wb"
    ) as out:
        while chunk := response.read(1024 * 1024):
            digest.update(chunk)
            out.write(chunk)
    if digest.hexdigest() != expected_sha256:
        destination.unlink()
        raise ValueError(
            "Flutter download SHA-256 mismatch; no SDK was installed. Retry the download."
        )


def install(destination):
    version = pinned_version()
    host = {"Linux": "linux", "Darwin": "macos"}.get(platform.system())
    architecture = {
        "x86_64": "x64",
        "AMD64": "x64",
        "arm64": "arm64",
        "aarch64": "arm64",
    }.get(platform.machine())
    if host is None or architecture is None:
        raise ValueError(
            "Use the matching official archive at https://docs.flutter.dev/install/archive on this host"
        )
    if destination.exists():
        # Never repair, replace or delete an SDK the developer may be using.
        executable = destination / "bin" / "flutter"
        if not executable.is_file():
            raise ValueError(
                f"Destination exists without Flutter: {destination}; choose --destination elsewhere"
            )
        result = subprocess.run(
            [str(executable), "--version", "--machine"],
            check=True,
            text=True,
            capture_output=True,
            timeout=120,
        )
        actual = json.loads(result.stdout).get("frameworkVersion")
        if actual != version:
            raise ValueError(
                f"Destination contains Flutter {actual}, expected {version}; choose --destination elsewhere"
            )
        return
    for command in ("git", "curl", "tar" if host == "linux" else "unzip"):
        if not shutil.which(command):
            raise ValueError(f"Install {command} first; see docs/LOCAL_DEVELOPMENT.md")
    with urllib.request.urlopen(
        f"{RELEASES}/releases_{host}.json", timeout=60
    ) as response:
        manifest = json.load(response)
    release = select_release(manifest, version, architecture)
    destination.parent.mkdir(parents=True, exist_ok=True)
    # A sibling staging directory keeps a partial download/extraction from being
    # selected as the usable SDK. The final rename stays on the same filesystem.
    with tempfile.TemporaryDirectory(
        prefix=".flutter-download-", dir=destination.parent
    ) as staging:
        staging = Path(staging)
        archive = staging / Path(release["archive"]).name
        print(
            f"Downloading official Flutter {version} ({host}/{architecture})...",
            flush=True,
        )
        download_verified(
            f"{RELEASES}/{release['archive']}", archive, release["sha256"]
        )
        print("SHA-256 verified; extracting...", flush=True)
        command = (
            ["tar", "-xf", str(archive), "-C", str(staging)]
            if host == "linux"
            else ["unzip", "-q", str(archive), "-d", str(staging)]
        )
        subprocess.run(command, check=True)
        extracted = staging / "flutter"
        if not (extracted / "bin" / "flutter").is_file():
            raise ValueError(
                "The verified archive did not contain a Flutter executable"
            )
        if destination.exists():
            raise ValueError(
                "Another installer created the destination; leaving it unchanged"
            )
        extracted.rename(destination)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--destination",
        type=Path,
        help="New SDK directory (default: user cache/getbible/flutter/pinned-version)",
    )
    args = parser.parse_args()
    try:
        destination = (
            (args.destination or default_destination(pinned_version()))
            .expanduser()
            .resolve()
        )
        install(destination)
        print(f"Flutter SDK: {destination}")
        print("For this terminal and your IDE, use:")
        print(f"export FLUTTER_ROOT={shlex.quote(str(destination))}")
        print('export PATH="$FLUTTER_ROOT/bin:$PATH"')
        return 0
    except (OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
        print(f"Flutter setup failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
