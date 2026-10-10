"""Packaging contract tests; native launch tests run separately in CI.

The Linux test executes the real Debian tools against a small ELF fixture. It
does not pretend that its tiny fixture is a compiled Flutter application.
"""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile
import unittest
import zipfile


SCRIPT = Path(__file__).resolve().parents[1] / "package.py"
SPEC = importlib.util.spec_from_file_location("release_package", SCRIPT)
release = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = release
SPEC.loader.exec_module(release)


class PackagingTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.repo = self.root / "repo"
        self.repo.mkdir()
        (self.repo / "pubspec.yaml").write_text("name: getbible\nversion: 1.2.3+42\n", encoding="utf-8")
        (self.repo / "LICENSE").write_text("Test packaging fixture license\n", encoding="utf-8")
        release.run(["git", "init", "--quiet", self.repo])
        release.run(["git", "add", "."], cwd=self.repo)
        release.run(["git", "-c", "user.name=Packaging Test", "-c", "user.email=tests@example.invalid", "commit", "--quiet", "-m", "Packaging fixture"], cwd=self.repo)
        self.metadata = release.ReleaseMetadata.create(self.repo, 42)
        self.metadata_path = self.root / "metadata.json"
        release.write_json(self.metadata_path, release.asdict(self.metadata))

    def args(self, target="web", source=None, output=None, base="/flutter/"):
        return argparse.Namespace(
            repo=self.repo, metadata=self.metadata_path,
            output=output or self.root / "dist", input=source,
            target=target, arch="x64", base_href=base,
        )

    def web(self):
        path = self.root / "web"
        path.mkdir()
        (path / "assets").mkdir()
        for name, content in {
            "index.html": '<html><base href="/flutter/"></html>',
            "flutter_bootstrap.js": "start();", "main.dart.js": "main();",
            "drift_worker.dart.js": "worker();", "sqlite3.wasm": "wasm fixture",
            "offline_bible_worker.dart.js": "offlineWorker();",
            "offline_shell.js": "registerWorker();",
            "offline_service_worker.js": "serviceWorker();",
        }.items():
            (path / name).write_text(content, encoding="utf-8")
        self.shell_manifest(path)
        return path

    def shell_manifest(self, path):
        entries = [{"path": file.relative_to(path).as_posix(), "bytes": file.stat().st_size, "sha256": release.sha256(file)}
                   for file in sorted(path.rglob("*")) if file.is_file() and file.name not in {"offline-shell-manifest.json", "offline_service_worker.js"}]
        revision = hashlib.sha256(json.dumps(entries, sort_keys=True, separators=(",", ":"), ensure_ascii=True).encode()).hexdigest()
        (path / "offline-shell-manifest.json").write_text(json.dumps({"schema_version": 1, "revision": revision, "worker_revision": "a" * 64, "files": entries}))

    def verify_checksums(self, output):
        checksums = list(output.glob("*-SHA256SUMS"))
        self.assertEqual(len(checksums), 1)
        for line in checksums[0].read_text().splitlines():
            digest, name = line.split("  ")
            self.assertEqual(hashlib.sha256((output / name).read_bytes()).hexdigest(), digest)

    def test_metadata_preserves_pubspec_and_supplies_shared_flutter_versions(self):
        github_output = self.root / "github-output"
        subprocess.run([
            sys.executable, str(SCRIPT), "metadata", "--repo", str(self.repo),
            "--build-number", "42", "--output", str(self.metadata_path),
            "--github-output", str(github_output),
        ], check=True, capture_output=True, text=True)
        self.assertEqual(self.metadata.version, "1.2.3+42")
        self.assertEqual(self.metadata.artifact_version, "1.2.3-build.42")
        self.assertIn("version_name=1.2.3\n", github_output.read_text())
        self.assertIn("build_number=42\n", github_output.read_text())
        self.assertIn("version: 1.2.3+42", (self.repo / "pubspec.yaml").read_text())
        for invalid in (0, 3, 65536):
            with self.subTest(build=invalid), self.assertRaises(release.PackagingError):
                release.ReleaseMetadata.create(self.repo, invalid)

    def test_pubspec_prerelease_channels_keep_numeric_apple_version_separate(self):
        for suffix, channel in (("-alpha.1", "alpha"), ("-beta.2", "beta"), ("-rc.3", "rc"), ("", "stable")):
            with self.subTest(channel=channel):
                version = f"1.2.3{suffix}"
                (self.repo / "pubspec.yaml").write_text(f"version: {version}+42\n", encoding="utf-8")
                metadata = release.ReleaseMetadata.create(self.repo, None)
                self.assertEqual(metadata.release_version, version)
                self.assertEqual(metadata.version_name, "1.2.3")
                self.assertEqual(metadata.channel, channel)
                self.assertEqual(metadata.version, f"{version}+42")
                self.assertEqual(metadata.artifact_version, f"{version}-build.42")

    def test_noncanonical_versions_and_native_version_overflow_are_rejected(self):
        for version in ("01.2.3+42", "1.2.3-dev.1+42", "1.2.3-alpha.0+42", "1.2.3-alpha.01+42", "1.2.3+042", "1.2.3+65536", "65536.2.3+42", "1.2.3+0"):
            with self.subTest(version=version):
                (self.repo / "pubspec.yaml").write_text(f"version: {version}\n", encoding="utf-8")
                with self.assertRaises(release.PackagingError):
                    release.ReleaseMetadata.create(self.repo, None)

    def test_metadata_from_another_commit_is_rejected(self):
        metadata = release.asdict(self.metadata)
        metadata["git_sha"] = "f" * 40
        release.write_json(self.metadata_path, metadata)
        with self.assertRaisesRegex(release.PackagingError, "git_sha differs"):
            release.package(self.args(source=self.web()))
        self.assertFalse((self.root / "dist").exists())

    def test_web_cli_emits_complete_versioned_archive_manifest_and_checksums(self):
        source = self.web()
        result = subprocess.run([
            sys.executable, str(SCRIPT), "package", "--repo", str(self.repo),
            "--target", "web", "--input", str(source), "--metadata", str(self.metadata_path),
            "--output", str(self.root / "dist"), "--base-href", "/flutter/",
        ], check=True, capture_output=True, text=True)
        output = self.root / "dist"
        archive = output / "getbible-1.2.3-build.42-web-browser.zip"
        self.assertIn(archive.name, result.stdout)
        with zipfile.ZipFile(archive) as package:
            self.assertIsNone(package.testzip())
            self.assertIn("index.html", package.namelist())
            self.assertIn("sqlite3.wasm", package.namelist())
            self.assertIn("drift_worker.dart.js", package.namelist())
            self.assertIn("offline_bible_worker.dart.js", package.namelist())
            self.assertIn("offline_service_worker.js", package.namelist())
            self.assertIn("offline-shell-manifest.json", package.namelist())
            self.assertEqual(json.loads(package.read("release-metadata.json"))["version"], "1.2.3+42")
        self.verify_checksums(output)
        self.assertFalse((source / "release-metadata.json").exists())
        manifest = json.loads(next(output.glob("*-manifest.json")).read_text())
        self.assertEqual(manifest["base_href"], "/flutter/")
        self.assertEqual(manifest["git_sha"], self.metadata.git_sha)

    def test_web_missing_worker_and_wrong_base_publish_nothing(self):
        source = self.web()
        for base in ("relative/", "/another/", "/bad?query/"):
            with self.subTest(base=base), self.assertRaises(release.PackagingError):
                release.package(self.args(source=source, base=base))
        (source / "drift_worker.dart.js").unlink()
        with self.assertRaisesRegex(release.PackagingError, "drift_worker"):
            release.package(self.args(source=source))
        self.assertEqual(list((self.root / "dist").iterdir()), [])

    def test_web_stale_or_incomplete_offline_shell_is_not_packaged(self):
        source = self.web()
        (source / "main.dart.js").write_text("changedAfterShellGeneration();")
        with self.assertRaisesRegex(release.PackagingError, "asset is missing or changed"):
            release.package(self.args(source=source))
        self.shell_manifest(source)
        (source / "unexpected.js").write_text("untracked();")
        with self.assertRaisesRegex(release.PackagingError, "complete compiled application"):
            release.package(self.args(source=source))
        self.assertEqual(list((self.root / "dist").iterdir()), [])

    def test_web_missing_offline_worker_cannot_be_packaged(self):
        source = self.web()
        (source / "offline_service_worker.js").unlink()
        with self.assertRaisesRegex(release.PackagingError, "offline_service_worker"):
            release.package(self.args(source=source))

    def test_repeat_packaging_cannot_replace_an_existing_release(self):
        source = self.web()
        release.package(self.args(source=source))
        before = {path.name: path.read_bytes() for path in (self.root / "dist").iterdir()}
        with self.assertRaisesRegex(release.PackagingError, "overwrite existing"):
            release.package(self.args(source=source))
        self.assertEqual(before, {path.name: path.read_bytes() for path in (self.root / "dist").iterdir()})

    def test_zip_is_reproducible_and_preserves_executable_permissions(self):
        source = self.web()
        (source / "main.dart.js").chmod(0o755)
        first, second = self.root / "first.zip", self.root / "second.zip"
        release.archive_zip(source, first, self.metadata.source_date_epoch)
        for path in source.rglob("*"):
            os.utime(path, (1_800_000_000, 1_800_000_000))
        release.archive_zip(source, second, self.metadata.source_date_epoch)
        self.assertEqual(first.read_bytes(), second.read_bytes())
        with zipfile.ZipFile(first) as archive:
            self.assertEqual((archive.getinfo("web/main.dart.js").external_attr >> 16) & 0o777, 0o755)

    @unittest.skipIf(sys.platform == "win32", "Creating symlinks needs Windows developer mode")
    def test_internal_symlinks_survive_but_external_links_are_rejected(self):
        source = self.web()
        (source / "alias.js").symlink_to("main.dart.js")
        archive = self.root / "links.zip"
        release.archive_zip(source, archive, self.metadata.source_date_epoch)
        with zipfile.ZipFile(archive) as package:
            self.assertEqual(package.read("web/alias.js"), b"main.dart.js")
        (source / "outside").symlink_to(self.repo / "LICENSE")
        with self.assertRaisesRegex(release.PackagingError, "external or broken symlink"):
            release.package(self.args(source=source))

    def test_android_emits_distinct_debug_and_unsigned_release_packages(self):
        source = self.root / "android"
        for relative, manifest in (
            ("flutter-apk/app-debug.apk", "AndroidManifest.xml"),
            ("flutter-apk/app-release.apk", "AndroidManifest.xml"),
            ("bundle/release/app-release.aab", "base/manifest/AndroidManifest.xml"),
        ):
            path = source / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            with zipfile.ZipFile(path, "w") as package:
                package.writestr(manifest, "binary manifest fixture")
        release.package(self.args(target="android", source=source))
        output = self.root / "dist"
        self.assertEqual(len(list(output.glob("*.apk"))), 2)
        self.assertEqual(len(list(output.glob("*-unsigned-release.aab"))), 1)
        manifest = json.loads(next(output.glob("*-manifest.json")).read_text())
        self.assertIn("release packages require signing", manifest["installability"])
        self.verify_checksums(output)

    @unittest.skipUnless(sys.platform.startswith("linux") and shutil.which("dpkg-deb") and shutil.which("dpkg-shlibdeps"), "Linux Debian tools required")
    def test_linux_real_deb_and_tar_have_dependencies_launchers_and_complete_bundle(self):
        source = self.root / "linux"
        (source / "lib").mkdir(parents=True)
        (source / "data/flutter_assets").mkdir(parents=True)
        # Executable fixture exercises real ELF dependency discovery. Production
        # builds and launches are separate jobs, never inferred from this test.
        for relative in ("getbible", "lib/libflutter_linux_gtk.so", "lib/libapp.so"):
            shutil.copy2(shutil.which("true"), source / relative)
        (source / "data/icudtl.dat").write_bytes(b"ICU fixture")
        (self.repo / "packaging/linux").mkdir(parents=True)
        shutil.copy2(release.ROOT / "packaging/linux/life.getbible.mobile.desktop", self.repo / "packaging/linux/life.getbible.mobile.desktop")
        (self.repo / "web/icons").mkdir(parents=True)
        shutil.copy2(release.ROOT / "web/icons/Icon-512.png", self.repo / "web/icons/Icon-512.png")
        release.package(self.args(target="linux", source=source))
        output = self.root / "dist"
        package = next(output.glob("*.deb"))
        control = release.run(["dpkg-deb", "--field", package])
        self.assertIn("Version: 1.2.3-42", control)
        self.assertIn("Depends: libc6", control)
        extracted = self.root / "extracted"
        release.run(["dpkg-deb", "--extract", package, extracted])
        self.assertTrue((extracted / "opt/getbible/lib/libapp.so").exists())
        desktop = (extracted / "usr/share/applications/life.getbible.mobile.desktop").read_text()
        self.assertIn("Exec=/opt/getbible/getbible %u", desktop)
        self.assertIn("MimeType=x-scheme-handler/getbible;", desktop)
        with tarfile.open(next(output.glob("*.tar.gz"))) as archive:
            self.assertTrue(any(name.endswith("/data/icudtl.dat") for name in archive.getnames()))
        self.verify_checksums(output)


if __name__ == "__main__":
    unittest.main()
