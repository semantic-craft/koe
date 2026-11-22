#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
IOS_DIR="$ROOT/platforms/ios"
PROJECT_SPEC="$IOS_DIR/project.yml"
XCODEPROJ_DIR="${KOE_IOS_PROJECT_DIR:-$IOS_DIR}"
XCODEPROJ_PATH="$XCODEPROJ_DIR/KoeiOS.xcodeproj"
BUNDLE_ID="com.semanticcraft.koe.ios"
SCHEME="KoeiOSApp"
DEFAULT_FIXTURE="$IOS_DIR/Tests/Fixtures/ios-rich-snapshot.json"
LIVE_FLOW="$IOS_DIR/Tests/maestro/smoke-ios-live.yaml"
FIXTURE_FLOW="$IOS_DIR/Tests/maestro/smoke-ios-fixture.yaml"

SELF_CHECK=0
FLOW_PATH=""
EXPECT_FAILURE=0
FIXTURE_PATH=""
EXPLICIT_UDID=""
SLIM=0
SLIM_PROFILE="$IOS_DIR/simslim-koe.json"
WORKSPACE=""
SEED=""
RESTART_FLOW=""
SKIP_BUILD=0
KEEP_ARTIFACTS=0
ARTIFACTS_DIR=""
FLOW_TIMEOUT="180"

UDID=""
DEVICE_NAME=""
BOOTED_BY_SCRIPT=0
CLEANUP_DONE=0
XCRUN_BIN=""

usage() {
  cat <<'USAGE'
Usage: platforms/ios/verify-simulator.sh [options]

Builds KoeiOSApp, runs KoeiOSTests and/or Maestro flows on a dynamically
resolved iOS Simulator, and captures a 4-artifact forensics bundle on failure
(or when --keep-artifacts is passed).

Options:
  --self-check            Run KoeiOSTests plus live and fixture Maestro flows
  --flow <path.yaml>      Run a single Maestro YAML flow
  --expect-failure        Exit 0 only if the flow fails AND all 4 artifacts exist
  --fixture <path.json>   Inject a DEBUG HostSnapshot fixture JSON into the app
  --slim                  Apply simslim on an owned or explicitly selected simulator; retain metrics
  --slim-profile <path>   Select a simslim JSON profile
  --seed <file.json>      Initialize a new verification workspace from Rust product-store data
  --restart-flow <yaml>   Force-stop and relaunch in the same workspace, collect sibling restart bundle
  --workspace <dir>       Reuse a workspace (absolute or under Documents/verify-workspaces)
  --udid <udid>           Target a specific available iOS Simulator UDID
  --skip-build            Reuse existing Koe.app without regenerating/building
  --keep-artifacts        Keep 4-artifact forensics bundle even on pass
  --artifacts-dir <dir>   Output directory (default: target/verify-artifacts/ios-<run-id>)
  --flow-timeout <sec>    Maestro flow timeout in seconds (default: 180)
  -h, --help              Show this help
USAGE
}

