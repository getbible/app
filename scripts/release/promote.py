#!/usr/bin/env python3
"""Promote a successful main CI run's exact packages, without rebuilding.

The trusted publisher validates the source workflow and main ancestry before
reading bounded, digest-checked artifact archives. Archives contain data only;
their executables and scripts are never run. Publication remains an atomic
draft-to-release operation implemented by publish.py.
"""
from __future__ import annotations

import argparse
import base64
from datetime import datetime
import json
import os
from pathlib import Path
import re
import shutil
import stat
import sys
import tempfile
import urllib.error
import urllib.parse
import urllib.request
import zipfile

from publish import GitHub, NoRedirect, ReleaseError, REQUIRED_TARGETS, SIGNED_TARGETS
from publish import digest, publish, validate_metadata, verified_assets


WORKFLOW_PATH = ".github/workflows/ci.yml"
MAX_ARCHIVE_BYTES = 4 * 1024**3
MAX_EXPANDED_BYTES = 8 * 1024**3


class ArtifactGitHub(GitHub):
    """Authenticated API metadata with credential-free archive downloads."""

    def collection(self, path: str, key: str):
        separator = "&" if "?" in path else "?"
        for page in range(1, 101):
            response = self.call(f"{path}{separator}per_page=100&page={page}")
            values = response.get(key) if isinstance(response, dict) else None
            if not isinstance(values, list):
                raise ReleaseError(f"Invalid GitHub collection: {key}")
            yield from values
            if len(values) < 100:
                return
        raise ReleaseError(f"Too many {key} to verify safely")

    def download(self, artifact: dict, destination: Path) -> None:
        """Do not forward the GitHub token to the short-lived storage URL."""
        artifact_id = artifact["id"]
        request = urllib.request.Request(
            f"{self.base}/actions/artifacts/{artifact_id}/zip",
            headers={"Authorization": f"Bearer {self.token}", "User-Agent": "getbible-release",
                     "X-GitHub-Api-Version": "2022-11-28"},
        )
        try:
            self.opener.open(request, timeout=60).close()
        except urllib.error.HTTPError as error:
            if error.code != 302:
                raise ReleaseError(f"Artifact download request failed with HTTP {error.code}") from None
            location = error.headers.get("Location", "")
        else:
            raise ReleaseError("Artifact API did not supply its expected archive redirect")
        parsed = urllib.parse.urlsplit(location)
        if parsed.scheme != "https" or not parsed.hostname or parsed.username or parsed.password:
            raise ReleaseError("Artifact API supplied an unsafe storage URL")
        # No authorization header, cookies, redirects or executable extraction.
        opener = urllib.request.build_opener(NoRedirect())
        try:
            with opener.open(location, timeout=300) as source, destination.open("xb") as target:
                size = 0
                while chunk := source.read(1024 * 1024):
                    size += len(chunk)
                    if size > MAX_ARCHIVE_BYTES:
                        raise ReleaseError("Artifact archive exceeds the download limit")
                    target.write(chunk)
        except urllib.error.URLError:
            # Signed download URLs are credentials; never include one in logs.
            raise ReleaseError("Artifact storage download failed; retry before artifact expiry") from None


def source_run(client, run_id: int) -> dict:
    """Require successful trusted CI and a commit reachable from current main."""
    if type(run_id) is not int or run_id <= 0:
        raise ReleaseError("Source run ID must be a positive integer")
    repository = client.call("")
    workflow = client.call("/actions/workflows/ci.yml")
    run = client.call(f"/actions/runs/{run_id}")
    if not isinstance(repository, dict) or not isinstance(workflow, dict) or not isinstance(run, dict):
        raise ReleaseError("Source repository, workflow or run is unavailable")
    repository_id = repository.get("id")
    if (type(repository_id) is not int or repository_id <= 0
            or type(workflow.get("id")) is not int or workflow["id"] <= 0
            or repository.get("full_name") != client.repository or repository.get("default_branch") != "main"
            or workflow.get("path") != WORKFLOW_PATH or run.get("workflow_id") != workflow.get("id")
            or run.get("path") != WORKFLOW_PATH or run.get("id") != run_id
            or run.get("repository", {}).get("id") != repository_id
            or run.get("head_repository", {}).get("id") != repository_id
            or run.get("head_branch") != "main" or run.get("event") not in {"push", "workflow_dispatch"}
            or run.get("status") != "completed" or run.get("conclusion") != "success"):
        raise ReleaseError("Source must be this repository's successful Flutter CI run on main")
    sha = run.get("head_sha", "")
    if not re.fullmatch(r"[0-9a-f]{40}", sha):
        raise ReleaseError("Source run has an invalid commit SHA")
    comparison = client.call(f"/compare/{sha}...main")
    if (not isinstance(comparison, dict) or comparison.get("status") not in {"ahead", "identical"}
            or comparison.get("merge_base_commit", {}).get("sha") != sha):
        raise ReleaseError("Source commit is not an ancestor of current main")
    return run


