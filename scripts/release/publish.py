#!/usr/bin/env python3
"""Publish verified CI packages as an immutable GitHub release.

Published versions are never edited. An interrupted draft may resume at the same
commit/build, retaining verified uploads. Tags are resolved to their commit,
created without force, and checked again immediately before publication.
"""
from __future__ import annotations

import argparse
import contextlib
import hashlib
import json
import os
from pathlib import Path
import re
import sys
import urllib.error
import urllib.parse
import urllib.request


class ReleaseError(Exception):
    """Publication stopped before exposing incomplete or inconsistent packages."""


REQUIRED_TARGETS = {"linux", "windows", "macos", "ios-device", "ios-simulator", "android", "web"}
SIGNED_TARGETS = {"android", "windows", "macos", "ios"}
SUFFIXES = {
    "linux": {".tar.gz", ".deb"}, "windows": {"-portable.zip", "-setup.exe"},
    "macos": {".app.zip", ".dmg"}, "ios-device": {".app.zip"},
    "ios-simulator": {".app.zip"}, "ios-signed": {".ipa"}, "web": {".zip"},
    "android": {"-debug.apk", "-unsigned-release.apk", "-unsigned-release.aab"},
    "android-signed": {"-release.apk", "-release.aab"},
}
ARCHITECTURES = {
    "linux": {"x64", "arm64"}, "windows": {"x64"},
    "macos": {"x64", "arm64", "universal"}, "ios-device": {"arm64"},
    "ios-simulator": {"x64", "arm64", "universal"}, "ios-signed": {"arm64"},
    "android": {"multiarch"}, "android-signed": {"multiarch"}, "web": {"browser"},
}


def version_key(value: str) -> tuple[int, ...]:
    number = r"(0|[1-9]\d*)"
    match = re.fullmatch(rf"{number}\.{number}\.{number}(?:-(alpha|beta|rc)\.([1-9]\d*))?", value)
    if not match:
        raise ReleaseError(f"Unsupported release version: {value}")
    major, minor, patch, channel, sequence = match.groups()
    return (int(major), int(minor), int(patch), {"alpha": 0, "beta": 1, "rc": 2, None: 3}[channel], int(sequence or 0))


def validate_metadata(metadata: dict) -> None:
    version = metadata.get("release_version", "")
    key = version_key(version)
    build = metadata.get("build_number")
    if type(build) is not int or not 1 <= build <= 65535 or max(key[:3]) > 65535:
        raise ReleaseError("Invalid native build/version number")
    expected = {
        "schema_version": 1, "version_name": ".".join(str(value) for value in key[:3]),
        "channel": ("alpha", "beta", "rc", "stable")[key[3]], "version": f"{version}+{build}",
        "artifact_version": f"{version}-build.{build}", "dirty": False,
    }
    for name, value in expected.items():
        if metadata.get(name) != value or (name == "dirty" and metadata.get(name) is not False):
            raise ReleaseError(f"Invalid release metadata field: {name}")
    if not re.fullmatch(r"[0-9a-f]{40}", metadata.get("git_sha", "")):
        raise ReleaseError("Invalid source commit SHA")
    if type(metadata.get("source_date_epoch")) is not int or metadata["source_date_epoch"] < 0:
        raise ReleaseError("Invalid source commit timestamp")


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        # API/upload requests must not forward the token to a redirect target.
        return None