export MOBILE_E2E_LOG_PREFIX="ios verify-simulator error"
# shellcheck source=scripts/lib/java-env.sh
source "$ROOT/scripts/lib/java-env.sh"
# shellcheck source=scripts/lib/mobile-e2e-common.sh
source "$ROOT/scripts/lib/mobile-e2e-common.sh"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --self-check)
      SELF_CHECK=1
      ;;
    --flow)
      [[ $# -ge 2 ]] || die_usage "--flow requires a value"
      FLOW_PATH="$2"
      shift
      ;;
    --expect-failure)
      EXPECT_FAILURE=1
      ;;
    --fixture)
      [[ $# -ge 2 ]] || die_usage "--fixture requires a value"
      FIXTURE_PATH="$2"
      shift
      ;;
    --slim) SLIM=1 ;;
    --slim-profile)
      [[ $# -ge 2 ]] || die_usage "--slim-profile requires a path"
      SLIM_PROFILE="$2"
      shift ;;
    --seed)
      [[ $# -ge 2 && -f "$2" ]] || die_usage "--seed requires an existing JSON file"
      SEED="$2"
      shift ;;
    --restart-flow)
      [[ $# -ge 2 && -f "$2" ]] || die_usage "--restart-flow requires an existing flow"
      RESTART_FLOW="$(abs_path "$2")"
      shift ;;
    --workspace)
      [[ $# -ge 2 && -n "$2" ]] || die_usage "--workspace requires a directory"
      WORKSPACE="$2"
      shift ;;
    --udid)
      [[ $# -ge 2 ]] || die_usage "--udid requires a value"
      EXPLICIT_UDID="$2"
      shift
      ;;
    --skip-build)
      SKIP_BUILD=1
      ;;
    --keep-artifacts)
      KEEP_ARTIFACTS=1
      ;;
    --artifacts-dir)
      [[ $# -ge 2 ]] || die_usage "--artifacts-dir requires a value"
      ARTIFACTS_DIR="$2"
      shift
      ;;
    --flow-timeout)
      [[ $# -ge 2 ]] || die_usage "--flow-timeout requires a value"
      FLOW_TIMEOUT="$2"
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


[[ "$FLOW_TIMEOUT" =~ ^[1-9][0-9]*$ ]] || die "--flow-timeout must be a positive integer: $FLOW_TIMEOUT"

if [[ "$SELF_CHECK" -eq 1 && -n "$FLOW_PATH" ]]; then
  die_usage "--self-check and --flow are mutually exclusive"
elif [[ "$SELF_CHECK" -eq 0 && -z "$FLOW_PATH" ]]; then
  die_usage "must specify either --self-check or --flow <path.yaml>"
fi

if [[ "$SELF_CHECK" -eq 1 && "$EXPECT_FAILURE" -eq 1 ]]; then
  die_usage "--expect-failure cannot be combined with --self-check"
fi

if [[ -n "$FLOW_PATH" ]]; then
  [[ -f "$FLOW_PATH" ]] || die "Maestro flow not found: $FLOW_PATH"
  FLOW_PATH="$(abs_path "$FLOW_PATH")"
fi

if [[ -n "$FIXTURE_PATH" ]]; then
  [[ -f "$FIXTURE_PATH" ]] || die "snapshot fixture not found: $FIXTURE_PATH"
  FIXTURE_PATH="$(abs_path "$FIXTURE_PATH")"
fi

JAVA_HOME="$(resolve_java_home)" \
  || die "working JDK 17+ not found for Maestro; install openjdk@17 or set JAVA_HOME"
export JAVA_HOME
export PATH="$JAVA_HOME/bin:$PATH"

XCRUN_BIN="$(resolve_tool "${KOE_XCRUN_BIN:-}" "xcrun")"
MAESTRO_BIN="$(resolve_tool "${KOE_MAESTRO_BIN:-}" "maestro" "$HOME/.maestro/bin/maestro")"
XCODEGEN_BIN=""
XCODEBUILD_BIN=""
if [[ "$SKIP_BUILD" -eq 0 || "$SELF_CHECK" -eq 1 ]]; then
  XCODEGEN_BIN="$(resolve_tool "${KOE_XCODEGEN_BIN:-}" "xcodegen")"
  XCODEBUILD_BIN="$(resolve_tool "${KOE_XCODEBUILD_BIN:-}" "xcodebuild")"
fi

SIM_LIB="${KOE_IOS_SIM_LIB:-$ROOT/target/ios/simulator/libkoe_host_api.a}"
DERIVED_DATA="${KOE_IOS_DERIVED_DATA:-$ROOT/target/ios-derived}"
APP_PATH="$DERIVED_DATA/Build/Products/Debug-iphonesimulator/Koe.app"
FORENSICS_TIMEOUT="${KOE_IOS_FORENSICS_TIMEOUT:-15}"

run_with_timeout() {
  local timeout_sec="$1"
  local stdout_file="$2"
  local stderr_file="$3"
  shift 3

  python3 - "$timeout_sec" "$stdout_file" "$stderr_file" "$@" <<'PY'
import os
import signal
import subprocess
import sys

timeout_sec = float(sys.argv[1])
stdout_path = sys.argv[2]
stderr_path = sys.argv[3]
cmd = sys.argv[4:]

out_f = open(stdout_path, "wb") if stdout_path else subprocess.DEVNULL
if stderr_path == "__STDOUT__":
    err_f = subprocess.STDOUT
elif stderr_path:
    err_f = open(stderr_path, "wb")
else:
    err_f = subprocess.DEVNULL

proc = subprocess.Popen(cmd, stdout=out_f, stderr=err_f, start_new_session=True)
try:
    rc = proc.wait(timeout=timeout_sec)
except subprocess.TimeoutExpired:
    try:
        os.killpg(proc.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    try:
        proc.wait(timeout=2)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        proc.wait(timeout=2)
    rc = 124
finally:
    if stdout_path and out_f not in (subprocess.DEVNULL, None):
        out_f.close()
    if stderr_path and stderr_path != "__STDOUT__" and err_f not in (subprocess.DEVNULL, subprocess.STDOUT, None):
        err_f.close()

sys.exit(rc)
PY
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

  if [[ "$BOOTED_BY_SCRIPT" -eq 1 && -n "$UDID" && -n "$XCRUN_BIN" ]]; then
    "$XCRUN_BIN" simctl shutdown "$UDID" >/dev/null 2>&1 || true
  fi
}

trap cleanup EXIT
trap on_term TERM
trap on_int INT

resolve_simulator() {
  local devices_json=""
  devices_json="$("$XCRUN_BIN" simctl list devices available -j)" || die "failed to query available iOS simulators"

  python3 - "${1:-$EXPLICIT_UDID}" "$devices_json" <<'PY'
import json
import sys

explicit_udid = sys.argv[1]
payload = json.loads(sys.argv[2])
devices_by_runtime = payload.get("devices", {})

candidates = []
for runtime, devices in devices_by_runtime.items():
    if "iOS" not in runtime:
        continue
    for dev in devices:
        if not dev.get("isAvailable", True):
            continue
        name = dev.get("name", "")
        udid = dev.get("udid", "")
        state = dev.get("state", "Shutdown")
        if explicit_udid:
            if udid == explicit_udid:
                print(f"{udid}\t{state}\t{name}")
                sys.exit(0)
            continue
        if "iPhone" not in name:
            continue
        if name == "iPhone 17":
            tier = 0
        elif name == "iPhone 16":
            tier = 1
        elif name.startswith("iPhone 17") or name.startswith("iPhone 16"):
            tier = 2
        elif "Duo" in name:
            tier = 4
        else:
            tier = 3
        boot_rank = 0 if state == "Booted" else 1
        candidates.append((tier, boot_rank, runtime, name, udid, state))

if explicit_udid:
    sys.stderr.write(f"available iOS simulator with UDID '{explicit_udid}' not found\n")
    sys.exit(1)

if not candidates:
    sys.stderr.write("no available iPhone simulator found in xcrun simctl list\n")
    sys.exit(1)

candidates.sort(key=lambda item: (item[0], item[1], item[3]))
_, _, _, name, udid, state = candidates[0]
print(f"{udid}\t{state}\t{name}")
PY
}

SIM_INFO="$(resolve_simulator)" || exit 1
IFS=$'\t' read -r UDID INITIAL_STATE DEVICE_NAME <<< "$SIM_INFO"
[[ -n "$UDID" ]] || die "failed to resolve iOS simulator UDID"

RUN_ID="$(date -u '+%Y%m%dT%H%M%SZ')-$$"
ARTIFACTS_DIR_CREATED=0
if [[ -z "$ARTIFACTS_DIR" ]]; then
  ARTIFACTS_DIR="$ROOT/target/verify-artifacts/ios-$RUN_ID"
else
  ARTIFACTS_DIR="$(abs_path "$ARTIFACTS_DIR")"
fi
if [[ ! -d "$ARTIFACTS_DIR" ]]; then
  ARTIFACTS_DIR_CREATED=1
fi

boot_start=$SECONDS
if [[ "$INITIAL_STATE" != "Booted" ]]; then
  if [[ "$INITIAL_STATE" != "Booting" ]]; then
    if "$XCRUN_BIN" simctl boot "$UDID"; then
      BOOTED_BY_SCRIPT=1
    else
      boot_result=$?
      SIM_INFO="$(resolve_simulator "$UDID")" || exit "$boot_result"
      IFS=$'\t' read -r _ current_state _ <<< "$SIM_INFO"
      [[ "$current_state" == "Booted" || "$current_state" == "Booting" ]] || exit "$boot_result"
    fi
  fi
  "$XCRUN_BIN" simctl bootstatus "$UDID"
fi

if [[ "$SLIM" -eq 1 ]]; then
  mkdir -p "$ARTIFACTS_DIR"
  printf '%s\n' "$((SECONDS - boot_start))" > "$ARTIFACTS_DIR/boot-seconds.txt"
  slim_bin="${KOE_SIMSLIM_BIN:-$(command -v simslim || true)}"
  if [[ ! -x "$slim_bin" ]]; then
    printf 'warning: simslim unavailable; continuing with normal services\n' >&2
  elif [[ "$BOOTED_BY_SCRIPT" -eq 0 && -z "$EXPLICIT_UDID" ]]; then
    printf 'warning: skipping simslim on an implicitly selected booted simulator\n' >&2
  else
    "$slim_bin" on "$UDID" --no-reboot --profile "$SLIM_PROFILE"
    "$slim_bin" doctor "$UDID" --requires files-recents,siri
    "$slim_bin" measure "$UDID" --json > "$ARTIFACTS_DIR/simslim-metrics.json"
  fi
fi

ensure_app_built() {
  if [[ "$SKIP_BUILD" -eq 1 ]]; then
    return 0
  fi

  if [[ ! -f "$SIM_LIB" ]]; then
    "$IOS_DIR/build-native.sh" simulator
  fi

  "$XCODEGEN_BIN" generate --spec "$PROJECT_SPEC" --project "$XCODEPROJ_DIR"
  "$XCODEBUILD_BIN" \
    -project "$XCODEPROJ_PATH" \
    -scheme "$SCHEME" \
    -sdk iphonesimulator \
    -destination "platform=iOS Simulator,id=$UDID" \
    -derivedDataPath "$DERIVED_DATA" \
    build \
    CODE_SIGNING_ALLOWED=NO

  [[ -d "$APP_PATH" ]] || die "expected built simulator app missing: $APP_PATH"
}

run_unit_tests() {
  if [[ ! -f "$SIM_LIB" ]]; then
    "$IOS_DIR/build-native.sh" simulator
  fi
  if [[ ! -d "$XCODEPROJ_PATH" ]]; then
    "$XCODEGEN_BIN" generate --spec "$PROJECT_SPEC" --project "$XCODEPROJ_DIR"
  fi
  "$XCODEBUILD_BIN" \
    -project "$XCODEPROJ_PATH" \
    -scheme "$SCHEME" \
    -sdk iphonesimulator \
    -destination "platform=iOS Simulator,id=$UDID" \
    -derivedDataPath "$DERIVED_DATA" \
    -parallel-testing-enabled NO \
    test \
    CODE_SIGNING_ALLOWED=NO
}

collect_forensics() {
  local dir="$1"
  local container_dir="$2"
  local trace_src="$3"
  local maestro_debug_dir="$4"
  local log_window_sec="${5:-120}"
  local flow="$6"
  local flow_exit="$7"
  local outcome="$8"
  mkdir -p "$dir"

  rm -f "$dir/screen.png"
  run_with_timeout "$FORENSICS_TIMEOUT" "" "" \
    "$XCRUN_BIN" simctl io "$UDID" screenshot "$dir/screen.png" || true
  if [[ ! -s "$dir/screen.png" && -d "$maestro_debug_dir" ]]; then
    local fallback_png=""
    fallback_png="$(python3 - "$maestro_debug_dir" <<'PY'
from pathlib import Path
import sys

root = Path(sys.argv[1])
pngs = [p for p in root.rglob("*.png") if p.is_file() and p.stat().st_size > 0]
if pngs:
    pngs.sort(key=lambda p: p.stat().st_mtime, reverse=True)
    print(pngs[0])
PY
)"
    if [[ -n "$fallback_png" && -s "$fallback_png" ]]; then
      cp "$fallback_png" "$dir/screen.png" || true
    fi
  fi

  rm -f "$dir/view_hierarchy.txt"
  run_with_timeout "$FORENSICS_TIMEOUT" "$dir/view_hierarchy.txt" "" \
    "$MAESTRO_BIN" --udid "$UDID" hierarchy --no-ansi || true
  if [[ ! -s "$dir/view_hierarchy.txt" && -d "$maestro_debug_dir" ]]; then
    local fallback_dump=""
    fallback_dump="$(python3 - "$maestro_debug_dir" <<'PY'
from pathlib import Path
import sys

root = Path(sys.argv[1])
candidates = []
for pattern in ("screen-hierarchy/*.json", "*hierarchy*", "commands.json", "maestro.log"):
    for p in root.rglob(pattern):
        if p.is_file() and p.stat().st_size > 0:
            candidates.append(p)
if candidates:
    print(candidates[0])
PY
)"
    if [[ -n "$fallback_dump" && -s "$fallback_dump" ]]; then
      cp "$fallback_dump" "$dir/view_hierarchy.txt" || true
    fi
  fi

  rm -f "$dir/syslog.txt"
  run_with_timeout "$FORENSICS_TIMEOUT" "$dir/syslog.txt" "__STDOUT__" \
    "$XCRUN_BIN" simctl spawn "$UDID" log show --last "${log_window_sec}s" --style compact \
    --predicate 'process == "Koe" OR subsystem BEGINSWITH "com.semanticcraft.koe"' || true

  local host_trace_raw=""
  if [[ -n "$trace_src" && -s "$trace_src" ]]; then
    host_trace_raw="$trace_src"
  elif [[ -n "$container_dir" && -s "$container_dir/Documents/koe-trace.json" ]]; then
    host_trace_raw="$container_dir/Documents/koe-trace.json"
  fi

  write_forensics_trace \
    "$dir/trace.json" "ios" "$RUN_ID" "$flow" \
    "$flow_exit" "$outcome" \
    "$dir/screen.png" "$dir/view_hierarchy.txt" "$dir/syslog.txt" "$maestro_debug_dir" \
    "$host_trace_raw" \
    "udid=$UDID" "device_name=$DEVICE_NAME"
}

run_single_flow() {
  local flow="$1"
  local fixture="$2"
  local out_dir="$3"
  local label="$4"

  local debug_dir="$out_dir/maestro_debug"
  mkdir -p "$debug_dir"

  if [[ -d "$APP_PATH" && "$SKIP_BUILD" -eq 0 ]]; then
    "$XCRUN_BIN" simctl install "$UDID" "$APP_PATH"
  elif [[ -d "$APP_PATH" ]]; then
    "$XCRUN_BIN" simctl get_app_container "$UDID" "$BUNDLE_ID" data >/dev/null 2>&1 \
      || "$XCRUN_BIN" simctl install "$UDID" "$APP_PATH"
  fi

  local container_dir=""
  container_dir="$("$XCRUN_BIN" simctl get_app_container "$UDID" "$BUNDLE_ID" data)" \
    || die "app $BUNDLE_ID is not installed on simulator $UDID"

  local docs_dir="$container_dir/Documents"
  mkdir -p "$docs_dir"
  local workspace_dir="$docs_dir/verify-workspaces/${label}-$$"
  if [[ -n "$WORKSPACE" && ( "$SELF_CHECK" -eq 0 || -z "$fixture" ) ]]; then
    case "$WORKSPACE" in
      /*) workspace_dir="$WORKSPACE" ;;
      *) workspace_dir="$docs_dir/verify-workspaces/$WORKSPACE" ;;
    esac
  fi
  "$XCRUN_BIN" simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
  mkdir -p "$workspace_dir"
  if [[ -n "$SEED" ]]; then
    [[ ! -e "$workspace_dir/product-workspace.json" ]] || die "refusing to overwrite seeded workspace"
    cp "$SEED" "$workspace_dir/product-workspace.json"
  fi
  local log_start=$SECONDS
  local trace_file="$docs_dir/koe-trace.json"
  rm -f "$trace_file"

  if [[ -n "$RESTART_FLOW" ]]; then
    "$XCRUN_BIN" simctl privacy "$UDID" grant microphone "$BUNDLE_ID"
  fi
  local launch_args=(
    -koe-workspace "$workspace_dir"
    -koe-trace-output "$trace_file"
  )
  if [[ -n "$fixture" ]]; then
    local staged_fixture="$docs_dir/koe-active-fixture.json"
    cp "$fixture" "$staged_fixture"
    launch_args+=(-koe-snapshot-fixture "$staged_fixture")
    if [[ -n "$SEED" ]]; then launch_args+=(-koe-fixture-to-live); fi
  fi

  "$XCRUN_BIN" simctl launch "$UDID" "$BUNDLE_ID" "${launch_args[@]}" >/dev/null

  local wait_ticks=0
  while [[ ! -s "$trace_file" && $wait_ticks -lt 30 ]]; do
    interruptible_sleep 0.2
    wait_ticks=$((wait_ticks + 1))
  done

  local flow_exit=0
  run_maestro_with_timeout "$MAESTRO_BIN" "$UDID" "$debug_dir" "$flow" "$FLOW_TIMEOUT" || flow_exit=$?

  if [[ "$flow_exit" -eq 0 && "$flow" -ef "$LIVE_FLOW" ]]; then
    python3 - "$workspace_dir/product-workspace.json" <<'PYTHON' || flow_exit=$?
import json
import sys

with open(sys.argv[1], encoding="utf-8") as workspace:
    saved_model = json.load(workspace)["provider"]["model"]
if saved_model != "deepseek-v4-pro":
    sys.exit(f"iOS live settings persistence failed: saved model is {saved_model!r}")
print(f"iOS live settings persisted: {saved_model}")
PYTHON
  fi

  local outcome=""
  outcome="$(compute_flow_outcome "$flow_exit" "$EXPECT_FAILURE")"

  local should_collect=0
  if [[ "$flow_exit" -ne 0 || "$EXPECT_FAILURE" -eq 1 || "$KEEP_ARTIFACTS" -eq 1 ]]; then
    should_collect=1
  fi

  if [[ "$should_collect" -eq 1 ]]; then
    collect_forensics "$out_dir" "$container_dir" "$trace_file" "$debug_dir" \
      "$((SECONDS - log_start + 1))" "$flow" "$flow_exit" "$outcome"
    if [[ -n "$WORKSPACE" && -z "$fixture" ]]; then
      mkdir -p "$out_dir/workspace"
      cp "$workspace_dir/product-workspace.json" "$out_dir/workspace/"
      if [[ -d "$workspace_dir/audio" ]]; then cp -R "$workspace_dir/audio" "$out_dir/workspace/"; fi
    fi
  fi

  return "$flow_exit"
}

ensure_app_built

if [[ "$SELF_CHECK" -eq 1 ]]; then
  run_unit_tests

  [[ -f "$LIVE_FLOW" ]] || die "missing live smoke flow: $LIVE_FLOW"
  [[ -f "$FIXTURE_FLOW" ]] || die "missing fixture smoke flow: $FIXTURE_FLOW"
  [[ -f "$DEFAULT_FIXTURE" ]] || die "missing rich fixture JSON: $DEFAULT_FIXTURE"

  live_dir="$ARTIFACTS_DIR/live"
  fixture_dir="$ARTIFACTS_DIR/fixture"

  if ! run_single_flow "$LIVE_FLOW" "" "$live_dir" "live"; then
    validate_forensics_bundle "$live_dir" "view_hierarchy.txt" "syslog.txt" || true
    printf 'verify-simulator: FAIL (live flow failed, device=%s, udid=%s, artifacts=%s)\n' \
      "$DEVICE_NAME" "$UDID" "$live_dir" >&2
    exit 1
  fi

  if ! run_single_flow "$FIXTURE_FLOW" "$DEFAULT_FIXTURE" "$fixture_dir" "fixture"; then
    validate_forensics_bundle "$fixture_dir" "view_hierarchy.txt" "syslog.txt" || true
    printf 'verify-simulator: FAIL (fixture flow failed, device=%s, udid=%s, artifacts=%s)\n' \
      "$DEVICE_NAME" "$UDID" "$fixture_dir" >&2
    exit 1
  fi

  if [[ "$KEEP_ARTIFACTS" -eq 1 ]]; then
    validate_forensics_bundle "$live_dir" "view_hierarchy.txt" "syslog.txt"
    validate_forensics_bundle "$fixture_dir" "view_hierarchy.txt" "syslog.txt"
    printf 'verify-simulator: PASS (self-check, device=%s, udid=%s, artifacts=%s)\n' \
      "$DEVICE_NAME" "$UDID" "$ARTIFACTS_DIR"
  else
    if [[ "$ARTIFACTS_DIR_CREATED" -eq 1 && "$SLIM" -eq 0 ]]; then
      rm -rf "$ARTIFACTS_DIR" || true
    fi
    printf 'verify-simulator: PASS (self-check, device=%s, udid=%s)\n' "$DEVICE_NAME" "$UDID"
  fi
  exit 0
fi

flow_exit=0
run_single_flow "$FLOW_PATH" "$FIXTURE_PATH" "$ARTIFACTS_DIR" "flow" || flow_exit=$?

if [[ "$EXPECT_FAILURE" -eq 1 ]]; then
  if [[ "$flow_exit" -eq 0 ]]; then
    printf 'ios verify-simulator error: --expect-failure failed because flow passed (artifacts: %s)\n' \
      "$ARTIFACTS_DIR" >&2
    exit 1
  fi
  validate_forensics_bundle "$ARTIFACTS_DIR" "view_hierarchy.txt" "syslog.txt"
  printf 'verify-simulator: expected failure confirmed with complete 4-artifact forensics (%s)\n' \
    "$ARTIFACTS_DIR"
  exit 0
fi

if [[ "$flow_exit" -eq 0 && -n "$RESTART_FLOW" ]]; then
  SEED=""
  SKIP_BUILD=1
  restart_dir="$(dirname "$ARTIFACTS_DIR")/restart"
  run_single_flow "$RESTART_FLOW" "" "$restart_dir" restart
  validate_forensics_bundle "$restart_dir" "view_hierarchy.txt" "syslog.txt"
fi

if [[ "$flow_exit" -eq 0 ]]; then
  if [[ "$KEEP_ARTIFACTS" -eq 1 ]]; then
    validate_forensics_bundle "$ARTIFACTS_DIR" "view_hierarchy.txt" "syslog.txt"
    printf 'verify-simulator: PASS (device=%s, udid=%s, artifacts=%s)\n' \
      "$DEVICE_NAME" "$UDID" "$ARTIFACTS_DIR"
  else
    if [[ "$ARTIFACTS_DIR_CREATED" -eq 1 && "$SLIM" -eq 0 ]]; then
      rm -rf "$ARTIFACTS_DIR" || true
    fi
    printf 'verify-simulator: PASS (device=%s, udid=%s)\n' "$DEVICE_NAME" "$UDID"
  fi
  exit 0
fi

validate_forensics_bundle "$ARTIFACTS_DIR" "view_hierarchy.txt" "syslog.txt" || true
printf 'verify-simulator: FAIL (exit=%d, device=%s, udid=%s, artifacts=%s)\n' \
  "$flow_exit" "$DEVICE_NAME" "$UDID" "$ARTIFACTS_DIR" >&2
exit "$flow_exit"