def signed_targets(client, run: dict) -> set[str]:
    """Retain successful optional signing jobs; skipped targets need no keys."""
    latest = {}
    for job in client.collection(f'/actions/runs/{run["id"]}/jobs?filter=all', "jobs"):
        name = job.get("name")
        if name in {f"{target}-signed" for target in SIGNED_TARGETS}:
            if name not in latest or job["id"] > latest[name]["id"]:
                latest[name] = job
    if set(latest) != {f"{target}-signed" for target in SIGNED_TARGETS}:
        raise ReleaseError("Source CI does not declare all independent signing jobs")
    result = set()
    for name, job in latest.items():
        if job.get("status") != "completed" or job.get("conclusion") not in {"success", "skipped"}:
            raise ReleaseError("Source CI includes unsuccessful signing work")
        if job["conclusion"] == "success":
            result.add(name.removesuffix("-signed"))
    return result


def artifact_inventory(client, run: dict) -> dict[str, dict]:
    inventory = {}
    for artifact in client.collection(f'/actions/runs/{run["id"]}/artifacts', "artifacts"):
        name = artifact.get("name", "")
        if name != "release-metadata" and not name.startswith("packages-"):
            continue  # Browser traces/test reports are never release inputs.
        source = artifact.get("workflow_run", {})
        if (name in inventory or type(artifact.get("id")) is not int or artifact["id"] <= 0
                or artifact.get("expired") is not False
                or not isinstance(artifact.get("digest"), str)
                or not re.fullmatch(r"sha256:[0-9a-f]{64}", artifact["digest"])
                or type(artifact.get("size_in_bytes")) is not int
                or not 0 < artifact["size_in_bytes"] <= MAX_ARCHIVE_BYTES
                or source.get("id") != run["id"] or source.get("head_sha") != run["head_sha"]
                or source.get("head_branch") != "main"
                or source.get("repository_id") != run["repository"]["id"]
                or source.get("head_repository_id") != run["repository"]["id"]):
            raise ReleaseError("Artifact is duplicated, expired, too large or from a different source")
        inventory[name] = artifact
    if "release-metadata" not in inventory:
        raise ReleaseError("Source CI's release metadata has expired or is missing")
    return inventory


def extract_archive(archive: Path, destination: Path, *, metadata: bool = False) -> None:
    """Extract only flat regular files, with bounded count and expanded size."""
    destination.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(archive) as source:
        entries = source.infolist()
        names = [entry.filename for entry in entries]
        limit = 64 * 1024 if metadata else MAX_EXPANDED_BYTES
        if (not entries or len(entries) > 64 or len(names) != len(set(names))
                or sum(entry.file_size for entry in entries) > limit
                or (metadata and names != ["release-metadata.json"])):
            raise ReleaseError("Artifact archive has an invalid inventory or expanded size")
        for entry in entries:
            mode = entry.external_attr >> 16
            if (not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._+-]*", entry.filename)
                    or entry.is_dir() or stat.S_IFMT(mode) not in (0, stat.S_IFREG)
                    or entry.flag_bits & 1):
                raise ReleaseError("Artifact archive contains an unsafe or non-file entry")
            target = destination / entry.filename
            if target.exists() or target.is_symlink():
                raise ReleaseError("Artifact archives contain duplicate filenames")
            with source.open(entry) as data, target.open("xb") as output:
                shutil.copyfileobj(data, output, length=1024 * 1024)


def download_archive(client, artifact: dict, archive: Path) -> None:
    client.download(artifact, archive)
    if not 0 < archive.stat().st_size <= MAX_ARCHIVE_BYTES or digest(archive) != artifact["digest"].removeprefix("sha256:"):
        raise ReleaseError("Downloaded artifact does not match GitHub's SHA-256 digest")


