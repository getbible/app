"""Portable tests for Apple signing validation and credential cleanup contracts."""
from datetime import datetime, timedelta, timezone
import importlib.util
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location("apple_signing", Path(__file__).resolve().parents[1] / "apple_signing.py")
assert SPEC and SPEC.loader
signing = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(signing)

TEAM = "ABCDEFGHIJ"
IDENTITY = f"Apple Distribution: GetBible ({TEAM})"
UUID = "12345678-1234-1234-1234-123456789abc"
NOW = datetime(2026, 10, 9, tzinfo=timezone.utc)


def profile():
    return {"UUID": UUID, "TeamIdentifier": [TEAM], "ApplicationIdentifierPrefix": [TEAM],
            "ExpirationDate": (NOW + timedelta(days=30)).replace(tzinfo=None),
            "Entitlements": {"get-task-allow": False,
                             "application-identifier": f"{TEAM}.{signing.BUNDLE_ID}",
                             "com.apple.developer.team-identifier": TEAM,
                             "com.apple.developer.associated-domains": ["*"]}}


class ProfileTests(unittest.TestCase):
    def test_current_app_store_profile_allows_repository_domains(self):
        self.assertEqual(signing.validate_profile(profile(),
                         {"com.apple.developer.associated-domains": ["applinks:getbible.life"]}, TEAM, NOW), UUID)

    def test_valid_legacy_app_id_prefix_can_differ_from_team(self):
        data = profile()
        data["ApplicationIdentifierPrefix"] = ["OLDPREFIX1"]
        data["Entitlements"]["application-identifier"] = f"OLDPREFIX1.{signing.BUNDLE_ID}"
        self.assertEqual(signing.validate_profile(data, {}, TEAM, NOW), UUID)

    def test_wrong_team_bundle_development_ad_hoc_and_expiration_fail(self):
        fixtures = []
        for field, value in (("TeamIdentifier", ["OTHERTEAM1"]),
                             ("ExpirationDate", NOW - timedelta(seconds=1)),
                             ("ProvisionedDevices", ["device"]), ("ProvisionsAllDevices", True),
                             ("UUID", "../profile"), ("ApplicationIdentifierPrefix", ["OTHERTEAM1"])):
            data = profile()
            data[field] = value
            fixtures.append(data)
        for field, value in (("get-task-allow", True), ("application-identifier", "OTHER.app"),
                             ("com.apple.developer.team-identifier", "OTHERTEAM1")):
            data = profile()
            data["Entitlements"][field] = value
            fixtures.append(data)
        for data in fixtures:
            with self.subTest(data=data), self.assertRaises(signing.SigningError):
                signing.validate_profile(data, {}, TEAM, NOW)

    def test_missing_associated_domains_are_not_silently_removed(self):
        data = profile()
        data["Entitlements"].pop("com.apple.developer.associated-domains")
        with self.assertRaisesRegex(signing.SigningError, "entitlement"):
            signing.validate_profile(data, {"com.apple.developer.associated-domains": ["applinks:getbible.life"]}, TEAM, NOW)

    def test_only_matching_associated_domains_are_allowed(self):
        data = profile()
        data["Entitlements"]["com.apple.developer.associated-domains"] = ["applinks:example.org"]
        with self.assertRaises(signing.SigningError):
            signing.validate_profile(data, {"com.apple.developer.associated-domains": ["applinks:getbible.life"]}, TEAM, NOW)

    def test_project_patch_changes_only_runner_and_preserves_entitlements(self):
        original = (signing.ROOT / "ios/Runner.xcodeproj/project.pbxproj").read_text()
        updated = signing.configured_project(original, TEAM, IDENTITY, UUID)
        self.assertEqual(updated.count(f'PROVISIONING_PROFILE_SPECIFIER = "{UUID}";'), 3)
        self.assertEqual(updated.count("CODE_SIGN_ENTITLEMENTS = Runner/Runner.entitlements;"), 3)
        self.assertEqual(updated.count("CODE_SIGN_STYLE = Automatic;"), original.count("CODE_SIGN_STYLE = Automatic;"))
        self.assertIn("PRODUCT_BUNDLE_IDENTIFIER = life.getbible.mobile.RunnerTests;", updated)
        self.assertEqual(signing.configured_project(updated, TEAM, IDENTITY, UUID), updated)

    def test_unknown_project_structure_fails_before_writing(self):
        with self.assertRaises(signing.SigningError):
            signing.configured_project("different project format", TEAM, IDENTITY, UUID)

    def test_profile_install_restores_existing_bytes_on_failure(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            current = root / "Library/Developer/Xcode/UserData/Provisioning Profiles" / f"{UUID}.mobileprovision"
            legacy = root / "Library/MobileDevice/Provisioning Profiles" / f"{UUID}.mobileprovision"
            current.parent.mkdir(parents=True)
            current.write_bytes(b"previous local profile")
            supplied = root / "input.mobileprovision"
            supplied.write_bytes(b"new profile")
            with patch.object(Path, "home", return_value=root):
                with self.assertRaises(RuntimeError):
                    with signing.installed_profile(supplied, UUID):
                        self.assertEqual(current.read_bytes(), b"new profile")
                        self.assertEqual(legacy.read_bytes(), b"new profile")
                        raise RuntimeError("build failed")
            self.assertEqual(current.read_bytes(), b"previous local profile")
            self.assertFalse(legacy.exists())

    def test_keychain_import_failure_restores_search_list_and_deletes_keychain(self):
        calls = []
        def command(*args, **kwargs):
            calls.append(args)
            if args[:4] == ("security", "list-keychains", "-d", "user") and len(args) == 4:
                return '"/Users/test/Library/Keychains/login.keychain-db"'
            if args[:2] == ("security", "import"):
                raise signing.SigningError("invalid certificate")
            return ""
        with tempfile.TemporaryDirectory() as directory, patch.dict(os.environ, {
            "IOS_SIGNING_IDENTITY": IDENTITY, "IOS_TEAM_ID": TEAM,
            "IOS_CERTIFICATE_P12_BASE64": "YWJj", "IOS_CERTIFICATE_PASSWORD": "test-password"
        }), patch.object(signing, "run", side_effect=command):
            with self.assertRaises(signing.SigningError):
                with signing.TemporaryKeychain(Path(directory), "IOS"):
                    self.fail("must not enter after failed import")
        self.assertEqual(calls[-2], ("security", "list-keychains", "-d", "user", "-s", "/Users/test/Library/Keychains/login.keychain-db"))
        self.assertEqual(calls[-1][:2], ("security", "delete-keychain"))

    def test_invalid_base64_never_creates_key_file(self):
        with tempfile.TemporaryDirectory() as directory, patch.dict(os.environ, {"KEY_BASE64": "invalid?"}):
            destination = Path(directory) / "key"
            with self.assertRaises(signing.SigningError):
                signing.decode_secret("KEY_BASE64", destination)
            self.assertFalse(destination.exists())


if __name__ == "__main__":
    unittest.main()
