#!/usr/bin/env bash
set -euo pipefail

root="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"
cd "$root"

failures=0
pass() { printf 'PASS  %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1" >&2; failures=$((failures + 1)); }

if [[ -x "$root/target/debug/koe" ]]; then
  version_json="$("$root/target/debug/koe" --version 2>&1 || true)"
  if [[ "$version_json" == *'"name":"koe"'* ]]; then
    pass "koe CLI binary ready ($version_json)"
  else
    fail "koe CLI binary failed --version ($version_json)"
  fi
else
  fail "koe CLI binary missing at $root/target/debug/koe (run: cargo build -p koe-cli)"
fi

if [[ "$(uname -s)" == "Darwin" ]]; then
  macos_bin="$root/platforms/macos/.build/debug/Koe"
  if [[ -x "$macos_bin" ]]; then
    pass "macOS host binary ready ($macos_bin)"
  else
    fail "macOS host binary missing at $macos_bin (run: cargo build -p koe-host-api && swift build --package-path platforms/macos)"
  fi
else
  pass "non-Darwin host ($(uname -s)); macOS host binary check skipped"
fi

if [[ -z "${TMP_WS:-}" ]]; then
  fail "TMP_WS is unset (set TMP_WS=/tmp/koe-verify-\$\$)"
else
  ws_bytes="$(printf '%s' "$TMP_WS" | LC_ALL=C wc -c | tr -d ' ')"
  if (( ws_bytes >= 94 )); then
    fail "TMP_WS byte length is $ws_bytes bytes (must be < 94 bytes so koe.sock stays < 103 bytes)"
  elif ! ws_check="$(python3 - "$TMP_WS" "${TMPDIR:-/tmp}" <<'PY'
import os, sys

raw, tmpdir = sys.argv[1], sys.argv[2]
if not os.path.isabs(raw):
    print(f"TMP_WS must be an absolute path inside /tmp or TMPDIR ({raw})")
    sys.exit(1)

resolved = os.path.realpath(raw)
if "Library/Containers/com.anker.ankerRecorder" in raw or "Library/Containers/com.anker.ankerRecorder" in resolved:
    print(f"TMP_WS points inside production App Sandbox container ({resolved})")
    sys.exit(1)

allowed_roots = []
for candidate in ("/tmp", "/private/tmp", tmpdir):
    if candidate:
        rp = os.path.realpath(candidate)
        if rp not in allowed_roots:
            allowed_roots.append(rp)

for base in allowed_roots:
    if resolved == base:
        continue
    try:
        rel = os.path.relpath(resolved, base)
    except ValueError:
        continue
    if rel != "." and not rel.startswith(".." + os.sep) and rel != "..":
        print(f"TMP_WS safe ({raw} -> {resolved}, bytes={len(raw.encode('utf-8'))} < 94)")
        sys.exit(0)

print(f"TMP_WS must resolve to a subdirectory strictly inside /tmp or TMPDIR (got {raw} -> {resolved})")
sys.exit(1)
PY
  )"; then
    fail "$ws_check"
  else
    pass "$ws_check"
  fi
fi

leaked_keys=()
for var in DASHSCOPE_API_KEY DEEPSEEK_API_KEY ARK_API_KEY DOUBAO_API_KEY DOUBAO_TTS_API_KEY; do
  if [[ -n "${!var:-}" ]]; then
    leaked_keys+=("$var")
  fi
done
if (( ${#leaked_keys[@]} > 0 )); then
  fail "ambient cloud API keys must be unset: ${leaked_keys[*]}"
else
  pass "ambient cloud API keys unset"
fi

if [[ -f "$root/crates/koe-runtime/tests/formal_models.rs" ]]; then
  pass "formal_models integration test target present"
else
  fail "missing $root/crates/koe-runtime/tests/formal_models.rs"
fi

if (( failures > 0 )); then
  printf 'doctor: %d check(s) failed\n' "$failures" >&2
  exit 1
fi

printf 'doctor: all checks passed\n'
