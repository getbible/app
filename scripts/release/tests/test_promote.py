"""Promotion boundaries with real artifact ZIPs and a stateful GitHub API double.

No Flutter build or native package execution is part of publication. Existing
package contents come from the same cross-target fixtures as publication tests.
"""
from __future__ import annotations

import base64
import copy
from datetime import datetime, timezone
import hashlib
import io
import json
from pathlib import Path
import shutil
import stat
import sys
import tempfile
import unittest
from unittest.mock import patch
import urllib.error
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import promote
import test_publish


class SourceGitHub(test_publish.FakeGitHub):
    def __init__(self, root, metadata, packages):
        super().__init__()
        self.root = root
        self.metadata = metadata
        self.downloads = []
        self.source_reads = 0
        self.change_source_after_download = False
        self.repository_record = {"id": 12, "full_name": self.repository, "default_branch": "main"}
        self.workflow = {"id": 34, "path": promote.WORKFLOW_PATH}
        self.run = {
            "id": 56, "workflow_id": 34, "path": promote.WORKFLOW_PATH,
            "repository": {"id": 12}, "head_repository": {"id": 12},
            "head_branch": "main", "event": "push", "status": "completed",
            "conclusion": "success", "head_sha": metadata["git_sha"], "run_attempt": 1,
        }
        self.comparison = {"status": "ahead", "merge_base_commit": {"sha": metadata["git_sha"]}}
        self.pubspec_version = metadata["version"]
        self.date = datetime.fromtimestamp(metadata["source_date_epoch"], timezone.utc).isoformat()
        self.jobs = [
            {"id": i + 1, "name": f"{target}-signed", "status": "completed", "conclusion": "skipped"}
            for i, target in enumerate(sorted(promote.SIGNED_TARGETS))
        ]
        self.artifacts = []
        self.archives = {}
        self.add_archive("release-metadata", {"release-metadata.json": json.dumps(metadata).encode()})
        for target in promote.REQUIRED_TARGETS:
            name = f'packages-{target}-{metadata["artifact_version"]}'
            files = {path.name: path.read_bytes() for path in packages.glob(f"*-{target}-*")}
            self.add_archive(name, files)

    def add_archive(self, name, files):
        artifact_id = len(self.artifacts) + 1
        archive = self.root / f"source-{artifact_id}.zip"
        with zipfile.ZipFile(archive, "w", compression=zipfile.ZIP_DEFLATED) as output:
            for filename, body in files.items():
                output.writestr(filename, body)
        self.archives[artifact_id] = archive
        self.artifacts.append({
            "id": artifact_id, "name": name, "expired": False,
            "size_in_bytes": archive.stat().st_size,
            "digest": "sha256:" + promote.digest(archive),
            "workflow_run": {"id": self.run["id"], "head_sha": self.run["head_sha"],
                             "head_branch": "main", "repository_id": 12, "head_repository_id": 12},
        })

    def collection(self, path, key):
        return copy.deepcopy(self.jobs if key == "jobs" else self.artifacts)

    def download(self, artifact, destination):
        self.downloads.append(artifact["name"])
        shutil.copyfile(self.archives[artifact["id"]], destination)

    def call(self, path, *, method="GET", data=None, raw=None):
        if path == "":
            return copy.deepcopy(self.repository_record)
        if path.startswith("/actions/workflows/"):
            return copy.deepcopy(self.workflow)
        if path.startswith("/actions/runs/"):
            self.source_reads += 1
            run = copy.deepcopy(self.run)
            if self.change_source_after_download and self.source_reads > 1:
                run["run_attempt"] += 1
            return run
        if path.startswith("/compare/"):
            return copy.deepcopy(self.comparison)
        if path.startswith("/contents/pubspec.yaml"):
            return {"encoding": "base64", "content": base64.b64encode(f"name: getbible\nversion: {self.pubspec_version}\n".encode()).decode()}
        if path.startswith("/git/commits/"):
            return {"committer": {"date": self.date}}
        return super().call(path, method=method, data=data, raw=raw)


