#!/usr/bin/env bash
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
python3 scripts/test_host_contracts.py
python3 scripts/test_android_harness.py
python3 scripts/test_android_app_harness.py
python3 scripts/test_android_native_scripts.py
python3 scripts/test_ios_harness.py
python3 scripts/test_mobile_e2e_verifier.py
python3 scripts/test_run_with_secrets.py
python3 scripts/test_verify_ui_principles.py
python3 scripts/verify-ui-principles.py --mode all
perf_check="${KOE_SWIFTUI_PERF_CHECK:-$HOME/Projects/agent-home/tools/swiftui-perf-check/scripts/check_swiftui_perf.py}"
if [[ -f "$perf_check" ]]; then
  python3 "$perf_check" "$root"
fi
notary_check="${KOE_NOTARY_CHECK:-$HOME/Projects/agent-home/tools/notary-check/check_notary_policy.py}"
if [[ -f "$notary_check" ]]; then
  python3 "$notary_check" "$root"
fi
python3 progress/progress.py check

note "compile & clippy: rust workspace"
cargo check --workspace --all-targets ${cargo_offline_args[@]+"${cargo_offline_args[@]}"} --quiet
cargo clippy --workspace --all-targets ${cargo_offline_args[@]+"${cargo_offline_args[@]}"} -- -D warnings
cargo clippy -p koe-host-api -p koe-runtime -p koe-client-providers --no-default-features --all-targets ${cargo_offline_args[@]+"${cargo_offline_args[@]}"} -- -D warnings

if [[ "$quick" -eq 1 ]]; then
  echo "verify-local (--quick): all compile and contract gates passed."
  exit 0
fi

note "test: rust workspace"
cargo test --workspace ${cargo_offline_args[@]+"${cargo_offline_args[@]}"} --quiet
cargo test -p koe-host-api -p koe-runtime -p koe-client-providers --no-default-features ${cargo_offline_args[@]+"${cargo_offline_args[@]}"} --quiet

note "formal state-machine models: koe-runtime"
cargo test -p koe-runtime --test formal_models ${cargo_offline_args[@]+"${cargo_offline_args[@]}"}

if [[ -d "$root/platforms/macos" && -f "$root/platforms/macos/Package.swift" && "$(uname -s)" == "Darwin" ]]; then
  note "native host: platforms/apple-shared & platforms/macos"
  swift scripts/generate-app-icons.swift
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
  else
    echo "skip: JDK 17+ not detected; install openjdk@17 or set JAVA_HOME to run desktop JVM JNI tests."
  fi
fi

echo "verify-local (full): all gates passed."
