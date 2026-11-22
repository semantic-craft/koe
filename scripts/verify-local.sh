#!/usr/bin/env bash
# Local verification gate for Koe (aligned with metasequoiaime/msime).
#
# Usage:
#   scripts/verify-local.sh --quick   compile, lint, and fast contract checks
#   scripts/verify-local.sh           full verification including workspace tests

set -euo pipefail
export MACOSX_DEPLOYMENT_TARGET=14.0

unset DASHSCOPE_API_KEY DEEPSEEK_API_KEY ARK_API_KEY DOUBAO_API_KEY DOUBAO_TTS_API_KEY
root="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"
cd "$root"

quick=0
for arg in "$@"; do
  case "$arg" in
    --quick) quick=1 ;;
    --with-tests) quick=0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

cargo_offline_args=()
if [[ "${KOE_CARGO_OFFLINE:-0}" == "1" ]]; then
  cargo_offline_args=(--offline)
fi

note() { printf '\n=== %s ===\n' "$1"; }

note "contracts & tooling tests"
python3 scripts/test_cleanup_app_registrations.py
python3 scripts/test_install_macos.py
python3 scripts/test_release_macos.py
python3 scripts/test_ci.py
python3 scripts/test_android_harness.py
python3 scripts/test_android_app_harness.py
python3 scripts/test_android_native_scripts.py
python3 scripts/test_ios_harness.py
python3 scripts/test_mobile_e2e_verifier.py
python3 scripts/test_run_with_secrets.py
python3 scripts/test_verify_ui_principles.py
python3 scripts/verify-ui-principles.py --mode all
if [[ -n "${KOE_SWIFTUI_PERF_CHECK:-}" && -f "${KOE_SWIFTUI_PERF_CHECK}" ]]; then
  python3 "$KOE_SWIFTUI_PERF_CHECK" "$root"
fi
if [[ -n "${KOE_NOTARY_CHECK:-}" && -f "${KOE_NOTARY_CHECK}" ]]; then
  python3 "$KOE_NOTARY_CHECK" "$root"
fi
if [[ "${KOE_SKIP_PROGRESS_CHECK:-0}" != "1" ]]; then
  python3 progress/progress.py check
fi

note "compile & clippy: rust workspace"
cargo check --workspace --all-targets ${cargo_offline_args[@]+"${cargo_offline_args[@]}"} --quiet
cargo clippy --workspace --all-targets ${cargo_offline_args[@]+"${cargo_offline_args[@]}"} -- -D warnings
cargo clippy --package koe-host-api --no-default-features --all-targets ${cargo_offline_args[@]+"${cargo_offline_args[@]}"} -- -D warnings

if [[ "$quick" -eq 1 ]]; then
  echo "verify-local (--quick): all compile and contract gates passed."
  exit 0
fi

note "test: rust workspace"
cargo test --workspace ${cargo_offline_args[@]+"${cargo_offline_args[@]}"} --quiet

if [[ -d "$root/platforms/macos" && -f "$root/platforms/macos/Package.swift" && "$(uname -s)" == "Darwin" ]]; then
  note "native host: platforms/apple-shared & platforms/macos"
  swift scripts/generate-app-icons.swift --check
  swift scripts/verify-app-icon.swift build/macos/AppIcon.iconset
  cargo build --package koe-host-api ${cargo_offline_args[@]+"${cargo_offline_args[@]}"} --quiet
  cargo build --release --package koe-host-api ${cargo_offline_args[@]+"${cargo_offline_args[@]}"} --quiet
  swift test --package-path "$root/platforms/apple-shared"
  swift test --package-path "$root/platforms/macos"
fi

if [[ -x "$root/platforms/android/tests/jni/test-jni-host.sh" ]]; then
  note "native jni host: platforms/android/tests/jni"
  if "$root/platforms/android/tests/jni/test-jni-host.sh" --check-jdk >/dev/null 2>&1; then
    "$root/platforms/android/tests/jni/test-jni-host.sh"
  elif [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then
    echo "error: JDK 17+ not detected in GitHub Actions; desktop JVM JNI tests are required in CI." >&2
    exit 1
  else
    echo "skip: JDK 17+ not detected; install openjdk@17 or set JAVA_HOME to run desktop JVM JNI tests."
  fi
fi

echo "verify-local (full): all gates passed."
