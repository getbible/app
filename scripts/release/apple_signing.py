#!/usr/bin/env python3
"""Sign Apple release outputs with temporary credentials and explicit identities.

The macOS app/DMG stages are separate so package.py can hash the final stapled
files. iOS patches only Runner signing settings for the build, then restores the
original project bytes. Nothing in this module uploads an app to an app store.
"""
from __future__ import annotations

import argparse
import base64
from contextlib import contextmanager
from datetime import datetime, timezone
import fnmatch
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import secrets
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
BUNDLE_ID = "life.getbible.mobile"
MACOS_KEYS = (
    "MACOS_CERTIFICATE_P12_BASE64", "MACOS_CERTIFICATE_PASSWORD",
    "MACOS_SIGNING_IDENTITY", "MACOS_TEAM_ID", "MACOS_NOTARY_KEY_P8_BASE64",
    "MACOS_NOTARY_KEY_ID", "MACOS_NOTARY_ISSUER_ID",
)
IOS_KEYS = (
    "IOS_CERTIFICATE_P12_BASE64", "IOS_CERTIFICATE_PASSWORD",
    "IOS_PROVISIONING_PROFILE_BASE64", "IOS_SIGNING_IDENTITY", "IOS_TEAM_ID",
)


class SigningError(Exception):
    """A signing precondition or verification failed; do not publish the result."""


def run(*args: str | Path, capture: bool = True) -> str:
    # Do not include arguments in an exception: security commands receive a
    # password and the process's diagnostic may contain certificate identities.
    result = subprocess.run([str(arg) for arg in args], check=False, text=True,
                            capture_output=capture)
    if result.returncode:
        diagnostic = (result.stderr or result.stdout or "No diagnostic was returned.")[-4000:]
        for name, value in os.environ.items():
            if value and (name.endswith("_PASSWORD") or name.endswith("_BASE64")):
                diagnostic = diagnostic.replace(value, "[redacted]")
        raise SigningError(f"{Path(str(args[0])).name} failed (exit {result.returncode}): {diagnostic.strip()}")
    return result.stdout if capture else ""


def required(keys: tuple[str, ...]) -> None:
    missing = [key for key in keys if not os.environ.get(key, "").strip()]
    if missing:
        raise SigningError("Missing signing configuration: " + ", ".join(missing))


def decode_secret(name: str, destination: Path) -> None:
    try:
        data = base64.b64decode("".join(os.environ[name].split()), validate=True)
    except (KeyError, ValueError) as error:
        raise SigningError(f"{name} is not valid base64.") from error
    if not data:
        raise SigningError(f"{name} is empty.")
    destination.write_bytes(data)
    destination.chmod(0o600)


class TemporaryKeychain:
    """Restore the user's search list and remove imported private keys on exit."""

    def __init__(self, directory: Path, prefix: str):
        self.directory = directory
        self.prefix = prefix
        self.path = directory / "signing.keychain-db"
        self.previous: list[str] = []
        self.created = False
        self.identity = os.environ[f"{prefix}_SIGNING_IDENTITY"]

    def __enter__(self) -> "TemporaryKeychain":
        self.previous = shlex.split(run("security", "list-keychains", "-d", "user"))
        try:
            password = secrets.token_hex(32)
            run("security", "create-keychain", "-p", password, self.path)
            self.created = True
            run("security", "set-keychain-settings", "-lut", "21600", self.path)
            run("security", "unlock-keychain", "-p", password, self.path)
            run("security", "list-keychains", "-d", "user", "-s", self.path, *self.previous)
            certificate = self.directory / "certificate.p12"
            decode_secret(f"{self.prefix}_CERTIFICATE_P12_BASE64", certificate)
            run("security", "import", certificate, "-P",
                os.environ[f"{self.prefix}_CERTIFICATE_PASSWORD"], "-k", self.path,
                "-T", "/usr/bin/codesign", "-T", "/usr/bin/security")
            run("security", "set-key-partition-list", "-S", "apple-tool:,apple:,codesign:",
                "-s", "-k", password, self.path)
            identities = run("security", "find-identity", "-v", "-p", "codesigning", self.path)
            matches = re.findall(r'\b([A-Fa-f0-9]{40})\s+"([^"]+)"', identities)
            identity_hashes = [digest for digest, name in matches if name == self.identity]
            expected = "Developer ID Application: " if self.prefix == "MACOS" else "Apple Distribution: "
            team = os.environ[f"{self.prefix}_TEAM_ID"]
            if not self.identity.startswith(expected) or not self.identity.endswith(f"({team})"):
                raise SigningError(f"{self.prefix}_SIGNING_IDENTITY has the wrong certificate type or team.")
            if len(identity_hashes) != 1:
                raise SigningError("The imported keychain must contain exactly one matching valid identity.")
            self.identity = identity_hashes[0]
            return self
        except BaseException:
            self.close()
            raise

    def close(self) -> None:
        if not self.created:
            return
        try:
            run("security", "list-keychains", "-d", "user", "-s", *self.previous)
        finally:
            run("security", "delete-keychain", self.path)
            self.created = False

    def __exit__(self, *unused: object) -> None:
        self.close()


