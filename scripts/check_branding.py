#!/usr/bin/env python3
"""Validate product identity across native metadata and distributable sources.

Flutter cannot share a Dart constant with native installer metadata. This gate
keeps those required duplicate declarations aligned and rejects retired product
suffixes in tracked source, including localized text and release tooling.
"""
from __future__ import annotations

import json
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
PRODUCT_NAME = "getBible"
PACKAGE_NAME = "getbible"
OLD_READER_HOST = ".".join(("getbible", "life"))
RETIRED_NAME = re.compile(
    r"getBible\.(?:[Ll]ife|live)|getbible[_.-](?:live|life)(?![a-z])"
    r"|getbible[L]ife|GETBIBLE\.(?:LIVE|LIFE)"
)
DISPLAY_NAME_VARIANT = re.compile(r"\b(?:GetBible|Get Bible|get Bible|GETBIBLE)\b")


def text_violations(path: str, value: str) -> list[str]:
    """Allow actual website/repository hosts, never domain-suffixed branding."""
    errors = []
    for line_number, line in enumerate(value.splitlines(), 1):
        # The correctly named external site is not the application's name.
        line = line.replace("app.getbible.life", "reader.example")
        # Negative link-validation fixtures may deliberately contain the old
        # host; that is not permission for production code to generate it.
        if path.startswith(("test/", "scripts/release/tests/")):
            line = line.replace(f"https://{OLD_READER_HOST}", "https://reader.example")
            line = line.replace(f"applinks:{OLD_READER_HOST}", "applinks:reader.example")
        if RETIRED_NAME.search(line):
            errors.append(f"{path}:{line_number}: retired product name")
        if path.endswith(".md") and DISPLAY_NAME_VARIANT.search(line):
            errors.append(f"{path}:{line_number}: product name must be getBible")
        # Public error/status strings are visible branding too. Class names
        # remain ordinary Dart identifiers; translated catalogues have their
        # own generation and runtime brand-normalization contract.
        if path.startswith("lib/") and path.endswith(".dart") and not path.endswith(
            ("web_ui_catalog.dart", "native_ui_catalog.dart")
        ):
            literals = re.finditer(r'''(['"])((?:\\.|(?!\1).)*)\1''', line)
            if any(DISPLAY_NAME_VARIANT.search(item.group(2)) for item in literals):
                errors.append(f"{path}:{line_number}: display text must use getBible")
    return errors


def validate(root: Path) -> list[str]:
    errors = []

    def expect(label: str, actual: object, expected: object) -> None:
        if actual != expected:
            errors.append(f"{label}: expected {expected!r}, found {actual!r}")

    def read(name: str) -> str:
        return (root / name).read_text(encoding="utf-8")

    def declaration(name: str, expression: str, expected: str) -> None:
        match = re.search(expression, read(name), re.MULTILINE)
        expect(name, match.group(1) if match else None, expected)

    declaration("pubspec.yaml", r"^name:\s*(\S+)$", PACKAGE_NAME)
    declaration("lib/core/product_identity.dart", r"name = '([^']+)'", PRODUCT_NAME)
    manifest = json.loads(read("web/manifest.json"))
    for key in ("name", "short_name"):
        expect(f"web/manifest.json:{key}", manifest.get(key), PRODUCT_NAME)
    declaration("web/index.html", r"<title>([^<]+)</title>", PRODUCT_NAME)
    android = ET.fromstring(read("android/app/src/main/AndroidManifest.xml"))
    application = android.find("application")
    expect("Android application label", application.get(
        "{http://schemas.android.com/apk/res/android}label"
    ) if application is not None else None, PRODUCT_NAME)
    ios = plistlib.loads((root / "ios/Runner/Info.plist").read_bytes())
    for key in ("CFBundleDisplayName", "CFBundleName"):
        expect(f"iOS:{key}", ios.get(key), PRODUCT_NAME)
    declaration("macos/Runner/Configs/AppInfo.xcconfig", r"^PRODUCT_NAME = (.+)$", PRODUCT_NAME)
    declaration("packaging/linux/life.getbible.mobile.desktop", r"^Name=(.+)$", PRODUCT_NAME)
    declaration("packaging/windows/getbible.iss", r"^AppName=(.+)$", PRODUCT_NAME)
    for name in ("linux/CMakeLists.txt", "windows/CMakeLists.txt"):
        declaration(name, r'set\(BINARY_NAME "([^"]+)"\)', PACKAGE_NAME)
    for key in ("ProductName", "FileDescription"):
        declaration("windows/runner/Runner.rc", rf'VALUE "{key}", "([^"]+)"', PRODUCT_NAME)
    declaration("scripts/release/package.py", r'^APP = "([^"]+)"$', PACKAGE_NAME)

    names = subprocess.check_output(
        ["git", "ls-files", "-z"], cwd=root
    ).decode("utf-8").split("\0")
    for name in names:
        path = root / name
        if not name or not path.is_file():
            continue
        try:
            value = path.read_text(encoding="utf-8")
        except UnicodeError:
            continue
        errors.extend(text_violations(name, value))
    if (root / "assets/branding/getbible_wordmark.png").exists():
        errors.append("Obsolete domain-suffixed raster wordmark must not be shipped")
    return errors


def main() -> int:
    errors = validate(ROOT)
    if errors:
        print("Product branding validation failed:", file=sys.stderr)
        for error in errors:
            print(f"  {error}", file=sys.stderr)
        return 1
    print("Product identity and native package branding are consistent.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
