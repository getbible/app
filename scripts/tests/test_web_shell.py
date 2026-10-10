"""Build-time inventory, reproducibility and safety checks for the Web shell."""
from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import build_web_shell as shell


class WebShellTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.index = '<html><base href="/flutter/">' + shell.DISABLED_META + '<script src="offline_shell.js" defer></script></html>'
        for name in shell.REQUIRED_FILES:
            (self.root / name).write_text(self.index if name == "index.html" else "fixture " + name)
        (self.root / "assets").mkdir()
        (self.root / "assets/font.ttf").write_bytes(b"binary\x00font")

    def build(self):
        return shell.ShellBuilder(self.root).build()

    def test_inventory_hashes_actual_complete_build_and_enables_only_built_index(self):
        manifest = self.build()
        self.assertEqual(manifest["schema_version"], 1)
        self.assertIn(shell.ENABLED_META, (self.root / "index.html").read_text())
        self.assertEqual(manifest["revision"], hashlib.sha256(shell.canonical_json(manifest["files"])).hexdigest())
        self.assertEqual(manifest["worker_revision"], hashlib.sha256(shell.WORKER_TEMPLATE.encode()).hexdigest())
        names = [entry["path"] for entry in manifest["files"]]
        self.assertEqual(names, sorted([*shell.REQUIRED_FILES, "assets/font.ttf"]))
        for entry in manifest["files"]:
            body = (self.root / entry["path"]).read_bytes()
            self.assertEqual(entry["bytes"], len(body))
            self.assertEqual(entry["sha256"], hashlib.sha256(body).hexdigest())
        self.assertNotIn("__GETBIBLE_SHELL_MANIFEST__", (self.root / shell.WORKER_NAME).read_text())
        if os.name != "nt":
            self.assertEqual((self.root / shell.WORKER_NAME).stat().st_mode & 0o777, 0o644)

    def test_generation_is_idempotent_and_file_timestamps_do_not_change_revision(self):
        first = self.build()
        worker = (self.root / shell.WORKER_NAME).read_bytes()
        for path in self.root.rglob("*"):
            os.utime(path, (1800000000, 1800000000))
        self.assertEqual(self.build(), first)
        self.assertEqual((self.root / shell.WORKER_NAME).read_bytes(), worker)

    def test_asset_change_and_worker_behavior_change_have_separate_cache_identities(self):
        first = self.build()
        (self.root / "main.dart.js").write_text("changed application")
        changed = self.build()
        self.assertNotEqual(first["revision"], changed["revision"])
        self.assertEqual(first["worker_revision"], changed["worker_revision"])
        with patch.object(shell, "WORKER_TEMPLATE", shell.WORKER_TEMPLATE + "\n// behavior revision\n"):
            behavior = self.build()
        self.assertEqual(behavior["revision"], changed["revision"])
        self.assertNotEqual(behavior["worker_revision"], changed["worker_revision"])

    def test_missing_worker_unsafe_base_and_legacy_service_worker_fail_without_outputs(self):
        for value in ("https://another.example/", "/../", "/missing-trailing", "$FLUTTER_BASE_HREF"):
            (self.root / "index.html").write_text(self.index.replace("/flutter/", value))
            with self.subTest(base=value), self.assertRaises(shell.ShellBuildError):
                self.build()
        (self.root / "index.html").write_text(self.index)
        bootstrap = self.root / "flutter_bootstrap.js"
        bootstrap.write_text('_flutter.loader.load({serviceWorkerSettings: {serviceWorkerVersion: "1"}});')
        with self.assertRaisesRegex(shell.ShellBuildError, "legacy service worker"):
            self.build()
        bootstrap.write_text("bootstrap();")
        (self.root / "offline_bible_worker.dart.js").unlink()
        with self.assertRaisesRegex(shell.ShellBuildError, "Missing compiled"):
            self.build()
        self.assertFalse((self.root / shell.MANIFEST_NAME).exists())
        self.assertFalse((self.root / shell.WORKER_NAME).exists())

    def test_size_budget_rejection_preserves_old_generated_cache_files(self):
        self.build()
        original = (self.root / shell.WORKER_NAME).read_bytes()
        with patch.object(shell, "MAX_TOTAL_BYTES", 20):
            with self.assertRaisesRegex(shell.ShellBuildError, "budget"):
                self.build()
        self.assertEqual((self.root / shell.WORKER_NAME).read_bytes(), original)

    @unittest.skipIf(os.name == "nt", "Symlink creation needs Windows developer mode")
    def test_links_special_paths_and_reserved_completion_marker_are_not_static_assets(self):
        link = self.root / "link.js"
        link.symlink_to("main.dart.js")
        with self.assertRaisesRegex(shell.ShellBuildError, "symlink"):
            self.build()
        link.unlink()
        for name in ("script with spaces.js", shell.MARKER_NAME):
            path = self.root / name
            path.write_text("invalid")
            with self.subTest(name=name), self.assertRaises(shell.ShellBuildError):
                self.build()
            path.unlink()


if __name__ == "__main__":
    unittest.main()
