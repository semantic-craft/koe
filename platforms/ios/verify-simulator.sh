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
SKIP_BUILD=0
KEEP_ARTIFACTS=0
ARTIFACTS_DIR=""
FLOW_TIMEOUT="180"

UDID=""
DEVICE_NAME=""
BOOTED_BY_SCRIPT=0
CLEANUP_DONE=0
MAESTRO_PID=""
SLEEP_PID=""
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
  --udid <udid>           Target a specific available iOS Simulator UDID
  --skip-build            Reuse existing Koe.app without regenerating/building
  --keep-artifacts        Keep 4-artifact forensics bundle even on pass
  --artifacts-dir <dir>   Output directory (default: target/verify-artifacts/ios-<run-id>)
  --flow-timeout <sec>    Maestro flow timeout in seconds (default: 180)
  -h, --help              Show this help
USAGE
}

die() {
  printf 'ios verify-simulator error: %s\n' "$*" >&2
  exit 1
}

die_usage() {
  printf 'ios verify-simulator error: %s\n' "$*" >&2
  usage >&2
  exit 2
}

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
  FLOW_PATH="$(python3 -c 'import os, sys; print(os.path.abspath(sys.argv[1]))' "$FLOW_PATH")"
fi

if [[ -n "$FIXTURE_PATH" ]]; then
  [[ -f "$FIXTURE_PATH" ]] || die "snapshot fixture not found: $FIXTURE_PATH"
  FIXTURE_PATH="$(python3 -c 'import os, sys; print(os.path.abspath(sys.argv[1]))' "$FIXTURE_PATH")"
fi

valid_java_home() {
  local dir="$1"
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
    local formula brew_jdk
    for formula in openjdk@17 openjdk; do
      brew_jdk="$(brew --prefix "$formula" 2>/dev/null || true)"
      if [[ -n "$brew_jdk" ]]; then
        candidate="$brew_jdk/libexec/openjdk.jdk/Contents/Home"
        if valid_java_home "$candidate"; then
          printf '%s\n' "$candidate"
          return 0
        fi
      fi
    done
  fi

  die "working JDK 17+ not found for Maestro; install openjdk@17 or set JAVA_HOME"
}

resolve_tool() {
  local override="$1"
  local extra_candidate="$2"
  local name="$3"

  if [[ -n "$override" ]]; then
    [[ -x "$override" ]] || die "$name override is not executable: $override"
    printf '%s/%s\n' "$(cd "$(dirname "$override")" && pwd -P)" "$(basename "$override")"
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

  die "$name not found; install $name or set KOE_$(printf '%s' "$name" | tr '[:lower:]' '[:upper:]')_BIN"
}

JAVA_HOME="$(resolve_java_home)"
export JAVA_HOME
export PATH="$JAVA_HOME/bin:$PATH"

XCRUN_BIN="$(resolve_tool "${KOE_XCRUN_BIN:-}" "" "xcrun")"
MAESTRO_BIN="$(resolve_tool "${KOE_MAESTRO_BIN:-}" "$HOME/.maestro/bin/maestro" "maestro")"
XCODEGEN_BIN=""
XCODEBUILD_BIN=""
if [[ "$SKIP_BUILD" -eq 0 || "$SELF_CHECK" -eq 1 ]]; then
  XCODEGEN_BIN="$(resolve_tool "${KOE_XCODEGEN_BIN:-}" "" "xcodegen")"
  XCODEBUILD_BIN="$(resolve_tool "${KOE_XCODEBUILD_BIN:-}" "" "xcodebuild")"
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

pid_alive() {
  local pid="$1"
  [[ -n "$pid" ]] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  local stat=""
  stat="$(ps -o stat= -p "$pid" 2>/dev/null | tr -d '[:space:]' || true)"
  [[ -n "$stat" && "$stat" != Z* ]]
}

