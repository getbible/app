"""Exercise publication against a stateful GitHub contract double and real files.

The double models drafts, immutable tag creation, uploads and published releases;
tests assert externally visible state rather than an exact internal call order.
"""
from __future__ import annotations

import copy
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from urllib.parse import parse_qs, unquote, urlparse


SCRIPT = Path(__file__).resolve().parents[1] / "publish.py"
SPEC = importlib.util.spec_from_file_location("release_publish", SCRIPT)
publish = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(publish)
SHA = "a" * 40


class FakeGitHub:
    """Small stateful API: callers cannot replace tags or published assets."""

    def __init__(self):
        self.records = {}
        self.refs = {}
        self.tag_objects = {}
        self.writes = []
        self.fail_upload_after = None
        self.uploads = 0
        self.corrupt_upload_response = False
        self.move_tag_during_upload = False
        self.hide_final_asset = False
        self.asset_reads = 0

    def releases(self):
        return copy.deepcopy(list(self.records.values()))

    def assets(self, release_id):
        self.asset_reads += 1
        result = copy.deepcopy(self.records[release_id]["assets"])
        if self.hide_final_asset and self.asset_reads > 1:
            return result[:-1]
        return result

    def call(self, path, *, method="GET", data=None, raw=None):
        if method != "GET":
            self.writes.append((method, path))
        if path.startswith("/releases/tags/"):
            tag = unquote(path.removeprefix("/releases/tags/"))
            return next((copy.deepcopy(value) for value in self.records.values() if value["tag_name"] == tag and not value["draft"]), None)
        if path.startswith("/git/ref/tags/"):
            tag = unquote(path.removeprefix("/git/ref/tags/"))
            return {"object": copy.deepcopy(self.refs[tag])} if tag in self.refs else None
        if path.startswith("/git/tags/"):
            return copy.deepcopy(self.tag_objects.get(path.removeprefix("/git/tags/")))
        if path == "/git/refs" and method == "POST":
            tag = data["ref"].removeprefix("refs/tags/")
            if tag in self.refs:
                raise publish.ReleaseError("Reference already exists")
            self.refs[tag] = {"type": "commit", "sha": data["sha"]}
            return {"object": self.refs[tag]}
        if path == "/releases" and method == "POST":
            release_id = max(self.records, default=0) + 1
            record = {**data, "id": release_id, "assets": [], "upload_url": f"https://uploads.github.com/releases/{release_id}/assets{{?name,label}}"}
            self.records[release_id] = copy.deepcopy(record)
            return copy.deepcopy(record)
        if path.startswith("https://uploads.github.com/"):
            if self.fail_upload_after is not None and self.uploads >= self.fail_upload_after:
                raise publish.ReleaseError("Simulated interrupted upload")
            parsed = urlparse(path)
            release_id = int(parsed.path.split("/")[2])
            record = self.records[release_id]
            if not record["draft"]:
                raise AssertionError("Attempt to modify published assets")
            name = parse_qs(parsed.query)["name"][0]
            if any(asset["name"] == name for asset in record["assets"]):
                raise AssertionError("Attempt to replace an uploaded asset")
            asset = {"id": self.uploads + 1, "name": name, "size": len(raw), "state": "uploaded", "digest": "sha256:" + hashlib.sha256(raw).hexdigest()}
            record["assets"].append(asset)
            self.uploads += 1
            if self.move_tag_during_upload:
                self.refs[record["tag_name"]] = {"type": "commit", "sha": "b" * 40}
            if self.corrupt_upload_response:
                return {**asset, "digest": "sha256:" + "0" * 64}
            return copy.deepcopy(asset)
        if path.startswith("/releases/"):
            release_id = int(path.removeprefix("/releases/"))
            if method == "PATCH":
                if not self.records[release_id]["draft"]:
                    raise AssertionError("Attempt to modify a published release")
                self.records[release_id].update(data)
            return copy.deepcopy(self.records[release_id])
        raise AssertionError(f"Unhandled API request: {method} {path}")


class PublicationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.dist = self.root / "dist"
        self.dist.mkdir()
        self.metadata = {
            "release_version": "1.0.0-beta.1", "version_name": "1.0.0",
            "build_number": 7, "version": "1.0.0-beta.1+7", "channel": "beta",
            "artifact_version": "1.0.0-beta.1-build.7", "git_sha": SHA,
            "source_date_epoch": 1791558926, "dirty": False, "schema_version": 1,
        }
        self.client = FakeGitHub()
        self.write_inventory()

    def write_inventory(self):
        for path in self.dist.iterdir():
            path.unlink()
        for target, arch, endings in (
            ("linux", "x64", (".deb", ".tar.gz")),
            ("windows", "x64", ("-portable.zip", "-setup.exe")),
            ("macos", "universal", (".app.zip", ".dmg")),
            ("ios-device", "arm64", (".app.zip",)),
            ("ios-simulator", "arm64", (".app.zip",)),
            ("android", "multiarch", ("-debug.apk", "-unsigned-release.apk", "-unsigned-release.aab")),
            ("web", "browser", (".zip",)),
        ):
            prefix = f'getbible-live-{self.metadata["artifact_version"]}-{target}-{arch}'
            files, entries = [], []
            for ending in endings:
                path = self.dist / (prefix + ending)
                path.write_bytes((target + ending).encode())
                files.append(path)
                entries.append({"file": path.name, "bytes": path.stat().st_size, "sha256": publish.digest(path), "role": "test fixture"})
            manifest = self.dist / (prefix + "-manifest.json")
            manifest.write_text(json.dumps({**self.metadata, "target": target, "architecture": arch, "distribution_signed": False, "signing": "unsigned", "installability": "test fixture", "artifacts": entries}), encoding="utf-8")
            files.append(manifest)
            (self.dist / (prefix + "-SHA256SUMS")).write_text("".join(f"{publish.digest(path)}  {path.name}\n" for path in files), encoding="utf-8")

    def prior_release(self, version="1.0.0-alpha.1", build=6):
        self.client.records[40] = {
            "id": 40, "tag_name": "v" + version, "draft": False,
            "body": f"<!-- getbible-build-number: {build} -->", "assets": [],
        }

    def draft(self, sha=SHA):
        tag = "v" + self.metadata["release_version"]
        self.client.records[1] = {
            "id": 1, "tag_name": tag, "draft": True, "target_commitish": sha,
            "body": "<!-- getbible-build-number: 7 -->", "assets": [],
            "upload_url": "https://uploads.github.com/releases/1/assets{?name,label}",
        }
        self.client.refs[tag] = {"type": "commit", "sha": sha}

    def test_semantic_order_and_noncanonical_versions(self):
        ordered = ["1.0.0-alpha.1", "1.0.0-alpha.2", "1.0.0-alpha.10", "1.0.0-beta.1", "1.0.0-rc.1", "1.0.0", "1.0.1-alpha.1", "2.0.0"]
        self.assertEqual(ordered, sorted(reversed(ordered), key=publish.version_key))
        for invalid in ("01.0.0", "1.0.0-alpha.01", "1.0.0-alpha.0", "1.0.0-dev.1"):
            with self.subTest(version=invalid), self.assertRaises(publish.ReleaseError):
                publish.version_key(invalid)

    def test_complete_release_publishes_all_assets_and_never_marks_beta_latest(self):
        self.prior_release()
        publish.publish(self.client, self.dist, self.metadata)
        record = self.client.records[41]
        self.assertFalse(record["draft"])
        self.assertTrue(record["prerelease"])
        self.assertEqual(record["make_latest"], "false")
        self.assertEqual(len(record["assets"]), len(list(self.dist.iterdir())))
        self.assertEqual(self.client.refs[record["tag_name"]]["sha"], SHA)

    def test_existing_published_release_is_never_edited_even_at_a_new_commit(self):
        publish.publish(self.client, self.dist, self.metadata)
        before = copy.deepcopy(self.client.records)
        self.client.writes.clear()
        publish.publish(self.client, self.dist, {**self.metadata, "git_sha": "b" * 40})
        self.assertEqual(self.client.records, before)
        self.assertEqual(self.client.writes, [])

    def test_build_number_must_increase_and_semver_must_advance(self):
        for version, build in (("1.0.0-alpha.1", 7), ("1.0.0-alpha.1", 8), ("1.0.0-rc.1", 5)):
            with self.subTest(version=version, build=build):
                self.client = FakeGitHub()
                self.prior_release(version, build)
                with self.assertRaises(publish.ReleaseError):
                    publish.publish(self.client, self.dist, self.metadata)
                self.assertEqual(self.client.writes, [])

    def test_tampered_package_and_missing_target_never_create_draft_or_tag(self):
        artifact = next(self.dist.glob("*.deb"))
        artifact.write_bytes(b"tampered")
        with self.assertRaises(publish.ReleaseError):
            publish.publish(self.client, self.dist, self.metadata)
        self.assertEqual(self.client.writes, [])
        self.write_inventory()
        for path in self.dist.glob("*-ios-device-*"):
            path.unlink()
        with self.assertRaisesRegex(publish.ReleaseError, "Missing required target"):
            publish.publish(self.client, self.dist, self.metadata)
        self.assertEqual(self.client.writes, [])

    def test_every_checksum_must_cover_exactly_its_packages_and_manifest(self):
        checksum = next(self.dist.glob("*-SHA256SUMS"))
        original = checksum.read_text()
        foreign = next(path for path in self.dist.glob("*-manifest.json") if path.name not in original)
        for content in ("", original.splitlines()[0] + "\n", original + original.splitlines()[0] + "\n", original + f"{publish.digest(foreign)}  {foreign.name}\n"):
            with self.subTest(content=content[:40]):
                checksum.write_text(content)
                with self.assertRaises(publish.ReleaseError):
                    publish.verified_assets(self.dist, self.metadata)
        checksum.write_text(original)
        publish.verified_assets(self.dist, self.metadata)

    def test_configured_signed_target_cannot_be_silently_omitted(self):
        with self.assertRaisesRegex(publish.ReleaseError, "Missing configured signed packages"):
            publish.publish(self.client, self.dist, self.metadata, {"ios"})
        self.assertEqual(self.client.writes, [])

    def test_interrupted_draft_resumes_without_replacing_verified_uploads(self):
        self.client.fail_upload_after = 3
        with self.assertRaisesRegex(publish.ReleaseError, "interrupted upload"):
            publish.publish(self.client, self.dist, self.metadata)
        retained = copy.deepcopy(self.client.records[1]["assets"])
        self.assertTrue(self.client.records[1]["draft"])
        self.client.fail_upload_after = None
        publish.publish(self.client, self.dist, self.metadata)
        self.assertFalse(self.client.records[1]["draft"])
        self.assertEqual(self.client.records[1]["assets"][:3], retained)
        self.assertEqual(self.client.uploads, len(list(self.dist.iterdir())))

    def test_wrong_tag_sha_or_draft_source_is_never_overwritten(self):
        for wrong_field in ("tag", "draft"):
            with self.subTest(wrong_field=wrong_field):
                self.client = FakeGitHub()
                self.draft()
                if wrong_field == "tag":
                    self.client.refs["v1.0.0-beta.1"]["sha"] = "b" * 40
                else:
                    self.client.records[1]["target_commitish"] = "b" * 40
                before = copy.deepcopy(self.client.refs)
                with self.assertRaises(publish.ReleaseError):
                    publish.publish(self.client, self.dist, self.metadata)
                self.assertEqual(self.client.refs, before)
                self.assertEqual(self.client.writes, [])

    def test_annotated_tag_resolves_to_the_exact_draft_commit(self):
        self.draft()
        self.client.refs["v1.0.0-beta.1"] = {"type": "tag", "sha": "c" * 40}
        self.client.tag_objects["c" * 40] = {"object": {"type": "commit", "sha": SHA}}
        publish.publish(self.client, self.dist, self.metadata)
        self.assertFalse(self.client.records[1]["draft"])
        self.assertEqual(self.client.refs["v1.0.0-beta.1"]["type"], "tag")

    def test_wrong_upload_digest_missing_asset_or_moved_tag_leaves_draft(self):
        for failure in ("corrupt_upload_response", "hide_final_asset", "move_tag_during_upload"):
            with self.subTest(failure=failure):
                self.client = FakeGitHub()
                setattr(self.client, failure, True)
                with self.assertRaises(publish.ReleaseError):
                    publish.publish(self.client, self.dist, self.metadata)
                self.assertTrue(self.client.records[1]["draft"])
                self.assertFalse(any(method == "PATCH" for method, _ in self.client.writes))

    def test_stable_is_latest_only_when_publication_is_explicitly_invoked(self):
        self.metadata.update(release_version="1.0.0", version="1.0.0+7", artifact_version="1.0.0-build.7", channel="stable")
        self.write_inventory()
        publish.publish(self.client, self.dist, self.metadata)
        self.assertFalse(self.client.records[1]["prerelease"])
        self.assertEqual(self.client.records[1]["make_latest"], "true")
        metadata_path = self.root / "metadata.json"
        metadata_path.write_text(json.dumps(self.metadata))
        for event, ref, sha in (("push", "refs/heads/main", SHA), ("workflow_dispatch", "refs/heads/feature", SHA), ("workflow_dispatch", "refs/heads/main", "b" * 40)):
            result = subprocess.run([
                sys.executable, str(SCRIPT), "--directory", str(self.dist), "--metadata", str(metadata_path),
            ], env={**os.environ, "GITHUB_EVENT_NAME": event, "GITHUB_REF": ref, "GITHUB_SHA": sha}, capture_output=True, text=True)
            self.assertEqual(result.returncode, 1)
            self.assertNotIn("GITHUB_TOKEN", result.stderr)


if __name__ == "__main__":
    unittest.main()