class GitHub:
    def __init__(self, repository: str, token: str):
        if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository):
            raise ReleaseError("Invalid repository")
        self.base = "https://api.github.com/repos/" + repository
        self.repository = repository
        self.token = token
        self.opener = urllib.request.build_opener(NoRedirect())

    def call(self, path, *, method="GET", data=None, raw=None):
        url = path if path.startswith("https://") else self.base + path
        parsed = urllib.parse.urlparse(url)
        if parsed.hostname not in ("api.github.com", "uploads.github.com") or parsed.scheme != "https" or parsed.username or parsed.password:
            raise ReleaseError("Unexpected GitHub API host")
        headers = {
            "Authorization": f"Bearer {self.token}", "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28", "User-Agent": "getbible-release",
            "Content-Type": "application/octet-stream" if raw is not None else "application/json",
        }
        try:
            with contextlib.ExitStack() as stack:
                if isinstance(raw, Path):
                    # Stream large platform packages instead of holding a full
                    # archive in memory. GitHub requires the exact byte length.
                    headers["Content-Length"] = str(raw.stat().st_size)
                    source = stack.enter_context(raw.open("rb"))
                    body = iter(lambda: source.read(1024 * 1024), b"")
                else:
                    body = raw if raw is not None else (json.dumps(data).encode() if data is not None else None)
                request = urllib.request.Request(url, data=body, headers=headers, method=method)
                response = stack.enter_context(self.opener.open(request, timeout=300))
                content = response.read()
                return json.loads(content) if content else None
        except urllib.error.HTTPError as error:
            if error.code == 404 and method == "GET":
                return None
            raise ReleaseError(f"GitHub {method} failed with HTTP {error.code}") from None

    def pages(self, path):
        for page in range(1, 101):
            values = self.call(f"{path}?per_page=100&page={page}")
            if not isinstance(values, list):
                raise ReleaseError(f"Invalid GitHub collection response: {path}")
            yield from values
            if len(values) < 100:
                return
        raise ReleaseError("Too many GitHub records to verify safely")

    def releases(self):
        return self.pages("/releases")

    def assets(self, release_id):
        return self.pages(f"/releases/{release_id}/assets")


def digest(path: Path) -> str:
    with path.open("rb") as file:
        return hashlib.file_digest(file, "sha256").hexdigest()


def safe_file(directory: Path, name: str) -> Path:
    if not isinstance(name, str) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._+-]*", name):
        raise ReleaseError(f"Unsafe artifact name: {name}")
    path = directory / name
    if path.is_symlink() or not path.is_file() or path.stat().st_size == 0:
        raise ReleaseError(f"Missing, empty or linked package: {name}")
    return path


def verified_assets(directory: Path, metadata: dict, required_signed=()):
    """Require exact per-target packages and checksums, including each manifest."""
    validate_metadata(metadata)
    required_signed = set(required_signed)
    if not required_signed <= SIGNED_TARGETS:
        raise ReleaseError("Unsupported required signed target")
    assets, targets, signed_targets, identities = {}, set(), set(), set()
    manifests = sorted(directory.glob("*-manifest.json"))
    for path in manifests:
        safe_file(directory, path.name)
        manifest = json.loads(path.read_text(encoding="utf-8"))
        for key, value in metadata.items():
            if manifest.get(key) != value:
                raise ReleaseError(f"{path.name}: mismatched {key}")
        target, arch, signed = manifest.get("target"), manifest.get("architecture"), manifest.get("distribution_signed")
        if target not in SUFFIXES or arch not in ARCHITECTURES[target] or type(signed) is not bool:
            raise ReleaseError(f"Invalid target/architecture/signing declaration: {path.name}")
        if target.endswith("-signed") != signed and target not in ("windows", "macos"):
            raise ReleaseError(f"Invalid signing declaration: {path.name}")
        identity = (target, arch, signed)
        if identity in identities:
            raise ReleaseError(f"Duplicate target manifest: {identity}")
        identities.add(identity)
        if target == "web":
            base = manifest.get("base_href", "")
            if not re.fullmatch(r"/(?:[A-Za-z0-9._~-]+/)*", base) or any(part in (".", "..") for part in base.split("/")):
                raise ReleaseError(f"Invalid web hosting path: {path.name}")
        if signed:
            signed_targets.add(target.removesuffix("-signed"))
        else:
            targets.add(target)
        suffix = "-signed" if signed and not target.endswith("-signed") else ""
        prefix = f'getbible-{metadata["artifact_version"]}-{target}-{arch}{suffix}'
        if path.name != prefix + "-manifest.json":
            raise ReleaseError(f"Manifest filename disagrees with its identity: {path.name}")
        expected_names = {prefix + suffix for suffix in SUFFIXES[target]}
        entries = manifest.get("artifacts")
        if not isinstance(entries, list) or len(entries) != len(expected_names):
            raise ReleaseError(f"Incomplete package list: {path.name}")
        local = {path.name: path}
        for entry in entries:
            name = entry.get("file")
            artifact = safe_file(directory, name)
            if name not in expected_names or name in local or name in assets:
                raise ReleaseError(f"Unexpected or duplicate package: {name}")
            if type(entry.get("bytes")) is not int or artifact.stat().st_size != entry["bytes"]:
                raise ReleaseError(f"Truncated package: {name}")
            if digest(artifact) != entry.get("sha256"):
                raise ReleaseError(f"Package checksum mismatch: {name}")
            local[name] = artifact
        checksum = safe_file(directory, prefix + "-SHA256SUMS")
        checked = set()
        for line in checksum.read_text(encoding="utf-8").splitlines():
            match = re.fullmatch(r"([0-9a-f]{64})  ([A-Za-z0-9][A-Za-z0-9._+-]*)", line)
            if not match:
                raise ReleaseError(f"Invalid checksum line: {checksum.name}")
            expected_digest, name = match.groups()
            if name not in local or name in checked or digest(local[name]) != expected_digest:
                raise ReleaseError(f"Unexpected, duplicate or mismatched checksum: {name}")
            checked.add(name)
        if checked != set(local):
            raise ReleaseError(f"Incomplete checksum coverage: {checksum.name}")
        local[checksum.name] = checksum
        assets.update(local)
    if not REQUIRED_TARGETS <= targets:
        raise ReleaseError("Missing required target packages: " + ", ".join(sorted(REQUIRED_TARGETS - targets)))
    if not required_signed <= signed_targets:
        raise ReleaseError("Missing configured signed packages: " + ", ".join(sorted(required_signed - signed_targets)))
    if {path.name for path in directory.iterdir()} != set(assets):
        raise ReleaseError("Package directory contains files outside the verified inventory")
    return assets, manifests