def verify_team(path: Path, team: str) -> None:
    run("codesign", "--verify", "--deep", "--strict", path)
    result = subprocess.run(["codesign", "--display", "--verbose=4", str(path)],
                            capture_output=True, text=True, check=True)
    if f"TeamIdentifier={team}" not in result.stderr.splitlines():
        raise SigningError("Signed artifact does not match the configured Apple team.")


def notarize(path: Path, directory: Path) -> None:
    key = directory / "notary.p8"
    decode_secret("MACOS_NOTARY_KEY_P8_BASE64", key)
    output = run("xcrun", "notarytool", "submit", path, "--key", key,
                 "--key-id", os.environ["MACOS_NOTARY_KEY_ID"],
                 "--issuer", os.environ["MACOS_NOTARY_ISSUER_ID"],
                 "--wait", "--timeout", "20m", "--output-format", "json")
    response = json.loads(output)
    if response.get("status") != "Accepted":
        # The submission ID is public diagnostic metadata; no credentials are printed.
        raise SigningError(f"Apple did not accept notarization; submission {response.get('id', 'unknown')}.")


def sign_macos(kind: str, path: Path) -> None:
    required(MACOS_KEYS)
    if not path.exists() or path.suffix != (".app" if kind == "app" else ".dmg"):
        raise SigningError(f"Expected an existing macOS {kind} output.")
    with tempfile.TemporaryDirectory(prefix="getbible-macos-sign-") as temporary:
        directory = Path(temporary)
        with TemporaryKeychain(directory, "MACOS") as keychain:
            command = ["codesign", "--force", "--sign", keychain.identity,
                       "--keychain", str(keychain.path), "--timestamp"]
            if kind == "app":
                with (path / "Contents/Info.plist").open("rb") as stream:
                    info = plistlib.load(stream)
                if info.get("CFBundleIdentifier") != BUNDLE_ID:
                    raise SigningError("Unexpected macOS bundle identifier.")
                if any(item.suffix == ".app" for item in path.rglob("*.app")):
                    raise SigningError("Nested apps need their own explicit entitlement policy.")
                # Sign real Mach-O code from the inside out, followed by framework
                # seals and finally the app. Never use --deep to infer signing rules.
                magic = {b"\xfe\xed\xfa\xce", b"\xce\xfa\xed\xfe", b"\xfe\xed\xfa\xcf",
                         b"\xcf\xfa\xed\xfe", b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca",
                         b"\xca\xfe\xba\xbf", b"\xbf\xba\xfe\xca"}
                main = path / "Contents/MacOS" / info["CFBundleExecutable"]
                for item in sorted(path.rglob("*"), key=lambda value: len(value.parts), reverse=True):
                    if item.is_symlink() or not item.is_file() or item == main:
                        continue
                    with item.open("rb") as stream:
                        is_code = stream.read(4) in magic
                    if is_code:
                        run(*command, "--options", "runtime", item)
                for framework in sorted(path.rglob("*.framework"), key=lambda value: len(value.parts), reverse=True):
                    if not framework.is_symlink():
                        run(*command, "--options", "runtime", framework)
                run(*command, "--options", "runtime", "--entitlements",
                    ROOT / "macos/Runner/Release.entitlements", path)
                verify_team(path, os.environ["MACOS_TEAM_ID"])
                archive = directory / "notarize.zip"
                run("ditto", "-c", "-k", "--keepParent", path, archive)
                notarize(archive, directory)
            else:
                run(*command, path)
                verify_team(path, os.environ["MACOS_TEAM_ID"])
                notarize(path, directory)
            run("xcrun", "stapler", "staple", path)
            run("xcrun", "stapler", "validate", path)
            if kind == "app":
                run("spctl", "--assess", "--type", "execute", path)
            else:
                run("spctl", "--assess", "--type", "open", "--context", "context:primary-signature", path)
    print(f"Signed and notarized macOS {kind}: {path.name}")


