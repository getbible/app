#!/usr/bin/env bash
set -euo pipefail
mkdir -p build/runtime-evidence
adb shell getprop > build/runtime-evidence/device-properties.txt
trap 'adb logcat -d > build/runtime-evidence/logcat.txt 2>&1 || true' EXIT
flutter drive --driver=test_driver/platform_acceptance.dart \
  --target=integration_test/platform_acceptance_test.dart \
  -d emulator-5554 2>&1 | tee build/runtime-evidence/driver.log