def tag_commit(client, tag: str) -> str | None:
    reference = client.call("/git/ref/tags/" + urllib.parse.quote(tag, safe=""))
    if reference is None:
        return None
    obj, seen = reference["object"], set()
    for _ in range(16):
        kind, sha = obj.get("type"), obj.get("sha")
        if not isinstance(sha, str) or not re.fullmatch(r"[0-9a-f]{40}", sha) or sha in seen:
            raise ReleaseError(f"Invalid or cyclic tag object: {tag}")
        if kind == "commit":
            return sha
        if kind != "tag":
            raise ReleaseError(f"Tag {tag} does not reference a commit")
        seen.add(sha)
        tagged = client.call("/git/tags/" + sha)
        if not tagged:
            raise ReleaseError(f"Missing annotated tag object: {tag}")
        obj = tagged["object"]
    raise ReleaseError(f"Tag {tag} has too many indirections")


def assert_source_tag(client, tag, sha):
    if tag_commit(client, tag) != sha:
        raise ReleaseError(f"Tag {tag} does not point to the verified source commit; never moved automatically")


def verify_remote_asset(asset: dict, path: Path):
    if asset.get("name") != path.name or asset.get("state") != "uploaded" or asset.get("size") != path.stat().st_size or asset.get("digest") != "sha256:" + digest(path):
        raise ReleaseError(f"GitHub asset failed size/state/SHA-256 verification: {path.name}")


