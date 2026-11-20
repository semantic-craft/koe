#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
TEST_AVD_REGEX='^koe-test-api[0-9]+$'
EMULATOR_SERIAL_REGEX='^emulator-[0-9]+$'

AVD_NAME="koe-test-api35"
AVD_EXPLICIT=0
PORT="5580"
REUSE_SERIAL=""
SELF_CHECK=0
FLOW_PATH=""
APK_PATH=""
APP_PACKAGE=""
APP_ACTIVITY=""
FIXTURE_PATH=""
GRANT_PERMISSIONS=()
LAUNCH_APP=0
EXPECT_FAILURE=0
KEEP_ARTIFACTS=0
ARTIFACTS_DIR=""
BOOT_TIMEOUT="180"
FLOW_TIMEOUT="180"
GPU_MODE="auto"

EMULATOR_PID=""
EMULATOR_OWNED=0
MAESTRO_PID=""
SLEEP_PID=""
CLEANUP_DONE=0
TEMP_EMU_LOG=""
SERIAL=""
ADB_BIN=""

usage() {
  cat <<'USAGE'
Usage: platforms/android/verify-emulator.sh [options]

Boots an ephemeral dedicated test Android emulator (koe-test-api<N>), runs a
Maestro flow, and collects a 4-artifact forensics bundle on failure.

Options:
  --avd <name>              Dedicated test AVD matching ^koe-test-api[0-9]+$ (default: koe-test-api35)
  --port <even-int>         Emulator console port (default: 5580 -> emulator-5580)
  --reuse-serial <serial>   Attach to a running emulator-NNNN verified to be ^koe-test-api[0-9]+$
  --self-check              Verify boot properties and run smoke-system-settings.yaml
  --flow <path.yaml>        Run the specified Maestro YAML flow
  --apk <path.apk>          Install the specified APK via adb install -r before running the flow
  --app-package <pkg>       Target Android package name for app launch and host_intent_trace capture
  --app-activity <comp>     Launch component (default: <pkg>/.MainActivity when --app-package is set)
  --grant-permission <perm> Grant runtime permission via adb shell pm grant before launch (repeatable)
  --fixture <path.json>     Stage DEBUG snapshot fixture JSON into app files/koe-active-fixture.json
  --launch-app              Force-stop, clear trace, and am start -W -S the app with isolated workspace
  --expect-failure          Exit 0 only if the flow fails AND all 4 forensics artifacts are valid
  --keep-artifacts          Keep the 4-artifact bundle even when the flow passes
  --artifacts-dir <dir>     Output directory (default: <repo>/target/verify-artifacts/<run-id>)
  --boot-timeout <sec>      Emulator cold-boot timeout in seconds (default: 180)
  --flow-timeout <sec>      Maestro flow timeout in seconds (default: 180)
  --gpu <mode>              Emulator -gpu mode (default: auto)
  -h, --help                Show this help
USAGE
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

die_usage() {
  printf 'error: %s\n' "$*" >&2
  usage >&2
  exit 2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --avd)
      [[ $# -ge 2 ]] || die_usage "--avd requires a value"
      AVD_NAME="$2"
      AVD_EXPLICIT=1
      shift
      ;;
    --port)
      [[ $# -ge 2 ]] || die_usage "--port requires a value"
      PORT="$2"
      shift
      ;;
    --reuse-serial)
      [[ $# -ge 2 ]] || die_usage "--reuse-serial requires a value"
      REUSE_SERIAL="$2"
      shift
      ;;
    --self-check)
      SELF_CHECK=1
      ;;
    --flow)
      [[ $# -ge 2 ]] || die_usage "--flow requires a value"
      FLOW_PATH="$2"
      shift
      ;;
    --apk)
      [[ $# -ge 2 ]] || die_usage "--apk requires a value"
      APK_PATH="$2"
      shift
      ;;
    --app-package)
      [[ $# -ge 2 ]] || die_usage "--app-package requires a value"
      APP_PACKAGE="$2"
      shift
      ;;
    --app-activity)
      [[ $# -ge 2 ]] || die_usage "--app-activity requires a value"
      APP_ACTIVITY="$2"
      shift
      ;;
    --grant-permission)
      [[ $# -ge 2 ]] || die_usage "--grant-permission requires a value"
      GRANT_PERMISSIONS+=("$2")
      shift
      ;;
    --fixture)
      [[ $# -ge 2 ]] || die_usage "--fixture requires a value"
      FIXTURE_PATH="$2"
      shift
      ;;
    --launch-app)
      LAUNCH_APP=1
      ;;
    --expect-failure)
      EXPECT_FAILURE=1
      ;;
    --keep-artifacts)
      KEEP_ARTIFACTS=1
      ;;
    --artifacts-dir)
      [[ $# -ge 2 ]] || die_usage "--artifacts-dir requires a value"
      ARTIFACTS_DIR="$2"
      shift
      ;;
    --boot-timeout)
      [[ $# -ge 2 ]] || die_usage "--boot-timeout requires a value"
      BOOT_TIMEOUT="$2"
      shift
      ;;
    --flow-timeout)
      [[ $# -ge 2 ]] || die_usage "--flow-timeout requires a value"
      FLOW_TIMEOUT="$2"
      shift
      ;;
    --gpu)
      [[ $# -ge 2 ]] || die_usage "--gpu requires a value"
      GPU_MODE="$2"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die_usage "unknown option: $1"
      ;;
  esac
  shift
done

[[ "$AVD_NAME" =~ $TEST_AVD_REGEX ]] || die "refusing non-test AVD '$AVD_NAME'; AVD must match $TEST_AVD_REGEX"
[[ "$PORT" =~ ^[0-9]+$ ]] && (( PORT >= 5554 && PORT <= 65534 && PORT % 2 == 0 )) || die "--port must be an even integer in [5554, 65534]: $PORT"
[[ "$BOOT_TIMEOUT" =~ ^[1-9][0-9]*$ ]] || die "--boot-timeout must be a positive integer: $BOOT_TIMEOUT"
[[ "$FLOW_TIMEOUT" =~ ^[1-9][0-9]*$ ]] || die "--flow-timeout must be a positive integer: $FLOW_TIMEOUT"

if [[ -n "$REUSE_SERIAL" ]]; then
  [[ "$REUSE_SERIAL" =~ $EMULATOR_SERIAL_REGEX ]] || die "refusing non-emulator serial '$REUSE_SERIAL'; physical devices are forbidden"
fi

if [[ "$SELF_CHECK" -eq 1 && -n "$FLOW_PATH" ]]; then
  die_usage "--self-check and --flow are mutually exclusive"
elif [[ "$SELF_CHECK" -eq 1 ]]; then
  FLOW_PATH="$ROOT/platforms/android/tests/maestro/smoke-system-settings.yaml"
elif [[ -z "$FLOW_PATH" ]]; then
  die_usage "must specify either --self-check or --flow <path.yaml>"
fi

[[ -f "$FLOW_PATH" ]] || die "Maestro flow not found: $FLOW_PATH"
FLOW_PATH="$(python3 -c 'import os, sys; print(os.path.abspath(sys.argv[1]))' "$FLOW_PATH")"

if [[ -n "$APK_PATH" ]]; then
  [[ -f "$APK_PATH" ]] || die "APK not found: $APK_PATH"
  APK_PATH="$(python3 -c 'import os, sys; print(os.path.abspath(sys.argv[1]))' "$APK_PATH")"
fi

if [[ -n "$FIXTURE_PATH" ]]; then
  [[ -f "$FIXTURE_PATH" ]] || die "snapshot fixture not found: $FIXTURE_PATH"
  FIXTURE_PATH="$(python3 -c 'import os, sys; print(os.path.abspath(sys.argv[1]))' "$FIXTURE_PATH")"
  [[ "$LAUNCH_APP" -eq 1 ]] || die_usage "--fixture requires --launch-app"
fi

if [[ "$LAUNCH_APP" -eq 1 && -z "$APP_PACKAGE" ]]; then
  die_usage "--launch-app requires --app-package <pkg>"
fi

if [[ ${#GRANT_PERMISSIONS[@]} -gt 0 ]]; then
  [[ -n "$APP_PACKAGE" ]] || die_usage "--grant-permission requires --app-package <pkg>"
  for perm in "${GRANT_PERMISSIONS[@]}"; do
    [[ "$perm" =~ ^[A-Za-z0-9_.]+$ ]] || die "invalid --grant-permission value: $perm"
  done
fi

if [[ -n "$APP_PACKAGE" ]]; then
  [[ "$APP_PACKAGE" =~ ^[A-Za-z0-9._]+$ ]] || die "invalid --app-package value: $APP_PACKAGE"
  if [[ -z "$APP_ACTIVITY" ]]; then
    APP_ACTIVITY="${APP_PACKAGE}/.MainActivity"
  fi
fi

if [[ -n "$APP_ACTIVITY" ]]; then
  [[ "$APP_ACTIVITY" =~ ^[A-Za-z0-9._/$]+$ ]] || die "invalid --app-activity value: $APP_ACTIVITY"
fi

valid_java_home() {
  local dir="$1"
  # macOS ships a /usr/bin/java stub that exits non-zero when no JDK is installed.
  [[ -n "$dir" && -x "$dir/bin/java" ]] && "$dir/bin/java" -version >/dev/null 2>&1
}

resolve_java_home() {
  if [[ -n "${JAVA_HOME:-}" ]] && valid_java_home "$JAVA_HOME"; then
    printf '%s\n' "$JAVA_HOME"
    return 0
  fi

  local candidate=""
  if [[ -x /usr/libexec/java_home ]]; then
    candidate="$(/usr/libexec/java_home -v 17+ 2>/dev/null || true)"
    if valid_java_home "$candidate"; then
      printf '%s\n' "$candidate"
      return 0
    fi
  fi

  if command -v brew >/dev/null 2>&1; then
    local brew_jdk=""
    brew_jdk="$(brew --prefix openjdk@17 2>/dev/null || true)"
    if [[ -n "$brew_jdk" ]]; then
      candidate="$brew_jdk/libexec/openjdk.jdk/Contents/Home"
      if valid_java_home "$candidate"; then
        printf '%s\n' "$candidate"
        return 0
      fi
    fi
  fi

  die "working JDK 17+ not found; install with 'brew install openjdk@17' or set JAVA_HOME"
}

resolve_tool() {
  local override="$1"
  local sdk_rel="$2"
  local extra_candidate="$3"
  local name="$4"

  if [[ -n "$override" ]]; then
    [[ -x "$override" ]] || die "$name override is not executable: $override"
    printf '%s/%s\n' "$(cd "$(dirname "$override")" && pwd -P)" "$(basename "$override")"
    return 0
  fi

  if [[ -n "$sdk_rel" && -x "$ANDROID_SDK_ROOT/$sdk_rel" ]]; then
    printf '%s\n' "$ANDROID_SDK_ROOT/$sdk_rel"
    return 0
  fi

  if [[ -n "$extra_candidate" && -x "$extra_candidate" ]]; then
    printf '%s\n' "$extra_candidate"
    return 0
  fi

  local found=""
  if found="$(command -v "$name" 2>/dev/null)"; then
    printf '%s\n' "$found"
    return 0
  fi

  die "$name not found; run platforms/android/install-sdk-packages.sh or set KOE_$(printf '%s' "$name" | tr '[:lower:]' '[:upper:]')_BIN"
}

JAVA_HOME="$(resolve_java_home)"
export JAVA_HOME

ANDROID_SDK_ROOT="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-$HOME/Library/Android/sdk}}"
export ANDROID_SDK_ROOT
export ANDROID_HOME="$ANDROID_SDK_ROOT"
export ANDROID_AVD_HOME="${ANDROID_AVD_HOME:-$HOME/.android/avd}"

ADB_BIN="$(resolve_tool "${KOE_ADB_BIN:-}" "platform-tools/adb" "" "adb")"
MAESTRO_BIN="$(resolve_tool "${KOE_MAESTRO_BIN:-}" "" "$HOME/.maestro/bin/maestro" "maestro")"
EMULATOR_BIN=""
if [[ -z "$REUSE_SERIAL" ]]; then
  EMULATOR_BIN="$(resolve_tool "${KOE_EMULATOR_BIN:-}" "emulator/emulator" "" "emulator")"
fi

export PATH="$JAVA_HOME/bin:$(dirname "$ADB_BIN"):$PATH"

pid_alive() {
  local pid="$1"
  [[ -n "$pid" ]] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  local stat=""
  stat="$(ps -o stat= -p "$pid" 2>/dev/null | tr -d '[:space:]' || true)"
  [[ -n "$stat" && "$stat" != Z* ]]
}

interruptible_sleep() {
  # Waiting on a background sleep allows bash to dispatch trapped SIGTERM immediately.
  sleep "$1" &
  SLEEP_PID=$!
  wait "$SLEEP_PID" 2>/dev/null || true
  kill "$SLEEP_PID" 2>/dev/null || true
  SLEEP_PID=""
}

terminate_pgroup() {
  local pid="$1"
  local grace="${2:-3}"
  [[ -n "$pid" ]] || return 0

  kill -TERM -- "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
  local ticks=$(( grace * 5 ))
  local i=0
  while [[ $i -lt $ticks ]]; do
    if ! pid_alive "$pid"; then
      wait "$pid" 2>/dev/null || true
      kill -0 -- "-$pid" 2>/dev/null || return 0
    fi
    sleep 0.2
    i=$((i + 1))
  done

  if pid_alive "$pid" || kill -0 -- "-$pid" 2>/dev/null; then
    kill -KILL -- "-$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
    sleep 0.1
  fi
  wait "$pid" 2>/dev/null || true
}

cleanup() {
  if [[ "$CLEANUP_DONE" -eq 1 ]]; then
    return 0
  fi
  CLEANUP_DONE=1

  if [[ -n "$SLEEP_PID" ]]; then
    kill "$SLEEP_PID" 2>/dev/null || true
    SLEEP_PID=""
  fi

  if [[ -n "$MAESTRO_PID" ]]; then
    terminate_pgroup "$MAESTRO_PID" 2
    MAESTRO_PID=""
  fi

  if [[ "$EMULATOR_OWNED" -eq 1 && -n "$EMULATOR_PID" ]]; then
    if pid_alive "$EMULATOR_PID"; then
      if [[ -n "$ADB_BIN" && -n "$SERIAL" ]] && "$ADB_BIN" -s "$SERIAL" emu kill >/dev/null 2>&1; then
        local shutdown_timeout="${KOE_EMU_SHUTDOWN_TIMEOUT:-15}"
        local ticks=$(( shutdown_timeout * 5 ))
        local i=0
        while [[ $i -lt $ticks ]]; do
          if ! pid_alive "$EMULATOR_PID"; then
            break
          fi
          sleep 0.2
          i=$((i + 1))
        done
      fi
    fi

    if ! pid_alive "$EMULATOR_PID"; then
      wait "$EMULATOR_PID" 2>/dev/null || true
    fi
    if pid_alive "$EMULATOR_PID" || kill -0 -- "-$EMULATOR_PID" 2>/dev/null; then
      terminate_pgroup "$EMULATOR_PID" 3
    fi
    EMULATOR_PID=""

    # Wait for adb server transport deregistration so immediate back-to-back runs on the same port do not see a stale offline entry.
    if [[ -n "$ADB_BIN" && -n "$SERIAL" ]]; then
      local dereg_timeout="${KOE_ADB_DEREGISTER_TIMEOUT:-5}"
      local dereg_ticks=$(( dereg_timeout * 5 ))
      local j=0
      while [[ $j -lt $dereg_ticks ]]; do
        if ! "$ADB_BIN" devices 2>/dev/null | awk 'NR > 1 && NF >= 2 { print $1 }' | grep -Fxq "$SERIAL"; then
          break
        fi
        sleep 0.2
        j=$((j + 1))
      done
    fi
  fi

  if [[ -n "$TEMP_EMU_LOG" && -f "$TEMP_EMU_LOG" ]]; then
    rm -f "$TEMP_EMU_LOG" || true
  fi
}

on_term() {
  trap - INT TERM
  cleanup
  exit 143
}

on_int() {
  trap - INT TERM
  cleanup
  exit 130
}

trap cleanup EXIT
trap on_term TERM
trap on_int INT

adb_getprop() {
  "$ADB_BIN" -s "$1" shell getprop "$2" 2>/dev/null | tr -d '\r' | sed -n '1p'
}

verified_running_avd() {
  local serial="$1"
  local raw=""
  raw="$("$ADB_BIN" -s "$serial" emu avd name 2>/dev/null | tr -d '\r')" || return 1
  local name=""
  name="$(printf '%s\n' "$raw" | awk 'NF && $0 != "OK" { print; exit }')"
  [[ -n "$name" ]] || return 1
  printf '%s\n' "$name"
}

if [[ -n "$REUSE_SERIAL" ]]; then
  SERIAL="$REUSE_SERIAL"
  state="$("$ADB_BIN" -s "$SERIAL" get-state 2>/dev/null | tr -d '\r' || true)"
  [[ "$state" == "device" ]] || die "reused serial '$SERIAL' is not online (state='${state:-missing}')"

  running_avd="$(verified_running_avd "$SERIAL")" || die "failed to query AVD name for '$SERIAL'; refusing non-emulator target"
  [[ "$running_avd" =~ $TEST_AVD_REGEX ]] || die "refusing reused AVD '$running_avd' on $SERIAL; must match $TEST_AVD_REGEX"
  if [[ "$AVD_EXPLICIT" -eq 1 && "$running_avd" != "$AVD_NAME" ]]; then
    die "reused serial $SERIAL is running AVD '$running_avd', expected '$AVD_NAME'"
  fi
  AVD_NAME="$running_avd"

  booted="$(adb_getprop "$SERIAL" sys.boot_completed)"
  [[ "$booted" == "1" ]] || die "reused emulator $SERIAL has not completed boot (sys.boot_completed='${booted:-unset}')"
else
  SERIAL="emulator-${PORT}"
  if "$ADB_BIN" devices 2>/dev/null | awk 'NR > 1 && NF >= 2 { print $1 }' | grep -Fxq "$SERIAL"; then
    die "emulator serial $SERIAL is already running; choose another --port or use --reuse-serial $SERIAL"
  fi

  TEMP_EMU_LOG="$(mktemp "${TMPDIR:-/tmp}/koe-emulator-${PORT}.log.XXXXXX")"
  # os.setsid() places the emulator and its child processes in a dedicated process group for clean teardown.
  python3 -c 'import os, sys; os.setsid(); os.execvp(sys.argv[1], sys.argv[1:])' \
    "$EMULATOR_BIN" -avd "$AVD_NAME" -port "$PORT" \
    -no-window -no-audio -no-boot-anim -no-snapshot-load -no-snapshot-save \
    -gpu "$GPU_MODE" >"$TEMP_EMU_LOG" 2>&1 &
  EMULATOR_PID=$!
  EMULATOR_OWNED=1

  boot_deadline=$(( $(date +%s) + BOOT_TIMEOUT ))
  booted=""
  while true; do
    if ! pid_alive "$EMULATOR_PID"; then
      printf 'error: emulator exited prematurely before boot completed\n' >&2
      tail -n 40 "$TEMP_EMU_LOG" >&2 || true
      exit 1
    fi

    state="$("$ADB_BIN" -s "$SERIAL" get-state 2>/dev/null | tr -d '\r' || true)"
    if [[ "$state" == "device" ]]; then
      booted="$(adb_getprop "$SERIAL" sys.boot_completed)"
      if [[ "$booted" == "1" ]]; then
        break
      fi
    fi

    if [[ $(date +%s) -ge $boot_deadline ]]; then
      printf 'error: emulator %s (%s) did not complete boot within %ds\n' "$AVD_NAME" "$SERIAL" "$BOOT_TIMEOUT" >&2
      tail -n 40 "$TEMP_EMU_LOG" >&2 || true
      exit 1
    fi

    interruptible_sleep 0.5
  done
fi

API_LEVEL="$(adb_getprop "$SERIAL" ro.build.version.sdk)"
ABI="$(adb_getprop "$SERIAL" ro.product.cpu.abi)"
[[ -n "$API_LEVEL" ]] || die "failed to read ro.build.version.sdk from $SERIAL"
[[ -n "$ABI" ]] || die "failed to read ro.product.cpu.abi from $SERIAL"

RUN_ID="$(date -u '+%Y%m%dT%H%M%SZ')-$$"
ARTIFACTS_DIR_CREATED=0
if [[ -z "$ARTIFACTS_DIR" ]]; then
  ARTIFACTS_DIR="$ROOT/target/verify-artifacts/$RUN_ID"
else
  ARTIFACTS_DIR="$(python3 -c 'import os, sys; print(os.path.abspath(sys.argv[1]))' "$ARTIFACTS_DIR")"
fi
if [[ ! -d "$ARTIFACTS_DIR" ]]; then
  ARTIFACTS_DIR_CREATED=1
fi
MAESTRO_DEBUG_DIR="$ARTIFACTS_DIR/maestro_debug"
mkdir -p "$MAESTRO_DEBUG_DIR"

if ! start_ts_raw="$("$ADB_BIN" -s "$SERIAL" shell "date '+%Y-%m-%d %H:%M:%S.000'" 2>&1)"; then
  die "failed to capture device timestamp from $SERIAL: $start_ts_raw"
fi
START_TS="$(printf '%s\n' "$start_ts_raw" | tr -d '\r' | sed -n '1p')"
[[ -n "$START_TS" ]] || die "failed to capture device timestamp from $SERIAL"

if [[ -n "$APK_PATH" ]]; then
  "$ADB_BIN" -s "$SERIAL" install -r "$APK_PATH" >/dev/null
fi

if [[ ${#GRANT_PERMISSIONS[@]} -gt 0 ]]; then
  for perm in "${GRANT_PERMISSIONS[@]}"; do
    "$ADB_BIN" -s "$SERIAL" shell pm grant "$APP_PACKAGE" "$perm" >/dev/null 2>&1 || true
  done
fi

if [[ "$LAUNCH_APP" -eq 1 ]]; then
  WORKSPACE_REL="verify-workspaces/${RUN_ID}"
  "$ADB_BIN" -s "$SERIAL" shell "am force-stop $APP_PACKAGE" >/dev/null 2>&1 || true
  "$ADB_BIN" -s "$SERIAL" shell "run-as $APP_PACKAGE rm -f files/koe-trace.json files/koe-active-fixture.json" >/dev/null 2>&1 || true

  AM_START_CMD="am start -W -S -n $APP_ACTIVITY --es koe_workspace $WORKSPACE_REL"
  if [[ -n "$FIXTURE_PATH" ]]; then
    REMOTE_TMP_FIXTURE="/data/local/tmp/koe-fixture-${RUN_ID}.json"
    "$ADB_BIN" -s "$SERIAL" push "$FIXTURE_PATH" "$REMOTE_TMP_FIXTURE" >/dev/null
    "$ADB_BIN" -s "$SERIAL" shell "run-as $APP_PACKAGE sh -c 'mkdir -p files && cat > files/koe-active-fixture.json' < $REMOTE_TMP_FIXTURE"
    "$ADB_BIN" -s "$SERIAL" shell "rm -f $REMOTE_TMP_FIXTURE" >/dev/null 2>&1 || true
    AM_START_CMD="$AM_START_CMD --es koe_snapshot_fixture koe-active-fixture.json"
  fi

  "$ADB_BIN" -s "$SERIAL" shell "$AM_START_CMD" >/dev/null

  trace_wait_timeout="${KOE_TRACE_WAIT_TIMEOUT:-10}"
  trace_poll_interval="${KOE_TRACE_POLL_INTERVAL:-0.2}"
  trace_deadline=$(( $(date +%s) + trace_wait_timeout ))
  while true; do
    if "$ADB_BIN" -s "$SERIAL" shell "run-as $APP_PACKAGE sh -c 'test -s files/koe-trace.json'" >/dev/null 2>&1; then
      break
    fi
    if [[ $(date +%s) -ge $trace_deadline ]]; then
      printf 'warning: %s did not produce files/koe-trace.json within %ds\n' "$APP_PACKAGE" "$trace_wait_timeout" >&2
      break
    fi
    interruptible_sleep "$trace_poll_interval"
  done
fi

read -r STARTED_AT START_EPOCH < <(python3 -c 'import datetime, time; print(datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"), f"{time.time():.6f}")')

export MAESTRO_CLI_NO_ANALYTICS=1
export MAESTRO_CLI_ANALYSIS_NOTIFICATION_DISABLED=true

# Run Maestro inside MAESTRO_DEBUG_DIR so takeScreenshot outputs never pollute the repo root.
python3 -c 'import os, sys; os.setsid(); os.chdir(sys.argv[1]); os.execvp(sys.argv[2], sys.argv[2:])' \
  "$MAESTRO_DEBUG_DIR" \
  "$MAESTRO_BIN" test --udid "$SERIAL" --no-ansi --debug-output "$MAESTRO_DEBUG_DIR" "$FLOW_PATH" &
MAESTRO_PID=$!

FLOW_EXIT_CODE=0
flow_deadline=$(( $(date +%s) + FLOW_TIMEOUT ))
while pid_alive "$MAESTRO_PID"; do
  if [[ $(date +%s) -ge $flow_deadline ]]; then
    printf 'error: Maestro flow timed out after %ds: %s\n' "$FLOW_TIMEOUT" "$FLOW_PATH" >&2
    terminate_pgroup "$MAESTRO_PID" 3
    MAESTRO_PID=""
    FLOW_EXIT_CODE=124
    break
  fi
  interruptible_sleep 0.5
done

if [[ -n "$MAESTRO_PID" ]]; then
  wait "$MAESTRO_PID" || FLOW_EXIT_CODE=$?
  MAESTRO_PID=""
fi

read -r FINISHED_AT DURATION_SEC < <(python3 -c 'import datetime, sys, time; now = time.time(); print(datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"), f"{max(0.0, now - float(sys.argv[1])):.3f}")' "$START_EPOCH")

if [[ "$EXPECT_FAILURE" -eq 1 ]]; then
  if [[ "$FLOW_EXIT_CODE" -ne 0 ]]; then
    OUTCOME="expected_failure"
  else
    OUTCOME="unexpected_pass"
  fi
else
  if [[ "$FLOW_EXIT_CODE" -eq 0 ]]; then
    OUTCOME="pass"
  else
    OUTCOME="fail"
  fi
fi

collect_forensics() {
  local dir="$1"
  mkdir -p "$dir"

  "$ADB_BIN" -s "$SERIAL" exec-out screencap -p > "$dir/screen.png" 2>/dev/null || true

  local remote_xml="/sdcard/koe-window-hierarchy.xml"
  local dump_delay="${KOE_UIAUTOMATOR_RETRY_DELAY:-1}"
  local attempt
  # Retry because Maestro's accessibility driver can take ~1s to detach on Android 15.
  for attempt in 1 2 3; do
    rm -f "$dir/window_hierarchy.xml"
    "$ADB_BIN" -s "$SERIAL" shell rm -f "$remote_xml" >/dev/null 2>&1 || true
    if "$ADB_BIN" -s "$SERIAL" shell "uiautomator dump $remote_xml" >/dev/null 2>&1; then
      "$ADB_BIN" -s "$SERIAL" pull "$remote_xml" "$dir/window_hierarchy.xml" >/dev/null 2>&1 || true
    fi
    if [[ -s "$dir/window_hierarchy.xml" ]]; then
      break
    fi
    if [[ "$attempt" -lt 3 ]]; then
      sleep "$dump_delay"
    fi
  done
  "$ADB_BIN" -s "$SERIAL" shell rm -f "$remote_xml" >/dev/null 2>&1 || true

  {
    "$ADB_BIN" -s "$SERIAL" logcat -d -T "$START_TS" 2>&1 || true
    printf '\n=== crash buffer (since %s) ===\n' "$START_TS"
    "$ADB_BIN" -s "$SERIAL" logcat -b crash -d -T "$START_TS" 2>&1 || true
  } > "$dir/logcat.txt"

  if [[ -n "$TEMP_EMU_LOG" && -f "$TEMP_EMU_LOG" ]]; then
    cp "$TEMP_EMU_LOG" "$dir/emulator.log" 2>/dev/null || true
  fi

  local host_trace_raw=""
  if [[ -n "$APP_PACKAGE" ]]; then
    host_trace_raw="$dir/.host-trace.raw.json"
    rm -f "$host_trace_raw"
    "$ADB_BIN" -s "$SERIAL" shell "run-as $APP_PACKAGE cat files/koe-trace.json" 2>/dev/null | tr -d '\r' > "$host_trace_raw" || true
  fi

  python3 - "$dir/trace.json" \
    "$RUN_ID" "$AVD_NAME" "$SERIAL" "$API_LEVEL" "$ABI" "$FLOW_PATH" \
    "$STARTED_AT" "$FINISHED_AT" "$DURATION_SEC" "$FLOW_EXIT_CODE" "$OUTCOME" \
    "$dir/screen.png" "$dir/window_hierarchy.xml" "$dir/logcat.txt" "$MAESTRO_DEBUG_DIR" "$host_trace_raw" <<'PY'
import json
from pathlib import Path
import sys

(
    trace_path,
    run_id,
    avd,
    serial,
    api_level,
    abi,
    flow,
    started_at,
    finished_at,
    duration_sec,
    flow_exit_code,
    outcome,
    screen_path,
    hierarchy_path,
    logcat_path,
    maestro_debug_dir,
    host_trace_raw_path,
) = sys.argv[1:18]

host_intent_trace = None
if host_trace_raw_path:
    raw_file = Path(host_trace_raw_path)
    if raw_file.is_file() and raw_file.stat().st_size > 0:
        try:
            parsed = json.loads(raw_file.read_text(encoding="utf-8"))
            if isinstance(parsed, list):
                host_intent_trace = parsed
        except Exception:
            host_intent_trace = None

payload = {
    "run_id": run_id,
    "avd": avd,
    "serial": serial,
    "api_level": api_level,
    "abi": abi,
    "flow": flow,
    "started_at": started_at,
    "finished_at": finished_at,
    "duration_sec": float(duration_sec),
    "flow_exit_code": int(flow_exit_code),
    "outcome": outcome,
    "artifacts": {
        "screen": screen_path,
        "window_hierarchy": hierarchy_path,
        "logcat": logcat_path,
        "maestro_debug_dir": maestro_debug_dir,
    },
    "host_intent_trace": host_intent_trace,
}
Path(trace_path).write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
PY
  if [[ -n "$host_trace_raw" && -f "$host_trace_raw" ]]; then
    rm -f "$host_trace_raw" || true
  fi
}

validate_forensics_bundle() {
  local dir="$1"
  local missing=()
  local name
  for name in screen.png window_hierarchy.xml logcat.txt trace.json; do
    if [[ ! -s "$dir/$name" ]]; then
      missing+=("$name")
    fi
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    printf 'error: incomplete forensics bundle in %s; missing or empty: %s\n' "$dir" "${missing[*]}" >&2
    return 1
  fi
  python3 -c 'import json, sys; data = json.load(open(sys.argv[1], encoding="utf-8")); assert isinstance(data, dict)' "$dir/trace.json"
}

SHOULD_COLLECT=0
if [[ "$FLOW_EXIT_CODE" -ne 0 || "$EXPECT_FAILURE" -eq 1 || "$KEEP_ARTIFACTS" -eq 1 ]]; then
  SHOULD_COLLECT=1
fi

if [[ "$SHOULD_COLLECT" -eq 1 ]]; then
  collect_forensics "$ARTIFACTS_DIR"
fi

if [[ "$EXPECT_FAILURE" -eq 1 ]]; then
  if [[ "$FLOW_EXIT_CODE" -eq 0 ]]; then
    printf 'error: --expect-failure failed because flow passed (artifacts: %s)\n' "$ARTIFACTS_DIR" >&2
    exit 1
  fi
  validate_forensics_bundle "$ARTIFACTS_DIR"
  printf 'verify-emulator: expected failure confirmed with complete 4-artifact forensics (%s)\n' "$ARTIFACTS_DIR"
  exit 0
fi

if [[ "$FLOW_EXIT_CODE" -eq 0 ]]; then
  if [[ "$KEEP_ARTIFACTS" -eq 1 ]]; then
    validate_forensics_bundle "$ARTIFACTS_DIR"
    printf 'verify-emulator: PASS (avd=%s, api=%s, abi=%s, artifacts=%s)\n' "$AVD_NAME" "$API_LEVEL" "$ABI" "$ARTIFACTS_DIR"
  else
    if [[ "$ARTIFACTS_DIR_CREATED" -eq 1 ]]; then
      rm -rf "$ARTIFACTS_DIR" || true
    fi
    printf 'verify-emulator: PASS (avd=%s, api=%s, abi=%s)\n' "$AVD_NAME" "$API_LEVEL" "$ABI"
  fi
  exit 0
fi

printf 'verify-emulator: FAIL (exit=%d, avd=%s, artifacts=%s)\n' "$FLOW_EXIT_CODE" "$AVD_NAME" "$ARTIFACTS_DIR" >&2
exit "$FLOW_EXIT_CODE"
