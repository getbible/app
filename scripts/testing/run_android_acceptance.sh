#!/usr/bin/env bash
set -euo pipefail
mkdir -p build/runtime-evidence
android_device=emulator-5554
capture_device_state() {
  adb -s "$android_device" logcat -b all -d > build/runtime-evidence/logcat.txt 2>&1 || true
  adb -s "$android_device" shell dumpsys window > build/runtime-evidence/window.txt 2>&1 || true
  adb -s "$android_device" shell dumpsys activity activities > build/runtime-evidence/activities.txt 2>&1 || true
  adb -s "$android_device" shell dumpsys power > build/runtime-evidence/power.txt 2>&1 || true
  adb -s "$android_device" exec-out screencap -p > build/runtime-evidence/android-screen.png 2>/dev/null || true
}
trap capture_device_state EXIT
adb -s "$android_device" wait-for-device
adb -s "$android_device" shell getprop > build/runtime-evidence/device-properties.txt
# A booted emulator may still be locked or lose its foreground window while
# Flutter builds. Clipboard reads require actual Android input focus, which
# synthetic widget taps cannot supply. Keep this dedicated test device awake
# and dismiss its insecure keyguard before launching the native application.
adb -s "$android_device" shell svc power stayon true
adb -s "$android_device" shell input keyevent KEYCODE_WAKEUP
adb -s "$android_device" shell wm dismiss-keyguard
adb -s "$android_device" shell dumpsys window > build/runtime-evidence/window-before-launch.txt
# Build first so native readiness is checked immediately before installation
# and launch, not several minutes before Gradle finishes. Flutter drive reuses
# this exact integration APK; its assertions and native clipboard stay enabled.
flutter build apk --debug --target-platform=android-x64 \
  --target=integration_test/platform_acceptance_test.dart \
  2>&1 | tee build/runtime-evidence/build.log
python scripts/testing/prepare_android_emulator.py --device "$android_device"
flutter drive --driver=test_driver/platform_acceptance.dart \
  --target=integration_test/platform_acceptance_test.dart \
  --use-application-binary=build/app/outputs/flutter-apk/app-debug.apk \
  -d "$android_device" 2>&1 | tee build/runtime-evidence/driver.log