class PromotionTests(unittest.TestCase):
    def setUp(self):
        fixture = test_publish.PublicationTests()
        fixture.setUp()
        self.addCleanup(fixture.doCleanups)
        self.fixture = fixture
        self.root = fixture.root
        self.client = SourceGitHub(self.root, fixture.metadata, fixture.dist)

    def promote(self):
        return promote.promote(self.client, 56, self.root / "downloaded")

    def test_success_promotes_exact_existing_bytes_with_no_signing_credentials(self):
        url = self.promote()
        self.assertEqual(url, "https://github.com/getbible/app/releases/tag/v1.0.0-beta.1")
        record = self.client.records[1]
        self.assertFalse(record["draft"])
        self.assertEqual(len(self.client.downloads), 8)
        for asset in record["assets"]:
            self.assertEqual(asset["digest"], "sha256:" + promote.digest(self.fixture.dist / asset["name"]))

    def test_forks_pull_requests_other_workflows_failed_and_incomplete_runs_cannot_publish(self):
        for field, value in (
            ("head_branch", "feature"), ("event", "pull_request"), ("event", "pull_request_target"),
            ("head_repository", {"id": 99}), ("repository", {"id": 99}),
            ("workflow_id", 99), ("path", ".github/workflows/untrusted.yml"),
            ("status", "in_progress"), ("conclusion", "failure"), ("id", 57),
        ):
            with self.subTest(field=field, value=value):
                original = self.client.run[field]
                self.client.run[field] = value
                with self.assertRaises(promote.ReleaseError):
                    self.promote()
                self.client.run[field] = original
                self.assertEqual(self.client.downloads, [])
                self.assertEqual(self.client.writes, [])

    def test_manual_successful_main_runs_can_be_promoted_after_main_advances(self):
        self.client.run["event"] = "workflow_dispatch"
        self.promote()
        self.assertFalse(self.client.records[1]["draft"])

    def test_unreachable_commit_never_downloads_or_publishes(self):
        self.client.comparison = {"status": "diverged", "merge_base_commit": {"sha": "b" * 40}}
        with self.assertRaisesRegex(promote.ReleaseError, "not an ancestor"):
            self.promote()
        self.assertEqual(self.client.downloads, [])

    def test_expired_duplicate_foreign_or_digestless_artifacts_fail_before_download(self):
        for field, value in (("expired", True), ("digest", None), ("digest", "sha256:" + "z" * 64), ("size_in_bytes", promote.MAX_ARCHIVE_BYTES + 1), ("workflow_run", {})):
            with self.subTest(field=field):
                original = self.client.artifacts[0][field]
                self.client.artifacts[0][field] = value
                with self.assertRaises((promote.ReleaseError, TypeError)):
                    self.promote()
                self.client.artifacts[0][field] = original
        self.client.artifacts.append(self.client.artifacts[0])
        with self.assertRaises(promote.ReleaseError):
            self.promote()
        self.assertEqual(self.client.downloads, [])

    def test_corrupt_archive_is_rejected_before_extraction(self):
        path = self.client.archives[1]
        path.write_bytes(path.read_bytes() + b"tampered")
        with self.assertRaisesRegex(promote.ReleaseError, "SHA-256"):
            self.promote()
        self.assertFalse((self.root / "downloaded/metadata").exists())
        self.assertEqual(self.client.writes, [])

    def test_source_pubspec_and_timestamp_must_match_metadata(self):
        self.client.pubspec_version = "1.0.0-beta.2+8"
        with self.assertRaisesRegex(promote.ReleaseError, "source pubspec"):
            self.promote()
        shutil.rmtree(self.root / "downloaded")
        self.client.pubspec_version = self.fixture.metadata["version"]
        self.client.date = "2000-01-01T00:00:00Z"
        with self.assertRaisesRegex(promote.ReleaseError, "timestamp"):
            self.promote()
        self.assertEqual(self.client.writes, [])

    def test_missing_unsigned_or_unexpected_package_artifact_is_rejected(self):
        removed = self.client.artifacts.pop()
        with self.assertRaisesRegex(promote.ReleaseError, "inventory"):
            self.promote()
        shutil.rmtree(self.root / "downloaded")
        self.client.artifacts.append(removed)
        self.client.add_archive("packages-extra-untrusted", {"unexpected.exe": b"no"})
        with self.assertRaisesRegex(promote.ReleaseError, "inventory"):
            self.promote()
        self.assertEqual(self.client.writes, [])

    def test_successful_signed_job_requires_its_signed_artifact(self):
        self.client.jobs[0]["conclusion"] = "success"
        with self.assertRaisesRegex(promote.ReleaseError, "inventory"):
            self.promote()
        self.assertEqual(self.client.writes, [])

    def test_one_available_signed_platform_publishes_with_all_other_platforms_unsigned(self):
        metadata = self.fixture.metadata
        prefix = f'getbible-{metadata["artifact_version"]}-windows-x64-signed'
        files = {prefix + suffix: b"signed fixture " + suffix.encode() for suffix in ("-setup.exe", "-portable.zip")}
        entries = [{"file": name, "bytes": len(body), "sha256": hashlib.sha256(body).hexdigest(), "role": "signed Windows package"} for name, body in files.items()]
        manifest_name = prefix + "-manifest.json"
        files[manifest_name] = json.dumps({**metadata, "target": "windows", "architecture": "x64", "distribution_signed": True,
                                          "signing": "Authenticode signed", "installability": "desktop installation", "artifacts": entries}).encode()
        files[prefix + "-SHA256SUMS"] = "".join(f"{hashlib.sha256(body).hexdigest()}  {name}\n" for name, body in files.items()).encode()
        self.client.add_archive(f'packages-windows-signed-{metadata["artifact_version"]}', files)
        next(job for job in self.client.jobs if job["name"] == "windows-signed")["conclusion"] = "success"
        self.promote()
        record = self.client.records[1]
        self.assertFalse(record["draft"])
        self.assertTrue(any(asset["name"] == prefix + "-setup.exe" for asset in record["assets"]))
        self.assertIn("Authenticode signed", record["body"])
        self.assertEqual(len(record["assets"]), 30)

    def test_rerun_selects_latest_signing_state_and_does_not_hide_failed_signing(self):
        self.client.jobs.append({**self.client.jobs[0], "id": 500, "conclusion": "failure"})
        with self.assertRaisesRegex(promote.ReleaseError, "unsuccessful signing"):
            self.promote()
        self.assertEqual(self.client.writes, [])

    def test_test_reports_are_ignored_and_never_uploaded(self):
        self.client.artifacts.append({"name": "browser-smoke", "expired": True})
        self.promote()
        self.assertNotIn("browser-smoke", self.client.downloads)

    def test_published_version_skips_large_downloads_and_never_changes_assets(self):
        self.fixture.client = self.client
        test_publish.publish.publish(self.client, self.fixture.dist, self.fixture.metadata)
        before = copy.deepcopy(self.client.records)
        self.client.writes.clear()
        self.promote()
        self.assertEqual(self.client.records, before)
        self.assertEqual(self.client.downloads, ["release-metadata"])
        self.assertEqual(self.client.writes, [])

    def test_run_changed_during_download_does_not_create_a_release(self):
        self.client.change_source_after_download = True
        with self.assertRaisesRegex(promote.ReleaseError, "run changed"):
            self.promote()
        self.assertEqual(self.client.writes, [])

    def test_zip_slip_symlinks_directories_duplicate_and_oversized_files_rejected(self):
        for index, (name, mode) in enumerate((("../outside", 0), ("/absolute", 0), ("folder/file", 0), ("link", stat.S_IFLNK | 0o777), ("folder/", stat.S_IFDIR | 0o755))):
            archive = self.root / f"unsafe-{index}.zip"
            with zipfile.ZipFile(archive, "w") as output:
                entry = zipfile.ZipInfo(name)
                entry.external_attr = mode << 16
                output.writestr(entry, "unsafe")
            with self.subTest(name=name), self.assertRaises(promote.ReleaseError):
                promote.extract_archive(archive, self.root / f"unsafe-{index}")
        archive = self.root / "oversized.zip"
        with zipfile.ZipFile(archive, "w") as output:
            output.writestr("release-metadata.json", b"x" * (64 * 1024 + 1))
        with self.assertRaisesRegex(promote.ReleaseError, "expanded size"):
            promote.extract_archive(archive, self.root / "oversized", metadata=True)


