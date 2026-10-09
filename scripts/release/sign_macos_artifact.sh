#!/usr/bin/env bash
set -euo pipefail
if [[ $# -ne 1 ]]; then
  echo 'Usage: scripts/release/sign_macos_artifact.sh DMG_PATH' >&2
  exit 2
fi
exec bash "$(dirname "$0")/sign_macos.sh" dmg "$1"
