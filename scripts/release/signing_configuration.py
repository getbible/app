#!/usr/bin/env python3
"""Report signing configuration availability without reading or printing key data."""

import argparse
import json
import os
from pathlib import Path
import sys

REQUIRED = {
    "android": (
        "ANDROID_KEYSTORE_BASE64",
        "ANDROID_KEYSTORE_PASSWORD",
        "ANDROID_KEY_ALIAS",
        "ANDROID_KEY_PASSWORD",
    ),
    "windows": (
        "WINDOWS_SIGNING_CERTIFICATE_BASE64",
        "WINDOWS_SIGNING_CERTIFICATE_PASSWORD",
    ),
    "macos": (
        "MACOS_CERTIFICATE_P12_BASE64",
        "MACOS_CERTIFICATE_PASSWORD",
        "MACOS_NOTARY_KEY_P8_BASE64",
        "MACOS_SIGNING_IDENTITY",
        "MACOS_TEAM_ID",
        "MACOS_NOTARY_KEY_ID",
        "MACOS_NOTARY_ISSUER_ID",
    ),
    "ios": (
        "IOS_CERTIFICATE_P12_BASE64",
        "IOS_CERTIFICATE_PASSWORD",
        "IOS_PROVISIONING_PROFILE_BASE64",
        "IOS_SIGNING_IDENTITY",
        "IOS_TEAM_ID",
    ),
}


def assess(available_names):
    """Accept names only so API metadata and runtime checks share one contract."""
    available = set(available_names)
    return {
        platform: {
            "configured": all(name in available for name in required),
            "missing": [name for name in required if name not in available],
        }
        for platform, required in REQUIRED.items()
    }


def metadata_names(document):
    """Accept GitHub's secret metadata response or a JSON array of names."""
    if isinstance(document, dict):
        secrets = document.get("secrets", [])
        variables = document.get("variables", [])
        if not isinstance(secrets, list) or not isinstance(variables, list):
            raise ValueError("Invalid signing metadata lists")
        records = secrets + variables
    else:
        records = document
    if not isinstance(records, list):
        raise ValueError("Expected GitHub secret metadata or an array of secret names")
    names = [
        record.get("name") if isinstance(record, dict) else record for record in records
    ]
    if not all(isinstance(name, str) and name for name in names):
        raise ValueError("Invalid secret-name metadata")
    return names


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--metadata-file",
        type=Path,
        help="JSON secret metadata; values are neither required nor output",
    )
    parser.add_argument(
        "--require",
        choices=tuple(REQUIRED),
        help="Fail unless all requirements for this platform are available",
    )
    parser.add_argument(
        "--github-output",
        action="store_true",
        help="Append booleans to GITHUB_OUTPUT for workflow job gates",
    )
    args = parser.parse_args()
    try:
        names = (
            metadata_names(json.loads(args.metadata_file.read_text()))
            if args.metadata_file
            else [
                name for name in set(sum(REQUIRED.values(), ())) if os.environ.get(name)
            ]
        )
        result = assess(names)
        if args.github_output:
            with Path(os.environ["GITHUB_OUTPUT"]).open("a") as output:
                for platform, state in result.items():
                    output.write(
                        f"{platform}_signing={str(state['configured']).lower()}\n"
                    )
        print(json.dumps(result, indent=2))
        return int(bool(args.require and not result[args.require]["configured"]))
    except (OSError, ValueError, KeyError):
        # Do not include untrusted metadata or environment values in diagnostics.
        print(
            "Could not read signing configuration metadata/output location",
            file=sys.stderr,
        )
        return 1


if __name__ == "__main__":
    sys.exit(main())
