#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
case "$MODE" in
  run|--build-only|--verify|--ui-test|--debug|--logs|--telemetry) ;;
  --help|-h)
    printf 'Usage: %s [run|--build-only|--verify|--ui-test|--debug|--logs|--telemetry]\n' "$0"
    printf '  --ui-test: build Debug, open the existing popover, and verify the process (no GUI assertions).\n'
    exit 0
    ;;
  *)
    printf 'Unknown mode: %s\nRun %s --help for usage.\n' "$MODE" "$0" >&2
    exit 2
    ;;
esac
if [[ "$#" -gt 1 ]]; then
  printf 'Only one mode may be supplied.\n' >&2
  exit 2
fi

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
PROJECT_FILE="$PROJECT_ROOT/ToneHop/ToneHop.xcodeproj"
BUILD_ROOT="$PROJECT_ROOT/build"
DERIVED_DATA_PATH="$BUILD_ROOT/DerivedData.noindex"
APP_NAME="ToneHop"
BUNDLE_ID="com.dengziyi.ToneHop"
APP_BUNDLE="$DERIVED_DATA_PATH/Build/Products/Debug/$APP_NAME.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"

# Verify the executable's full path before sending any signal. An older
# app in another checkout or /Applications must remain untouched.
is_project_process() {
  /usr/sbin/lsof -a -p "$1" -d txt -Fn 2>/dev/null \
    | /usr/bin/grep -Fx -- "n$2" >/dev/null
}

project_processes() {
  local process_name="${1:-$APP_NAME}" process_binary="${2:-$APP_BINARY}"
  local candidate_pid
  while IFS= read -r candidate_pid; do
    [[ -n "$candidate_pid" ]] || continue
    if is_project_process "$candidate_pid" "$process_binary"; then
      printf '%s\n' "$candidate_pid"
    fi
  done < <(/usr/bin/pgrep -x "$process_name" || true)
}

stop_project_instances() {
  local process_name="$1" process_binary="$2" candidate_pid attempt
  while IFS= read -r candidate_pid; do
    [[ -n "$candidate_pid" ]] || continue
    if is_project_process "$candidate_pid" "$process_binary"; then
      printf 'Stopping this project instance (PID %s).\n' "$candidate_pid"
      kill -TERM "$candidate_pid"
      # Give an in-flight native route callback/cleanup time to finish. Never KILL.
      for ((attempt = 0; attempt < 200; attempt++)); do
        if ! is_project_process "$candidate_pid" "$process_binary"; then
          break
        fi
        sleep 0.1
      done
      if is_project_process "$candidate_pid" "$process_binary"; then
        printf 'The project instance did not exit. Complete or cancel its Quit confirmation, then retry.\n' >&2
        return 1
      fi
    fi
  done < <(project_processes "$process_name" "$process_binary")
}

wait_for_project_process() {
  local candidate_pid attempt
  for ((attempt = 0; attempt < 50; attempt++)); do
    candidate_pid="$(project_processes | /usr/bin/sed -n '1p')"
    if [[ -n "$candidate_pid" ]]; then
      printf '%s\n' "$candidate_pid"
      return 0
    fi
    sleep 0.1
  done
  printf 'The built app was opened, but its process could not be verified.\n' >&2
  return 1
}

# A build-only call must never stop or launch an app.
if [[ "$MODE" != --build-only ]]; then
  # Also close this checkout's previous output when moving to .noindex.
  stop_project_instances "$APP_NAME" "$BUILD_ROOT/Build/Products/Debug/$APP_NAME.app/Contents/MacOS/$APP_NAME"
  stop_project_instances "$APP_NAME" "$APP_BINARY"
fi

mkdir -p "$BUILD_ROOT/logs"
BUILD_LOG="$BUILD_ROOT/logs/build-$(date '+%Y%m%d-%H%M%S').log"
printf 'Building ToneHop; log: %s\n' "$BUILD_LOG"
/usr/bin/xcodebuild \
  -project "$PROJECT_FILE" \
  -scheme ToneHop \
  -configuration Debug \
  -sdk macosx \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  -quiet build 2>&1 | /usr/bin/tee "$BUILD_LOG"

[[ -x "$APP_BINARY" ]] || {
  printf 'Build completed without the expected app executable: %s\n' "$APP_BINARY" >&2
  exit 1
}
printf 'Built: %s\n' "$APP_BUNDLE"
if [[ "$MODE" == --build-only ]]; then
  exit 0
fi

APP_ARGUMENTS=()
# This script builds Debug only. The app compiles this entry out of Release.
if [[ "$MODE" == --ui-test ]]; then
  APP_ARGUMENTS+=(--show-popover-for-testing)
  # Optional isolated preferences for destructive GUI tests. Normal launches
  # and Release never replace the user's shortcut document.
  if [[ -n "${TONEHOP_SHORTCUT_TEST_PREFERENCES:-}" ]]; then
    APP_ARGUMENTS+=(--shortcut-preferences-for-testing "$TONEHOP_SHORTCUT_TEST_PREFERENCES")
  fi
fi
if [[ -n "${TONEHOP_LIVE_DIAGNOSTICS:-}" ]]; then
  APP_ARGUMENTS+=(--live-diagnostics "$TONEHOP_LIVE_DIAGNOSTICS")
fi
# Explicit Debug integration verification only. No default launch selects audio.
if [[ -n "${TONEHOP_SELECTED_ROUTE_VERIFICATION:-}" ]]; then
  APP_ARGUMENTS+=(--verify-selected-round-trip "$TONEHOP_SELECTED_ROUTE_VERIFICATION")
fi
if [[ "${#APP_ARGUMENTS[@]}" -gt 0 ]]; then
  /usr/bin/open -n "$APP_BUNDLE" --args "${APP_ARGUMENTS[@]}"
else
  /usr/bin/open -n "$APP_BUNDLE"
fi
case "$MODE" in
  run) ;;
  --verify|--ui-test)
    APP_PID="$(wait_for_project_process)"
    printf 'Verified app process at the project path (PID %s). UI and audio still need validation.\n' "$APP_PID"
    ;;
  --debug)
    APP_PID="$(wait_for_project_process)"
    exec /usr/bin/xcrun lldb -p "$APP_PID"
    ;;
  --logs)
    APP_PID="$(wait_for_project_process)"
    exec /usr/bin/log stream --info --style compact --predicate "processIdentifier == $APP_PID"
    ;;
  --telemetry)
    exec /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
esac
