#!/usr/bin/env bash
set -euo pipefail

readonly PACKAGE="dev.locus.test"
readonly ACTIVITY="$PACKAGE/dev.locus.core.RecoveryTestActivity"
readonly RECEIVER="$PACKAGE/dev.locus.core.RecoveryTestReceiver"
readonly SERVICE="$PACKAGE/dev.locus.service.ForegroundService"
readonly TAG="LocusRecoveryTest"
readonly ACTION_ARM="dev.locus.test.action.ARM_RECOVERY"
readonly ACTION_REPORT="dev.locus.test.action.REPORT_RECOVERY"
readonly ACTION_STOP="dev.locus.test.action.STOP_RECOVERY"
readonly ADB="${ADB:-adb}"
readonly ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
readonly TEST_APK="${LOCUS_ANDROID_TEST_APK:-$ROOT_DIR/example/build/locus/outputs/apk/androidTest/debug/locus-debug-androidTest.apk}"
readonly LOGCAT_CLEAR_ATTEMPTS=3
readonly LOGCAT_CLEAR_RETRY_SECONDS=1
readonly PROCESS_KILL_ATTEMPTS=3
readonly PROCESS_KILL_RETRY_SECONDS=1

fail() {
  echo "Android process-recovery smoke failed: $*" >&2
  "$ADB" shell dumpsys activity services "$SERVICE" >&2 || true
  "$ADB" logcat -d -t 300 >&2 || true
  exit 1
}

cleanup() {
  "$ADB" shell am force-stop "$PACKAGE" >/dev/null 2>&1 || true
}
trap cleanup EXIT

pid_of_package() {
  "$ADB" shell pidof "$PACKAGE" 2>/dev/null | tr -d '\r' | awk '{print $1}'
}

service_is_running() {
  "$ADB" shell dumpsys activity services "$SERVICE" 2>/dev/null |
    grep -Fq "$SERVICE"
}

start_command() {
  local action="$1"
  "$ADB" shell am start -W -a "$action" -n "$ACTIVITY" >/dev/null
}

send_command() {
  local action="$1"
  "$ADB" shell am broadcast -a "$action" -n "$RECEIVER" >/dev/null
}

read_report() {
  local previous=""
  local report=""
  previous=$("$ADB" logcat -d -s "$TAG:I" '*:S' 2>/dev/null |
    grep -F "state pid=" | tail -n 1 || true)
  send_command "$ACTION_REPORT"
  for _ in $(seq 1 25); do
    report=$("$ADB" logcat -d -s "$TAG:I" '*:S' 2>/dev/null |
      grep -F "state pid=" | tail -n 1 || true)
    if [[ -n "$report" && "$report" != "$previous" ]]; then
      printf '%s\n' "$report"
      return 0
    fi
    sleep 0.2
  done
  return 1
}

wait_for_runtime_recovery() {
  local expected_pid="$1"
  local report=""
  for _ in $(seq 1 60); do
    report=$(read_report || true)
    if [[ "$(report_field "$report" pid)" == "$expected_pid" &&
          "$(report_field "$report" trackingDesired)" == "true" &&
          "$(report_field "$report" runtimeEnabled)" == "true" ]]; then
      printf '%s\n' "$report"
      return 0
    fi
    sleep 1
  done
  return 1
}

wait_for_terminal_state() {
  local report=""
  for _ in $(seq 1 25); do
    report=$(read_report || true)
    if [[ "$(report_field "$report" trackingDesired)" == "false" &&
          "$(report_field "$report" runtimeEnabled)" == "false" ]]; then
      printf '%s\n' "$report"
      return 0
    fi
    sleep 0.2
  done
  return 1
}

report_field() {
  local report="$1"
  local field="$2"
  sed -n "s/.*${field}=\\([^ ]*\\).*/\\1/p" <<<"$report" | tail -n 1
}

