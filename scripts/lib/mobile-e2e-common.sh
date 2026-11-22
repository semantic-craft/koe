#!/usr/bin/env bash

MOBILE_E2E_LOG_PREFIX="${MOBILE_E2E_LOG_PREFIX:-error}"
MAESTRO_PID=""
SLEEP_PID=""
MAESTRO_STARTED_AT=""
MAESTRO_FINISHED_AT=""
MAESTRO_DURATION_SEC="0.000"

die() {
  printf '%s: %s\n' "${MOBILE_E2E_LOG_PREFIX:-error}" "$*" >&2
  exit 1
}

die_usage() {
  printf '%s: %s\n' "${MOBILE_E2E_LOG_PREFIX:-error}" "$*" >&2
  usage >&2
  exit 2
}

abs_path() {
  python3 -c 'import os, sys; print(os.path.abspath(sys.argv[1]))' "$1"
}

resolve_tool() {
  local override="$1"
  local name="$2"
  local extra_candidate="${3:-}"
  local not_found_hint="${4:-}"

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

  if [[ -n "$not_found_hint" ]]; then
    die "$name not found; $not_found_hint"
  fi
  die "$name not found; install $name or set KOE_$(printf '%s' "$name" | tr '[:lower:]' '[:upper:]')_BIN"
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

run_maestro_with_timeout() {
  local maestro_bin="$1"
  local udid="$2"
  local debug_dir="$3"
  local flow_path="$4"
  local flow_timeout="$5"

  local start_epoch=""
  read -r MAESTRO_STARTED_AT start_epoch < <(
    python3 -c 'import datetime, time; print(datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"), f"{time.time():.6f}")'
  )

  export MAESTRO_CLI_NO_ANALYTICS=1
  export MAESTRO_CLI_ANALYSIS_NOTIFICATION_DISABLED=true

  # Maestro takeScreenshot writes relative to CWD instead of --debug-output.
  python3 -c 'import os, sys; os.setsid(); os.chdir(sys.argv[1]); os.execvp(sys.argv[2], sys.argv[2:])' \
    "$debug_dir" \
    "$maestro_bin" test --udid "$udid" --no-ansi --debug-output "$debug_dir" "$flow_path" &
  MAESTRO_PID=$!

  local exit_code=0
  local flow_deadline=$(( $(date +%s) + flow_timeout ))
  while pid_alive "$MAESTRO_PID"; do
    if [[ $(date +%s) -ge $flow_deadline ]]; then
      printf '%s: Maestro flow timed out after %ds: %s\n' "${MOBILE_E2E_LOG_PREFIX:-error}" "$flow_timeout" "$flow_path" >&2
      terminate_pgroup "$MAESTRO_PID" 3
      MAESTRO_PID=""
      exit_code=124
      break
    fi
    interruptible_sleep 0.5
  done

  if [[ -n "$MAESTRO_PID" ]]; then
    wait "$MAESTRO_PID" || exit_code=$?
    MAESTRO_PID=""
  fi

  read -r MAESTRO_FINISHED_AT MAESTRO_DURATION_SEC < <(
    python3 -c 'import datetime, sys, time; now = time.time(); print(datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"), f"{max(0.0, now - float(sys.argv[1])):.3f}")' "$start_epoch"
  )
  return "$exit_code"
}

compute_flow_outcome() {
  local exit_code="$1"
  local expect_failure="$2"
  if [[ "$expect_failure" -eq 1 ]]; then
    if [[ "$exit_code" -ne 0 ]]; then
      printf 'expected_failure\n'
    else
      printf 'unexpected_pass\n'
    fi
  else
    if [[ "$exit_code" -eq 0 ]]; then
      printf 'pass\n'
    else
      printf 'fail\n'
    fi
  fi
}

write_forensics_trace() {
  python3 - "$MAESTRO_STARTED_AT" "$MAESTRO_FINISHED_AT" "$MAESTRO_DURATION_SEC" "$@" <<'PY'
import json
from pathlib import Path
import sys

(
    started_at, finished_at, duration_sec,
    trace_path, platform, run_id, flow, flow_exit_code, outcome,
    screen_path, hierarchy_path, log_path, maestro_debug_dir, host_trace_raw_path,
) = sys.argv[1:15]

extra_fields = dict(item.split("=", 1) for item in sys.argv[15:] if "=" in item)

host_intent_trace = None
if host_trace_raw_path:
    raw_file = Path(host_trace_raw_path)
    if raw_file.is_file() and raw_file.stat().st_size > 0:
        try:
            parsed = json.loads(raw_file.read_text(encoding="utf-8"))
            if isinstance(parsed, list):
                host_intent_trace = parsed
        except (OSError, json.JSONDecodeError, UnicodeDecodeError):
            host_intent_trace = None

payload = {
    "platform": platform,
    "run_id": run_id,
    **extra_fields,
    "flow": flow,
    "started_at": started_at,
    "finished_at": finished_at,
    "duration_sec": float(duration_sec),
    "flow_exit_code": int(flow_exit_code),
    "outcome": outcome,
    "artifacts": {
        "screen": screen_path,
        "hierarchy": hierarchy_path,
        "log": log_path,
        "maestro_debug_dir": maestro_debug_dir,
    },
    "host_intent_trace": host_intent_trace,
}
Path(trace_path).write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
PY
}

validate_forensics_bundle() {
  local dir="$1"
  local hierarchy_file="$2"
  local log_file="$3"
  local missing=()
  local name
  for name in screen.png "$hierarchy_file" "$log_file" trace.json; do
    if [[ ! -s "$dir/$name" ]]; then
      missing+=("$name")
    fi
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    printf '%s: incomplete forensics bundle in %s; missing or empty: %s\n' \
      "${MOBILE_E2E_LOG_PREFIX:-error}" "$dir" "${missing[*]}" >&2
    return 1
  fi
  python3 - "$dir/trace.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as fh:
    data = json.load(fh)
assert isinstance(data, dict), "trace.json must be a JSON object"
for key in ("platform", "run_id", "flow", "outcome", "flow_exit_code", "artifacts", "host_intent_trace"):
    assert key in data, f"trace.json missing key: {key}"
assert isinstance(data["artifacts"], dict), "trace.json artifacts must be an object"
assert data["host_intent_trace"] is None or isinstance(data["host_intent_trace"], list), (
    "trace.json host_intent_trace must be a list or null"
)
PY
}