interruptible_sleep() {
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

  if [[ "$BOOTED_BY_SCRIPT" -eq 1 && -n "$UDID" && -n "$XCRUN_BIN" ]]; then
    "$XCRUN_BIN" simctl shutdown "$UDID" >/dev/null 2>&1 || true
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

resolve_simulator() {
  local devices_json=""
  devices_json="$("$XCRUN_BIN" simctl list devices available -j)" || die "failed to query available iOS simulators"

  python3 - "$EXPLICIT_UDID" "$devices_json" <<'PY'
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

if [[ "$INITIAL_STATE" != "Booted" ]]; then
  "$XCRUN_BIN" simctl boot "$UDID"
  BOOTED_BY_SCRIPT=1
  "$XCRUN_BIN" simctl bootstatus "$UDID" -b
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
    "$XCRUN_BIN" simctl spawn "$UDID" log show --last 2m --style compact \
    --predicate 'process == "Koe" OR subsystem BEGINSWITH "com.semanticcraft.koe"' || true

  if [[ -n "$trace_src" && -s "$trace_src" ]]; then
    cp "$trace_src" "$dir/trace.json"
  elif [[ -n "$container_dir" && -s "$container_dir/Documents/koe-trace.json" ]]; then
    cp "$container_dir/Documents/koe-trace.json" "$dir/trace.json"
  fi
}

validate_forensics_bundle() {
  local dir="$1"
  local missing=()
  local name
  for name in screen.png view_hierarchy.txt syslog.txt trace.json; do
    if [[ ! -s "$dir/$name" ]]; then
      missing+=("$name")
    fi
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    printf 'ios verify-simulator error: incomplete forensics bundle in %s; missing or empty: %s\n' \
      "$dir" "${missing[*]}" >&2
    return 1
  fi
  python3 -c 'import json, sys; data = json.load(open(sys.argv[1], encoding="utf-8")); assert isinstance(data, (dict, list))' "$dir/trace.json"
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
  rm -rf "$workspace_dir"
  mkdir -p "$workspace_dir"

  local trace_file="$docs_dir/koe-trace.json"
  rm -f "$trace_file"

  local launch_args=(
    -koe-workspace "$workspace_dir"
    -koe-trace-output "$trace_file"
  )
  if [[ -n "$fixture" ]]; then
    local staged_fixture="$docs_dir/koe-active-fixture.json"
    cp "$fixture" "$staged_fixture"
    launch_args+=(-koe-snapshot-fixture "$staged_fixture")
  fi

  "$XCRUN_BIN" simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
  "$XCRUN_BIN" simctl launch "$UDID" "$BUNDLE_ID" "${launch_args[@]}" >/dev/null

  local wait_ticks=0
  while [[ ! -s "$trace_file" && $wait_ticks -lt 30 ]]; do
    interruptible_sleep 0.2
    wait_ticks=$((wait_ticks + 1))
  done

  export MAESTRO_CLI_NO_ANALYTICS=1
  export MAESTRO_CLI_ANALYSIS_NOTIFICATION_DISABLED=true

  python3 -c 'import os, sys; os.setsid(); os.chdir(sys.argv[1]); os.execvp(sys.argv[2], sys.argv[2:])' \
    "$debug_dir" \
    "$MAESTRO_BIN" test --udid "$UDID" --no-ansi --debug-output "$debug_dir" "$flow" &
  MAESTRO_PID=$!

  local flow_exit=0
  local flow_deadline=$(( $(date +%s) + FLOW_TIMEOUT ))
  while pid_alive "$MAESTRO_PID"; do
    if [[ $(date +%s) -ge $flow_deadline ]]; then
      printf 'ios verify-simulator error: Maestro flow timed out after %ds: %s\n' "$FLOW_TIMEOUT" "$flow" >&2
      terminate_pgroup "$MAESTRO_PID" 3
      MAESTRO_PID=""
      flow_exit=124
      break
    fi
    interruptible_sleep 0.5
  done

  if [[ -n "$MAESTRO_PID" ]]; then
    wait "$MAESTRO_PID" || flow_exit=$?
    MAESTRO_PID=""
  fi

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

  local should_collect=0
  if [[ "$flow_exit" -ne 0 || "$EXPECT_FAILURE" -eq 1 || "$KEEP_ARTIFACTS" -eq 1 ]]; then
    should_collect=1
  fi

  if [[ "$should_collect" -eq 1 ]]; then
    collect_forensics "$out_dir" "$container_dir" "$trace_file" "$debug_dir"
  fi

  return "$flow_exit"
}

RUN_ID="$(date -u '+%Y%m%dT%H%M%SZ')-$$"
ARTIFACTS_DIR_CREATED=0
if [[ -z "$ARTIFACTS_DIR" ]]; then
  ARTIFACTS_DIR="$ROOT/target/verify-artifacts/ios-$RUN_ID"
else
  ARTIFACTS_DIR="$(python3 -c 'import os, sys; print(os.path.abspath(sys.argv[1]))' "$ARTIFACTS_DIR")"
fi
if [[ ! -d "$ARTIFACTS_DIR" ]]; then
  ARTIFACTS_DIR_CREATED=1
fi

ensure_app_built

if [[ "$SELF_CHECK" -eq 1 ]]; then
  run_unit_tests

  [[ -f "$LIVE_FLOW" ]] || die "missing live smoke flow: $LIVE_FLOW"
  [[ -f "$FIXTURE_FLOW" ]] || die "missing fixture smoke flow: $FIXTURE_FLOW"
  [[ -f "$DEFAULT_FIXTURE" ]] || die "missing rich fixture JSON: $DEFAULT_FIXTURE"

  live_dir="$ARTIFACTS_DIR/live"
  fixture_dir="$ARTIFACTS_DIR/fixture"

  if ! run_single_flow "$LIVE_FLOW" "" "$live_dir" "live"; then
    validate_forensics_bundle "$live_dir" || true
    printf 'verify-simulator: FAIL (live flow failed, device=%s, udid=%s, artifacts=%s)\n' \
      "$DEVICE_NAME" "$UDID" "$live_dir" >&2
    exit 1
  fi

  if ! run_single_flow "$FIXTURE_FLOW" "$DEFAULT_FIXTURE" "$fixture_dir" "fixture"; then
    validate_forensics_bundle "$fixture_dir" || true
    printf 'verify-simulator: FAIL (fixture flow failed, device=%s, udid=%s, artifacts=%s)\n' \
      "$DEVICE_NAME" "$UDID" "$fixture_dir" >&2
    exit 1
  fi

  if [[ "$KEEP_ARTIFACTS" -eq 1 ]]; then
    validate_forensics_bundle "$live_dir"
    validate_forensics_bundle "$fixture_dir"
    printf 'verify-simulator: PASS (self-check, device=%s, udid=%s, artifacts=%s)\n' \
      "$DEVICE_NAME" "$UDID" "$ARTIFACTS_DIR"
  else
    if [[ "$ARTIFACTS_DIR_CREATED" -eq 1 ]]; then
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
  validate_forensics_bundle "$ARTIFACTS_DIR"
  printf 'verify-simulator: expected failure confirmed with complete 4-artifact forensics (%s)\n' \
    "$ARTIFACTS_DIR"
  exit 0
fi

if [[ "$flow_exit" -eq 0 ]]; then
  if [[ "$KEEP_ARTIFACTS" -eq 1 ]]; then
    validate_forensics_bundle "$ARTIFACTS_DIR"
    printf 'verify-simulator: PASS (device=%s, udid=%s, artifacts=%s)\n' \
      "$DEVICE_NAME" "$UDID" "$ARTIFACTS_DIR"
  else
    if [[ "$ARTIFACTS_DIR_CREATED" -eq 1 ]]; then
      rm -rf "$ARTIFACTS_DIR" || true
    fi
    printf 'verify-simulator: PASS (device=%s, udid=%s)\n' "$DEVICE_NAME" "$UDID"
  fi
  exit 0
fi

validate_forensics_bundle "$ARTIFACTS_DIR" || true
printf 'verify-simulator: FAIL (exit=%d, device=%s, udid=%s, artifacts=%s)\n' \
  "$flow_exit" "$DEVICE_NAME" "$UDID" "$ARTIFACTS_DIR" >&2
exit "$flow_exit"