wait_for_service() {
  local old_pid="${1:-}"
  local pid=""
  for _ in $(seq 1 60); do
    pid=$(pid_of_package)
    if [[ -n "$pid" && "$pid" != "$old_pid" ]] && service_is_running; then
      printf '%s\n' "$pid"
      return 0
    fi
    sleep 1
  done
  return 1
}

wait_for_service_stop() {
  for _ in $(seq 1 20); do
    if ! service_is_running; then
      return 0
    fi
    sleep 0.5
  done
  return 1
}

clear_logcat() {
  local attempt
  for attempt in $(seq 1 "$LOGCAT_CLEAR_ATTEMPTS"); do
    if "$ADB" logcat -c >/dev/null 2>&1 ||
      "$ADB" shell logcat -c >/dev/null 2>&1; then
      return 0
    fi
    sleep "$LOGCAT_CLEAR_RETRY_SECONDS"
  done

  # Some hosted API 26 images reject the clear request even though logcat can
  # still be read and appended to. read_report() already waits for a changed
  # report line, so a stale buffer cannot satisfy the lifecycle assertions.
  echo "Warning: unable to clear logcat; continuing with report change detection." >&2
}

kill_process() {
  local pid="$1"
  local attempt
  local shell_error=""
  local run_as_error=""

  for attempt in $(seq 1 "$PROCESS_KILL_ATTEMPTS"); do
    if shell_error=$("$ADB" shell kill -9 "$pid" 2>&1); then
      return 0
    fi
    if run_as_error=$("$ADB" shell run-as "$PACKAGE" /system/bin/kill -9 "$pid" 2>&1); then
      return 0
    fi

    # A heavily contended emulator can report a transient adb failure after
    # the signal has already taken effect. The replacement-PID assertion below
    # still proves that the service recovered from process death.
    if [[ "$(pid_of_package)" != "$pid" ]]; then
      return 0
    fi
    if (( attempt < PROCESS_KILL_ATTEMPTS )); then
      sleep "$PROCESS_KILL_RETRY_SECONDS"
    fi
  done

  printf 'adb shell kill failed: %s\nrun-as kill failed: %s\n' \
    "$shell_error" "$run_as_error" >&2
  return 1
}

[[ -f "$TEST_APK" ]] || fail "instrumentation APK not found at $TEST_APK"
"$ADB" get-state >/dev/null 2>&1 || fail "no adb device is ready"
"$ADB" install -r -t "$TEST_APK" >/dev/null || fail "could not install instrumentation APK"
"$ADB" shell am force-stop "$PACKAGE"
clear_logcat

readonly SDK=$("$ADB" shell getprop ro.build.version.sdk | tr -d '\r')
[[ "$SDK" =~ ^[0-9]+$ ]] || fail "could not read device API level"

# Grant the exact runtime permissions needed by the test-only package. The
# foreground service itself is still started from a visible Activity, matching
# Android 14+'s while-in-use location requirement.
"$ADB" shell pm grant "$PACKAGE" android.permission.ACCESS_COARSE_LOCATION ||
  fail "could not grant coarse location"
"$ADB" shell pm grant "$PACKAGE" android.permission.ACCESS_FINE_LOCATION ||
  fail "could not grant fine location"
if (( SDK >= 29 )); then
  "$ADB" shell pm grant "$PACKAGE" android.permission.ACCESS_BACKGROUND_LOCATION ||
    fail "could not grant background location"
fi
if (( SDK >= 33 )); then
  "$ADB" shell pm grant "$PACKAGE" android.permission.POST_NOTIFICATIONS ||
    fail "could not grant notifications"
fi
"$ADB" shell settings put secure location_mode 3 >/dev/null || true

start_command "$ACTION_ARM"
initial_pid=$(wait_for_service) || fail "foreground service did not start"
[[ -n "$initial_pid" ]] || fail "initial process PID was empty"

# SIGKILL reproduces process loss without force-stopping the package. A
# force-stop would intentionally clear Android's restart eligibility and would
# therefore test the wrong lifecycle contract. The adb-shell form works on
# older API images where run-as may reject the test-only package; run-as remains
# a fallback for devices that restrict shell process signals.
kill_process "$initial_pid" ||
  fail "could not kill process $initial_pid without force-stopping the package"