def release_notes(repository: str, metadata: dict, manifests: list[Path], source_run_id: int | None) -> str:
    """Put actual installer links and platform limitations above the asset list."""
    tag = "v" + metadata["release_version"]
    root = f"https://github.com/{repository}/releases/download/{tag}/"
    downloads, files = [], {}
    def label(value):
        return str(value).replace("|", "\\|").replace("\n", " ").replace("\r", " ")
    for path in manifests:
        manifest = json.loads(path.read_text(encoding="utf-8"))
        target = manifest["target"]
        entries = manifest["artifacts"]
        links = [f'[{label(entry["role"])}]({root}{entry["file"]})' for entry in entries]
        downloads.append(f'| {target} ({manifest["architecture"]}) | {" · ".join(links)} | {label(manifest["signing"])} |')
        if not manifest["distribution_signed"]:
            files[target] = {"manifest": manifest, "names": [entry["file"] for entry in entries]}
    def filename(target, suffix):
        return next(name for name in files[target]["names"] if name.endswith(suffix))
    linux = filename("linux", ".deb")
    android = filename("android", "-debug.apk")
    simulator = filename("ios-simulator", ".app.zip")
    web = filename("web", ".zip")
    base = files["web"]["manifest"]["base_href"]
    web_directory = "preview" + base.rstrip("/")
    source = f'Build `{metadata["version"]}` from [`{metadata["git_sha"][:12]}`](https://github.com/{repository}/commit/{metadata["git_sha"]}).'
    if source_run_id is not None:
        source += f' These are the original packages from [successful Flutter CI run {source_run_id}](https://github.com/{repository}/actions/runs/{source_run_id}); they were not rebuilt for this release.'
    installation_notice = (
        '**Alpha 5 requires a clean installation.** Remove any earlier alpha and '
        'its local test data before installing getBible. For Web, clear the deployment\'s '
        'site data. This intentional development reset does not migrate old package '
        'names or databases. '
        if metadata["release_version"] == "1.0.0-alpha.5" else
        'Export a complete private backup before testing an upgrade or uninstalling. '
    )
    return (
        source + f'\n\n<!-- getbible-build-number: {metadata["build_number"]} -->\n\n'
        + installation_notice + '\n\n' +
        '## Downloads\n\n| Platform | Packages | Signing |\n|---|---|---|\n' + "\n".join(downloads) +
        '\n\nDownload the installer for your architecture. The adjacent `-SHA256SUMS` files cover '
        'every package and its manifest; compare your download before opening it. Manifests record '
        'the exact version, commit, architecture and signing state. No store submission occurs.\n\n'
        '## Install for testing\n\n'
        f'- **Linux (Debian/Ubuntu):** run `sudo apt install ./{linux}` from the download directory, '
        'then open **getBible** from Applications or run `getbible`. The `.tar.gz` is a portable '
        'Flutter bundle for compatible Linux hosts; keep its `lib/` and `data/` beside the executable. '
        'This release does not contain an AppImage.\n'
        '- **Windows:** run the `-setup.exe`. It installs for the current user and includes the required '
        'Microsoft runtime. An unsigned build may show SmartScreen; after checking this source and its '
        'checksum, use **More info → Run anyway** if your device policy allows. The portable ZIP also '
        'works when extracted as a complete folder.\n'
        '- **macOS:** open the `.dmg`, drag **getBible** into Applications, and launch it. For an '
        'unsigned test build blocked by Gatekeeper, use **System Settings → Privacy & Security → Open Anyway** '
        'after checking the download. Managed device policy may prevent an override. Prefer the signed, '
        'notarized download when available.\n'
        f'- **Android phone/tablet or emulator:** use the `-debug.apk`, for example `adb install -r {android}`. '
        'An AAB is a store-upload bundle, and an unsigned release APK cannot be installed directly. '
        'CI debug signing identities can change between runs; back up private data before replacing an '
        'installation whose signing key differs. A configured release key provides upgrade continuity.\n'
        f'- **iOS/iPadOS Simulator on macOS:** unzip the `ios-simulator` archive with '
        f'`ditto -x -k {simulator} ios-simulator`, boot a compatible Xcode Simulator, then run '
        '`xcrun simctl install booted ios-simulator/Runner.app` and '
        '`xcrun simctl launch booted life.getbible.mobile`. Match the simulator architecture. '
        'The unsigned `ios-device` bundle only validates compilation and cannot run on a physical device. '
        'An optional App Store IPA still requires TestFlight/App Store Connect distribution.\n'
        f'- **Web/Chrome:** create `{web_directory}`, extract `{web}` into it, then run '
        f'`python3 -m http.server 8000 --directory preview` and open `http://localhost:8000{base}`. '
        'Keep the packaged base path; opening `index.html` as a local file is unsupported.\n\n'
        'Store acceptance and physical-device approval are separate '
        f'from these automated build checks; see the [release checklist](https://github.com/{repository}/blob/{metadata["git_sha"]}/docs/RELEASE_CHECKLIST.md).\n'
    )


