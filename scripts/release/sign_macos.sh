#!/usr/bin/env bash
set -euo pipefail
if [[ $# -ne 2 || ( "$1" != app && "$1" != dmg ) ]]; then
  echo 'Usage: scripts/release/sign_macos.sh app|dmg PATH' >&2
  exit 2
fi
exec python3 "$(dirname "$0")/apple_signing.py" "macos-$1" "$2"