def validate_source_metadata(client, run: dict, metadata: dict) -> None:
    validate_metadata(metadata)
    if metadata["git_sha"] != run["head_sha"]:
        raise ReleaseError("Package metadata differs from its source run commit")
    pubspec = client.call(f'/contents/pubspec.yaml?ref={run["head_sha"]}')
    if not isinstance(pubspec, dict) or pubspec.get("encoding") != "base64":
        raise ReleaseError("Cannot verify the source version in pubspec.yaml")
    content = base64.b64decode(pubspec["content"], validate=False).decode("utf-8")
    versions = re.findall(r"^version:\s*(\S+)\s*$", content, re.M)
    if versions != [metadata["version"]]:
        raise ReleaseError("Package version differs from the source pubspec.yaml")
    commit = client.call(f'/git/commits/{run["head_sha"]}')
    date = commit.get("committer", {}).get("date") if isinstance(commit, dict) else None
    if not isinstance(date, str) or int(datetime.fromisoformat(date.replace("Z", "+00:00")).timestamp()) != metadata["source_date_epoch"]:
        raise ReleaseError("Package timestamp differs from the source commit")


def promote(client, run_id: int, workspace: Path) -> str:
    run = source_run(client, run_id)
    required_signed = signed_targets(client, run)
    inventory = artifact_inventory(client, run)
    workspace.mkdir(parents=True, exist_ok=True)
    archive = workspace / "metadata.zip"
    download_archive(client, inventory.pop("release-metadata"), archive)
    extract_archive(archive, workspace / "metadata", metadata=True)
    metadata = json.loads((workspace / "metadata/release-metadata.json").read_text(encoding="utf-8"))
    validate_source_metadata(client, run, metadata)
    artifact_version = metadata["artifact_version"]
    expected = {f"packages-{target}-{artifact_version}" for target in REQUIRED_TARGETS}
    expected |= {f"packages-{target}-signed-{artifact_version}" for target in required_signed}
    if set(inventory) != expected:
        raise ReleaseError("Source run's package artifact inventory is incomplete or unexpected")
    tag = "v" + metadata["release_version"]
    existing = client.call("/releases/tags/" + urllib.parse.quote(tag, safe=""))
    if existing and not existing["draft"]:
        print(f"{tag} already published; no packages rebuilt, downloaded again or replaced.")
        return f"https://github.com/{client.repository}/releases/tag/{tag}"
    packages = workspace / "packages"
    for index, name in enumerate(sorted(inventory)):
        archive = workspace / f"package-{index}.zip"
        download_archive(client, inventory[name], archive)
        extract_archive(archive, packages)
        archive.unlink()
    verified_assets(packages, metadata, required_signed)
    # Recheck trust after potentially long downloads, before any release write.
    fresh = source_run(client, run_id)
    if fresh["head_sha"] != run["head_sha"] or fresh.get("run_attempt") != run.get("run_attempt"):
        raise ReleaseError("Source run changed while downloading; retry its completed attempt")
    publish(client, packages, metadata, required_signed, source_run_id=run_id)
    return f"https://github.com/{client.repository}/releases/tag/{tag}"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run-id", required=True)
    args = parser.parse_args()
    try:
        if (os.environ.get("GITHUB_REF") != "refs/heads/main"
                or os.environ.get("GITHUB_EVENT_NAME") not in {"workflow_run", "workflow_dispatch"}):
            raise ReleaseError("Promotion must execute from the trusted main publication workflow")
        if not re.fullmatch(r"[1-9]\d*", args.run_id):
            raise ReleaseError("Source run ID must be a positive integer")
        client = ArtifactGitHub(os.environ["GITHUB_REPOSITORY"], os.environ["GITHUB_TOKEN"])
        with tempfile.TemporaryDirectory(prefix="getbible-release-") as directory:
            url = promote(client, int(args.run_id), Path(directory))
        if summary := os.environ.get("GITHUB_STEP_SUMMARY"):
            with Path(summary).open("a", encoding="utf-8") as output:
                output.write(f"### Download tested packages\n\n[{url}]({url})\n\nSource Flutter CI run: {args.run_id}. No application rebuild was performed.\n")
        print(url)
    except (ReleaseError, OSError, ValueError, KeyError, TypeError, zipfile.BadZipFile) as error:
        print(f"Package promotion failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
