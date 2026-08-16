#!/usr/bin/env bash
set -euo pipefail

readonly SDK_ROOT="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
readonly REAL_ADB="$SDK_ROOT/platform-tools/adb"
readonly RETRIES=12
readonly RETRY_SECONDS=5

[[ -x "$REAL_ADB" ]] || {
  echo "Android adb retry wrapper: executable not found at $REAL_ADB" >&2
  exit 1
}

retry_bootstrap_command() {
  [[ "${1:-}" == "-s" && "${3:-}" == "shell" ]] || return 1
  [[ "${4:-}" == "input" || "${4:-}" == "settings" ]]
}

if ! retry_bootstrap_command "$@"; then
  exec "$REAL_ADB" "$@"
fi

for attempt in $(seq 1 "$RETRIES"); do
  if "$REAL_ADB" "$@"; then
    exit 0
  fi
  if (( attempt < RETRIES )); then
    sleep "$RETRY_SECONDS"
  fi
done

exit 1
