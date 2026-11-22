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
GPU_MODE=""
SLIM=0
WITH_AUDIO=0
WORKSPACE=""
SEED=""
RESTART_FLOW=""
GOLDEN=0
CLONED_AVD_HOME=""

EMULATOR_PID=""
EMULATOR_OWNED=0
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
  --slim                    Prefer host GPU and read-only avdslim_clean; retain metrics
  --with-audio              Enable emulator microphone and output
  --seed <file.json>      Initialize a new verification workspace from Rust product-store data
  --restart-flow <yaml>   Force-stop and relaunch in the same workspace, collect sibling restart bundle
  --workspace <dir>         Reuse this app-private verify-workspaces subdirectory
  --gpu <mode>              Emulator -gpu mode (default: auto)
  -h, --help                Show this help
USAGE
}

export MOBILE_E2E_LOG_PREFIX="error"
# shellcheck source=scripts/lib/java-env.sh
source "$ROOT/scripts/lib/java-env.sh"
# shellcheck source=scripts/lib/mobile-e2e-common.sh
source "$ROOT/scripts/lib/mobile-e2e-common.sh"

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
    --slim) SLIM=1 ;;
    --with-audio) WITH_AUDIO=1 ;;
    --seed)
      [[ $# -ge 2 && -f "$2" ]] || die_usage "--seed requires an existing JSON file"
      SEED="$2"
      shift ;;
    --restart-flow)
      [[ $# -ge 2 && -f "$2" ]] || die_usage "--restart-flow requires an existing flow"
      RESTART_FLOW="$(abs_path "$2")"
      shift ;;
    --workspace)
      [[ $# -ge 2 && "$2" =~ ^[a-zA-Z0-9_-]+(/[a-zA-Z0-9_-]+)*$ ]] || die_usage "--workspace requires a safe relative directory"
      WORKSPACE="$2"
      shift ;;
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
if [[ -n "$SEED" || -n "$RESTART_FLOW" ]]; then
  [[ -n "$WORKSPACE" && -n "$FLOW_PATH" && "$SELF_CHECK" -eq 0 ]] || die_usage "--seed and --restart-flow require --workspace and --flow"
fi
if [[ -n "$RESTART_FLOW" ]]; then KEEP_ARTIFACTS=1; fi


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
FLOW_PATH="$(abs_path "$FLOW_PATH")"

if [[ -n "$APK_PATH" ]]; then
  [[ -f "$APK_PATH" ]] || die "APK not found: $APK_PATH"
  APK_PATH="$(abs_path "$APK_PATH")"
fi

if [[ -n "$FIXTURE_PATH" ]]; then
  [[ -f "$FIXTURE_PATH" ]] || die "snapshot fixture not found: $FIXTURE_PATH"
  FIXTURE_PATH="$(abs_path "$FIXTURE_PATH")"
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

JAVA_HOME="$(resolve_java_home)" \
  || die "working JDK 17+ not found; install with 'brew install openjdk@17' or set JAVA_HOME"
export JAVA_HOME

ANDROID_SDK_ROOT="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-$HOME/Library/Android/sdk}}"
export ANDROID_SDK_ROOT
export ANDROID_HOME="$ANDROID_SDK_ROOT"
export ANDROID_AVD_HOME="${ANDROID_AVD_HOME:-$HOME/.android/avd}"

ADB_BIN="$(resolve_tool "${KOE_ADB_BIN:-}" "adb" "$ANDROID_SDK_ROOT/platform-tools/adb" "run platforms/android/install-sdk-packages.sh or set KOE_ADB_BIN")"
MAESTRO_BIN="$(resolve_tool "${KOE_MAESTRO_BIN:-}" "maestro" "$HOME/.maestro/bin/maestro" "run platforms/android/install-sdk-packages.sh or set KOE_MAESTRO_BIN")"
EMULATOR_BIN=""
if [[ -z "$REUSE_SERIAL" ]]; then
  EMULATOR_BIN="$(resolve_tool "${KOE_EMULATOR_BIN:-}" "emulator" "$ANDROID_SDK_ROOT/emulator/emulator" "run platforms/android/install-sdk-packages.sh or set KOE_EMULATOR_BIN")"
fi

ADB_DIR="$(dirname "$ADB_BIN")"
export PATH="$JAVA_HOME/bin:$ADB_DIR:$PATH"

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

  if [[ -n "$CLONED_AVD_HOME" ]]; then
    python3 -c 'import shutil,sys; shutil.rmtree(sys.argv[1])' "$CLONED_AVD_HOME"
  fi
  if [[ -n "$TEMP_EMU_LOG" && -f "$TEMP_EMU_LOG" ]]; then
    rm -f "$TEMP_EMU_LOG" || true
  fi
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

boot_start=$SECONDS
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
  boot_args=(-no-window -no-boot-anim -no-snapshot-save)
  if [[ "$WITH_AUDIO" -eq 0 ]]; then boot_args+=(-no-audio); fi
  snapshot_home="$ANDROID_AVD_HOME"
  snapshot_dir="$snapshot_home/$AVD_NAME.avd/snapshots/avdslim_clean"
  hardware="$snapshot_dir/hardware.ini"
  if [[ "$SLIM" -eq 1 && -d "$snapshot_dir" ]]; then
    GOLDEN=1
    if [[ "$WITH_AUDIO" -eq 1 ]]; then
      # Emulator hardware.ini serializes enabled booleans as true on some SDK versions.
      for key in audioInput audioOutput; do
        if [[ ! -f "$hardware" ]] || ! grep -Eiq "^[[:blank:]]*hw[.]${key}[[:blank:]]*=[[:blank:]]*(yes|true)[[:space:]]*$" "$hardware"; then
          GOLDEN=0
          break
        fi
      done
    fi
  fi
  if [[ "$WITH_AUDIO" -eq 1 || ( "$GOLDEN" -eq 1 && -f "$hardware" ) ]]; then
    CLONED_AVD_HOME="$(mktemp -d "$snapshot_home/.koe-verify-XXXXXX")"
    stage_args=("$snapshot_home" "$AVD_NAME" "$CLONED_AVD_HOME")
    if [[ "$WITH_AUDIO" -eq 1 ]]; then stage_args+=(--with-audio); fi
    python3 "$ROOT/platforms/android/stage-golden-avd.py" "${stage_args[@]}"
    export ANDROID_AVD_HOME="$CLONED_AVD_HOME"
  fi
  if [[ "$GOLDEN" -eq 1 ]]; then
    boot_args+=(-snapshot avdslim_clean -force-snapshot-load)
    if [[ -f "$hardware" ]]; then
      ram=$(awk '$1 == "hw.ramSize" && $2 == "=" {print $3}' "$hardware")
      if [[ "$ram" =~ ^[0-9]+$ ]]; then boot_args+=(-lowram -memory "$ram"); fi
    fi
  else
    boot_args+=(-no-snapshot-load)
  fi
  if [[ "$SLIM" -eq 1 ]]; then GPU_MODE="${GPU_MODE:-host}"; fi
  python3 -c 'import os, sys; os.setsid(); os.execvp(sys.argv[1], sys.argv[1:])' \
    "$EMULATOR_BIN" -avd "$AVD_NAME" -port "$PORT" \
    "${boot_args[@]}" \
    -gpu "${GPU_MODE:-auto}" >"$TEMP_EMU_LOG" 2>&1 &
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

boot_seconds=$((SECONDS - boot_start))
API_LEVEL="$(adb_getprop "$SERIAL" ro.build.version.sdk)"
ABI="$(adb_getprop "$SERIAL" ro.product.cpu.abi)"
[[ -n "$API_LEVEL" ]] || die "failed to read ro.build.version.sdk from $SERIAL"
[[ -n "$ABI" ]] || die "failed to read ro.product.cpu.abi from $SERIAL"

RUN_ID="$(date -u '+%Y%m%dT%H%M%SZ')-$$"
ARTIFACTS_DIR_CREATED=0
if [[ -z "$ARTIFACTS_DIR" ]]; then
  ARTIFACTS_DIR="$ROOT/target/verify-artifacts/$RUN_ID"
else
  ARTIFACTS_DIR="$(abs_path "$ARTIFACTS_DIR")"
fi
if [[ ! -d "$ARTIFACTS_DIR" ]]; then
  ARTIFACTS_DIR_CREATED=1
fi
MAESTRO_DEBUG_DIR="$ARTIFACTS_DIR/maestro_debug"
mkdir -p "$MAESTRO_DEBUG_DIR"
if [[ "$SLIM" -eq 1 ]]; then
  printf '%s\n' "$boot_seconds" > "$ARTIFACTS_DIR/boot-seconds.txt"
  slim_bin="${KOE_AVDSLIM_BIN:-$(command -v avdslim || true)}"
  if [[ ! -x "$slim_bin" ]]; then
    printf 'warning: avdslim unavailable; continuing with lightweight boot flags\n' >&2
  else
    if [[ "$GOLDEN" -eq 0 && "$EMULATOR_OWNED" -eq 1 ]]; then
      "$slim_bin" on "$SERIAL" --skip=bluetooth --no-anim
    fi
    "$slim_bin" measure "$SERIAL" > "$ARTIFACTS_DIR/avdslim-metrics.txt"
  fi
fi

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
  WORKSPACE_REL="verify-workspaces/${WORKSPACE:-$RUN_ID}"
  "$ADB_BIN" -s "$SERIAL" shell "am force-stop $APP_PACKAGE" >/dev/null 2>&1 || true
  "$ADB_BIN" -s "$SERIAL" shell "run-as $APP_PACKAGE rm -f files/koe-trace.json files/koe-active-fixture.json" >/dev/null 2>&1 || true

  if [[ -n "$SEED" ]]; then
    "$ADB_BIN" -s "$SERIAL" shell "run-as $APP_PACKAGE mkdir -p files/$WORKSPACE_REL"
    "$ADB_BIN" -s "$SERIAL" shell -T "run-as $APP_PACKAGE sh -c 'set -C; cat > files/$WORKSPACE_REL/product-workspace.json'" < "$SEED"
  fi
  AM_START_CMD="am start -W -S -n $APP_ACTIVITY --es koe_workspace $WORKSPACE_REL"
  if [[ -n "$FIXTURE_PATH" ]]; then
    REMOTE_TMP_FIXTURE="/data/local/tmp/koe-fixture-${RUN_ID}.json"
    "$ADB_BIN" -s "$SERIAL" push "$FIXTURE_PATH" "$REMOTE_TMP_FIXTURE" >/dev/null
    "$ADB_BIN" -s "$SERIAL" shell "run-as $APP_PACKAGE sh -c 'mkdir -p files && cat > files/koe-active-fixture.json' < $REMOTE_TMP_FIXTURE"
    "$ADB_BIN" -s "$SERIAL" shell "rm -f $REMOTE_TMP_FIXTURE" >/dev/null 2>&1 || true
    AM_START_CMD="$AM_START_CMD --es koe_snapshot_fixture koe-active-fixture.json"
    if [[ -n "$SEED" ]]; then AM_START_CMD="$AM_START_CMD --ez koe_fixture_to_live true"; fi
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

FLOW_EXIT_CODE=0
run_maestro_with_timeout "$MAESTRO_BIN" "$SERIAL" "$MAESTRO_DEBUG_DIR" "$FLOW_PATH" "$FLOW_TIMEOUT" || FLOW_EXIT_CODE=$?
OUTCOME="$(compute_flow_outcome "$FLOW_EXIT_CODE" "$EXPECT_FAILURE")"

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

  write_forensics_trace \
    "$dir/trace.json" "android" "$RUN_ID" "$FLOW_PATH" \
    "$FLOW_EXIT_CODE" "$OUTCOME" \
    "$dir/screen.png" "$dir/window_hierarchy.xml" "$dir/logcat.txt" "$MAESTRO_DEBUG_DIR" \
    "$host_trace_raw" \
    "avd=$AVD_NAME" "serial=$SERIAL" "api_level=$API_LEVEL" "abi=$ABI"
  if [[ -n "$host_trace_raw" && -f "$host_trace_raw" ]]; then
    rm -f "$host_trace_raw"
  fi
  if [[ -n "$WORKSPACE" && "$LAUNCH_APP" -eq 1 && -z "$FIXTURE_PATH" ]]; then
    mkdir -p "$dir/workspace/audio"
    "$ADB_BIN" -s "$SERIAL" exec-out run-as "$APP_PACKAGE" cat "files/$WORKSPACE_REL/product-workspace.json" > "$dir/workspace/product-workspace.json"
    local wav
    while IFS= read -r wav; do
      wav="${wav%$'\r'}"
      [[ "$wav" =~ ^[a-zA-Z0-9-]+\.wav$ ]] || continue
      "$ADB_BIN" -s "$SERIAL" exec-out run-as "$APP_PACKAGE" cat "files/$WORKSPACE_REL/audio/$wav" > "$dir/workspace/audio/$wav"
    done < <("$ADB_BIN" -s "$SERIAL" shell run-as "$APP_PACKAGE" ls "files/$WORKSPACE_REL/audio" 2>/dev/null)
  fi
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
  validate_forensics_bundle "$ARTIFACTS_DIR" "window_hierarchy.xml" "logcat.txt"
  printf 'verify-emulator: expected failure confirmed with complete 4-artifact forensics (%s)\n' "$ARTIFACTS_DIR"
  exit 0
fi

if [[ "$FLOW_EXIT_CODE" -eq 0 && -n "$RESTART_FLOW" ]]; then
  "$ROOT/platforms/android/verify-emulator.sh" --reuse-serial "$SERIAL" --flow "$RESTART_FLOW" --workspace "$WORKSPACE" \
    --app-package "$APP_PACKAGE" --app-activity "$APP_ACTIVITY" --launch-app --keep-artifacts \
    --flow-timeout "$FLOW_TIMEOUT" --artifacts-dir "$(dirname "$ARTIFACTS_DIR")/restart"
fi
if [[ "$FLOW_EXIT_CODE" -eq 0 ]]; then
  if [[ "$KEEP_ARTIFACTS" -eq 1 ]]; then
    validate_forensics_bundle "$ARTIFACTS_DIR" "window_hierarchy.xml" "logcat.txt"
    printf 'verify-emulator: PASS (avd=%s, api=%s, abi=%s, artifacts=%s)\n' "$AVD_NAME" "$API_LEVEL" "$ABI" "$ARTIFACTS_DIR"
  else
    if [[ "$ARTIFACTS_DIR_CREATED" -eq 1 && "$SLIM" -eq 0 ]]; then
      rm -rf "$ARTIFACTS_DIR" || true
    fi
    printf 'verify-emulator: PASS (avd=%s, api=%s, abi=%s)\n' "$AVD_NAME" "$API_LEVEL" "$ABI"
  fi
  exit 0
fi

printf 'verify-emulator: FAIL (exit=%d, avd=%s, artifacts=%s)\n' "$FLOW_EXIT_CODE" "$AVD_NAME" "$ARTIFACTS_DIR" >&2
exit "$FLOW_EXIT_CODE"
