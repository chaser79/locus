#!/usr/bin/env bash
set -euo pipefail

readonly ADB="${ADB:-adb}"
readonly ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
readonly TEST_APK="${LOCUS_ANDROID_TEST_APK:-$ROOT_DIR/example/build/locus/outputs/apk/androidTest/debug/locus-debug-androidTest.apk}"
readonly PACKAGE="dev.locus.test"
readonly INSTRUMENTATION="$PACKAGE/dev.locus.core.ConfigSnapshotInstrumentation"
readonly BUILD_ATTEMPTS=3
readonly BUILD_RETRY_SECONDS=15

fail() {
  echo "Android config-snapshot instrumentation failed: $*" >&2
  exit 1
}

build_test_apk() {
  local attempt
  for attempt in $(seq 1 "$BUILD_ATTEMPTS"); do
    if (cd "$ROOT_DIR/example/android" && ./gradlew :locus:assembleDebugAndroidTest); then
      return 0
    fi
    if (( attempt < BUILD_ATTEMPTS )); then
      echo "Instrumentation APK build attempt $attempt/$BUILD_ATTEMPTS failed; retrying." >&2
      sleep "$BUILD_RETRY_SECONDS"
    fi
  done
  return 1
}

build_test_apk || fail "could not assemble the instrumentation APK"
[[ -f "$TEST_APK" ]] || fail "instrumentation APK not found at $TEST_APK"
"$ADB" install -r -t "$TEST_APK" >/dev/null || fail "could not install instrumentation APK"

instrumentation_output=""
if ! instrumentation_output=$(
  "$ADB" shell am instrument -w -r "$INSTRUMENTATION" 2>&1
); then
  printf '%s\n' "$instrumentation_output" >&2
  fail "instrumentation command exited unsuccessfully"
fi
printf '%s\n' "$instrumentation_output"
printf '%s\n' "$instrumentation_output" | grep -Fq "Config snapshot instrumentation passed" ||
  fail "instrumentation did not report a passing contract"
printf '%s\n' "$instrumentation_output" | grep -Fq "INSTRUMENTATION_CODE: -1" ||
  fail "instrumentation did not return a successful result code"