def validate_profile(profile: dict, requested: dict, team: str, now: datetime) -> str:
    """Reject development/ad-hoc/wrong-team profiles before changing the project."""
    identifier = profile.get("UUID", "")
    if not re.fullmatch(r"[A-Fa-f0-9-]{36}", identifier):
        raise SigningError("Provisioning profile has no valid UUID.")
    if profile.get("TeamIdentifier") != [team]:
        raise SigningError("Provisioning profile belongs to another Apple team.")
    expiry = profile.get("ExpirationDate")
    if not isinstance(expiry, datetime) or expiry.replace(tzinfo=timezone.utc) <= now:
        raise SigningError("Provisioning profile is expired or has no expiration date.")
    entitlements = profile.get("Entitlements", {})
    if (entitlements.get("get-task-allow") is not False or
            "ProvisionedDevices" in profile or profile.get("ProvisionsAllDevices")):
        raise SigningError("An App Store distribution provisioning profile is required.")
    prefixes = profile.get("ApplicationIdentifierPrefix", [])
    if (not isinstance(prefixes, list) or not prefixes or
            not all(isinstance(prefix, str) and re.fullmatch(r"[A-Z0-9]{10}", prefix) for prefix in prefixes) or
            entitlements.get("application-identifier") not in [f"{prefix}.{BUNDLE_ID}" for prefix in prefixes]):
        raise SigningError("Provisioning profile does not match life.getbible.mobile.")
    if entitlements.get("com.apple.developer.team-identifier") != team:
        raise SigningError("Provisioning profile entitlement belongs to another team.")
    for name, needed in requested.items():
        allowed = entitlements.get(name)
        if isinstance(needed, list):
            if not isinstance(allowed, list) or any(
                not any(isinstance(pattern, str) and fnmatch.fnmatchcase(value, pattern)
                        for pattern in allowed) for value in needed
            ):
                raise SigningError(f"Provisioning profile does not permit entitlement {name}.")
        elif allowed != needed:
            raise SigningError(f"Provisioning profile does not permit entitlement {name}.")
    return identifier


def configured_project(source: str, team: str, identity: str, profile: str) -> str:
    """Set only Runner configurations; framework and test targets get no profile."""
    pattern = re.compile(r"(\bbuildSettings = \{)(.*?)(\n\s*\};)", re.DOTALL)
    replacements = 0

    def replace(match: re.Match[str]) -> str:
        nonlocal replacements
        body = match[2]
        if not re.search(r"\bPRODUCT_BUNDLE_IDENTIFIER = " + re.escape(BUNDLE_ID) + r";", body):
            return match[0]
        if "CODE_SIGN_ENTITLEMENTS = Runner/Runner.entitlements;" not in body:
            raise SigningError("Runner entitlements are missing; signing configuration needs review.")
        values = {"CODE_SIGN_STYLE": "Manual", "DEVELOPMENT_TEAM": team,
                  "CODE_SIGN_IDENTITY": identity, "PROVISIONING_PROFILE_SPECIFIER": profile}
        for name, value in values.items():
            body = re.sub(r'\n\s*' + name + r' = [^;]*;', '', body)
            body = re.sub(r'\n\s*"' + name + r'\[sdk=iphoneos\*\]" = [^;]*;', '', body)
            body += f"\n\t\t\t\t{name} = {json.dumps(value)};"
            if name == "CODE_SIGN_IDENTITY":
                body += f'\n\t\t\t\t"CODE_SIGN_IDENTITY[sdk=iphoneos*]" = {json.dumps(value)};' 
        replacements += 1
        return match[1] + body + match[3]

    result = pattern.sub(replace, source)
    if replacements != 3:
        raise SigningError("Expected three Runner configurations; review the updated Xcode project.")
    return result


@contextmanager
def installed_profile(profile: Path, identifier: str):
    """Install in both current and legacy Xcode locations, restoring prior bytes."""
    paths = [Path.home() / "Library/Developer/Xcode/UserData/Provisioning Profiles",
             Path.home() / "Library/MobileDevice/Provisioning Profiles"]
    previous: dict[Path, bytes | None] = {}
    try:
        for folder in paths:
            folder.mkdir(parents=True, exist_ok=True)
            destination = folder / f"{identifier}.mobileprovision"
            previous[destination] = destination.read_bytes() if destination.exists() else None
            shutil.copy2(profile, destination)
            destination.chmod(0o600)
        yield
    finally:
        for destination, content in previous.items():
            if content is None:
                destination.unlink(missing_ok=True)
            else:
                destination.write_bytes(content)