recovered_pid=$(wait_for_service "$initial_pid") ||
  fail "sticky service did not recover with a replacement process"
[[ "$recovered_pid" != "$initial_pid" ]] || fail "process PID did not change"

recovered_report=$(wait_for_runtime_recovery "$recovered_pid") ||
  fail "recovered process did not re-arm the location runtime"
not_before=$(report_field "$recovered_report" reportedAt)
[[ "$not_before" =~ ^[0-9]+$ ]] || fail "recovery report had no valid timestamp"

# Emulator geo fixes exercise the real FusedLocationProvider callback and the
# production SQLite persistence path. Alternate fixes ensure distance filters
# cannot suppress every update on older Play Services builds.
fresh_location_seen=false
for attempt in $(seq 1 45); do
  if (( attempt % 2 == 0 )); then
    "$ADB" emu geo fix -122.0840 37.4220 >/dev/null
  else
    "$ADB" emu geo fix -122.0940 37.4320 >/dev/null
  fi
  sleep 1
  location_report=$(read_report) || continue
  latest_timestamp=$(report_field "$location_report" latestTimestamp)
  if [[ "$latest_timestamp" =~ ^[0-9]+$ ]] && (( latest_timestamp >= not_before )); then
    fresh_location_seen=true
    break
  fi
done
[[ "$fresh_location_seen" == "true" ]] ||
  fail "no post-recovery location reached durable storage"

# Android 13+'s Task Manager Stop kills the process without placing the
# package in the force-stopped state. A later broadcast/job can therefore
# launch it again; Locus must consume the explicit-stop exit record and clear
# durable tracking intent before reconciliation can revive the service.
if (( SDK >= 33 )); then
  "$ADB" shell cmd activity stop-app "$PACKAGE" >/dev/null ||
    fail "could not invoke Android Task Manager Stop semantics"
  wait_for_service_stop || fail "foreground service survived Task Manager Stop"
  task_manager_report=$(wait_for_terminal_state) ||
    fail "could not inspect state after Task Manager Stop"
  [[ "$(report_field "$task_manager_report" trackingDesired)" == "false" ]] ||
    fail "Task Manager Stop did not clear durable tracking intent on relaunch"
  [[ "$(report_field "$task_manager_report" runtimeEnabled)" == "false" ]] ||
    fail "Task Manager Stop re-enabled the location runtime on relaunch"
  service_is_running && fail "Task Manager Stop inspection resurrected the service"

  # Re-arm the fixture so the SDK's explicit STOP contract remains an
  # independent assertion below.
  start_command "$ACTION_ARM"
  wait_for_service >/dev/null || fail "fixture did not re-arm after Task Manager Stop"
fi

# An explicit stop is terminal: it clears durable intent, stops the service,
# and must remain stopped after another process loss/recreation.
send_command "$ACTION_STOP"
wait_for_service_stop || fail "foreground service survived explicit stop"
stopped_report=$(read_report) || fail "could not read explicitly stopped state"
[[ "$(report_field "$stopped_report" trackingDesired)" == "false" ]] ||
  fail "explicit stop did not clear durable tracking intent"
stopped_pid=$(report_field "$stopped_report" pid)
if [[ -n "$stopped_pid" ]]; then
  "$ADB" shell run-as "$PACKAGE" kill -9 "$stopped_pid" >/dev/null 2>&1 || true
fi
sleep 10
service_is_running && fail "service resurrected after explicit stop"

terminal_report=$(read_report) || fail "could not read terminal state"
[[ "$(report_field "$terminal_report" trackingDesired)" == "false" ]] ||
  fail "terminal process recreation restored tracking intent"
service_is_running && fail "state inspection resurrected the stopped service"

echo "Android process-recovery smoke passed on API $SDK: PID $initial_pid -> $recovered_pid, fresh location persisted, user and SDK stops remained terminal."