def publish(client, directory: Path, metadata: dict, required_signed=(), *, source_run_id=None):
    validate_metadata(metadata)
    version, tag = metadata["release_version"], "v" + metadata["release_version"]
    existing = client.call("/releases/tags/" + urllib.parse.quote(tag, safe=""))
    if existing and not existing["draft"]:
        print(f"{tag} already exists; published release and assets remain unchanged.")
        return
    releases = list(client.releases())
    # GitHub's release-by-tag endpoint returns published releases only. Draft
    # recovery must use the authenticated releases listing instead.
    drafts = [release for release in releases if release["tag_name"] == tag and release["draft"]]
    if len(drafts) > 1:
        raise ReleaseError("Multiple interrupted drafts use this release tag")
    if not existing and drafts:
        existing = drafts[0]
    for previous_release in releases:
        if previous_release["draft"] or not previous_release["tag_name"].startswith("v"):
            continue
        try:
            previous = version_key(previous_release["tag_name"][1:])
        except ReleaseError:
            continue
        if previous >= version_key(version):
            raise ReleaseError(f'Increment pubspec.yaml beyond published {previous_release["tag_name"]}')
        markers = re.findall(r"<!-- getbible-build-number: (\d+) -->", previous_release.get("body") or "")
        if not markers:
            raise ReleaseError(f'Published {previous_release["tag_name"]} has no recorded build number; cannot prove safe build-number progression')
        if len(markers) != 1 or int(markers[0]) >= metadata["build_number"]:
            raise ReleaseError("pubspec.yaml build number must increase across every channel")
    source_tag = tag_commit(client, tag)
    if source_tag is not None and (not existing or source_tag != metadata["git_sha"]):
        raise ReleaseError(f"Tag {tag} already exists with different or unowned release state; never moved automatically")
    assets, manifests = verified_assets(directory, metadata, required_signed)
    body = release_notes(client.repository, metadata, manifests, source_run_id)
    if existing:
        markers = re.findall(r"<!-- getbible-build-number: (\d+) -->", existing.get("body") or "")
        if existing["target_commitish"] != metadata["git_sha"] or markers != [str(metadata["build_number"])]:
            raise ReleaseError("Interrupted draft belongs to a different source commit or build")
        release = existing
    else:
        release = client.call("/releases", method="POST", data={
            "tag_name": tag, "target_commitish": metadata["git_sha"], "name": f"getBible {version}",
            "body": body, "draft": True, "prerelease": metadata["channel"] != "stable",
        })
    if tag_commit(client, tag) is None:
        client.call("/git/refs", method="POST", data={"ref": "refs/tags/" + tag, "sha": metadata["git_sha"]})
    assert_source_tag(client, tag, metadata["git_sha"])
    uploaded = {}
    for asset in client.assets(release["id"]):
        name = asset["name"]
        if name not in assets or name in uploaded:
            raise ReleaseError("Interrupted draft contains an unexpected or duplicate asset")
        verify_remote_asset(asset, assets[name])
        uploaded[name] = asset
    upload_url = release["upload_url"].split("{", 1)[0]
    for name, path in sorted(assets.items()):
        if name not in uploaded:
            asset = client.call(upload_url + "?name=" + urllib.parse.quote(name, safe=""), method="POST", raw=path)
            verify_remote_asset(asset, path)
    final_assets = list(client.assets(release["id"]))
    if len(final_assets) != len(assets) or {asset["name"] for asset in final_assets} != set(assets):
        raise ReleaseError("GitHub release asset inventory is incomplete")
    for asset in final_assets:
        verify_remote_asset(asset, assets[asset["name"]])
    assert_source_tag(client, tag, metadata["git_sha"])
    current = client.call(f'/releases/{release["id"]}')
    if not current or not current["draft"] or current["tag_name"] != tag or current["target_commitish"] != metadata["git_sha"]:
        raise ReleaseError("Draft release changed while uploading; refusing to publish")
    client.call(f'/releases/{release["id"]}', method="PATCH", data={
        "draft": False, "body": body, "prerelease": metadata["channel"] != "stable",
        "make_latest": "true" if metadata["channel"] == "stable" else "false",
    })
    print(f"Published {tag}: {len(assets)} verified package assets.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--directory", type=Path, required=True)
    parser.add_argument("--metadata", type=Path, required=True)
    parser.add_argument("--required-signed-targets", default="", help="Comma-separated configured signing targets")
    args = parser.parse_args()
    try:
        if os.environ.get("GITHUB_REF") != "refs/heads/main" or os.environ.get("GITHUB_EVENT_NAME") != "workflow_dispatch":
            raise ReleaseError("Release publication requires a manual workflow on main")
        metadata = json.loads(args.metadata.read_text(encoding="utf-8"))
        if metadata["git_sha"] != os.environ.get("GITHUB_SHA"):
            raise ReleaseError("Release source does not match the current workflow commit")
        required = set(filter(None, args.required_signed_targets.split(",")))
        publish(GitHub(os.environ["GITHUB_REPOSITORY"], os.environ["GITHUB_TOKEN"]), args.directory, metadata, required)
    except (ReleaseError, OSError, ValueError, KeyError, TypeError) as error:
        print(f"Release failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