def sign_ios() -> None:
    required(IOS_KEYS + ("VERSION_NAME", "BUILD_NUMBER"))
    if not re.fullmatch(r"\d+\.\d+\.\d+", os.environ["VERSION_NAME"]) or not re.fullmatch(r"[1-9]\d*", os.environ["BUILD_NUMBER"]):
        raise SigningError("VERSION_NAME and BUILD_NUMBER must contain valid release metadata.")
    with tempfile.TemporaryDirectory(prefix="getbible-ios-sign-") as temporary:
        directory = Path(temporary)
        profile_file = directory / "profile.mobileprovision"
        decode_secret("IOS_PROVISIONING_PROFILE_BASE64", profile_file)
        profile = plistlib.loads(run("security", "cms", "-D", "-i", profile_file).encode())
        with (ROOT / "ios/Runner/Runner.entitlements").open("rb") as stream:
            entitlements = plistlib.load(stream)
        identifier = validate_profile(profile, entitlements, os.environ["IOS_TEAM_ID"], datetime.now(timezone.utc))
        options = {"method": "app-store-connect", "destination": "export", "signingStyle": "manual",
                   "teamID": os.environ["IOS_TEAM_ID"], "signingCertificate": os.environ["IOS_SIGNING_IDENTITY"],
                   "provisioningProfiles": {BUNDLE_ID: identifier}, "manageAppVersionAndBuildNumber": False,
                   "uploadSymbols": True, "stripSwiftSymbols": True}
        export_options = directory / "ExportOptions.plist"
        with export_options.open("wb") as stream:
            plistlib.dump(options, stream)
        with TemporaryKeychain(directory, "IOS") as keychain, installed_profile(profile_file, identifier):
            certificates = profile.get("DeveloperCertificates", [])
            if not isinstance(certificates, list) or not any(
                isinstance(certificate, bytes) and
                hashlib.sha1(certificate).hexdigest().upper() == keychain.identity.upper()
                for certificate in certificates
            ):
                raise SigningError("Provisioning profile does not include the imported distribution certificate.")
            project = ROOT / "ios/Runner.xcodeproj/project.pbxproj"
            original = project.read_bytes()
            updated = configured_project(original.decode(), os.environ["IOS_TEAM_ID"],
                                         os.environ["IOS_SIGNING_IDENTITY"], identifier)
            try:
                # Never mistake an earlier IPA for this invocation's output if
                # Flutter reports an archive/export failure without an IPA.
                for previous_ipa in (ROOT / "build/ios/ipa").glob("*.ipa"):
                    previous_ipa.unlink()
                project.write_text(updated)
                run("flutter", "build", "ipa", "--release", "--build-name", os.environ["VERSION_NAME"],
                    "--build-number", os.environ["BUILD_NUMBER"], "--export-options-plist", export_options,
                    capture=False)
            finally:
                project.write_bytes(original)
        packages = list((ROOT / "build/ios/ipa").glob("*.ipa"))
        if len(packages) != 1:
            raise SigningError("Expected exactly one exported App Store IPA.")
        print(f"Exported signed iOS/iPadOS IPA: {packages[0].name}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("target", choices=("macos-app", "macos-dmg", "ios"))
    parser.add_argument("path", nargs="?", type=Path)
    arguments = parser.parse_args()
    if sys.platform != "darwin":
        parser.error("Apple signing requires a macOS host and Xcode.")
    os.chdir(ROOT)
    os.umask(0o077)
    # Convert workflow cancellation into normal stack unwinding so keychains,
    # profiles and temporary project settings are removed/restored.
    def cancelled(signum: int, frame: object) -> None:
        raise KeyboardInterrupt(f"Signing interrupted by signal {signum}.")
    signal.signal(signal.SIGTERM, cancelled)
    try:
        if arguments.target == "ios":
            sign_ios()
        elif arguments.path is None:
            parser.error("macOS signing requires an artifact path.")
        else:
            sign_macos(arguments.target.removeprefix("macos-"), arguments.path.resolve())
    except (SigningError, OSError, ValueError, subprocess.SubprocessError) as error:
        print(f"Apple signing failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