class TransportTests(unittest.TestCase):
    def test_signed_storage_download_never_receives_github_credentials(self):
        client = promote.ArtifactGitHub("getbible/app", "secret-not-for-storage")
        archive = b"small archive fixture"
        redirect = urllib.error.HTTPError("https://api.github.com/", 302, "Found", {"Location": "https://signed.example.invalid/archive?secret=temporary"}, None)
        with tempfile.TemporaryDirectory() as directory, patch.object(client.opener, "open", side_effect=redirect) as api, patch.object(promote.urllib.request, "build_opener") as storage:
            storage.return_value.open.return_value.__enter__.return_value = io.BytesIO(archive)
            client.download({"id": 8}, Path(directory) / "artifact.zip")
            self.assertEqual(api.call_args.args[0].get_header("Authorization"), "Bearer secret-not-for-storage")
            self.assertEqual(storage.return_value.open.call_args.args, ("https://signed.example.invalid/archive?secret=temporary",))

    def test_upload_stream_has_content_length_and_preserves_every_byte(self):
        client = promote.GitHub("getbible/app", "private-token")
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "large.zip"
            path.write_bytes(b"\x00\n\xff" * 900000)
            def open_request(request, **kwargs):
                self.assertEqual(request.get_header("Content-length"), str(path.stat().st_size))
                self.assertNotIsInstance(request.data, bytes)
                self.assertEqual(hashlib.sha256(b"".join(request.data)).hexdigest(), promote.digest(path))
                return io.BytesIO(b'{"id": 1}')
            with patch.object(client.opener, "open", side_effect=open_request):
                self.assertEqual(client.call("https://uploads.github.com/upload", method="POST", raw=path), {"id": 1})


if __name__ == "__main__":
    unittest.main()
