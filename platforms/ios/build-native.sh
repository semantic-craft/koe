#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: platforms/ios/build-native.sh [device|simulator]

Cross-compiles libkoe_host_api.a (--no-default-features) for iOS arm64
(device: aarch64-apple-ios, simulator: aarch64-apple-ios-sim) and verifies
arm64 architecture and all 16 exported C ABI v2 symbols.
USAGE
}

die() {
  printf 'ios build-native error: %s\n' "$*" >&2
  exit 1
}

if [[ $# -gt 1 ]]; then
  usage >&2
  exit 2
fi

case "${1:-simulator}" in
  -h|--help) usage; exit 0 ;;
  device)
    VARIANT="device"
    RUST_TARGET="aarch64-apple-ios"
    SDK="iphoneos"
    ;;
  simulator)
    VARIANT="simulator"
    RUST_TARGET="aarch64-apple-ios-sim"
    SDK="iphonesimulator"
    ;;
  *)
    die "unsupported variant '$1' (expected device or simulator)"
    ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || (cd "$SCRIPT_DIR/../.." && pwd))"

export IPHONEOS_DEPLOYMENT_TARGET="${IPHONEOS_DEPLOYMENT_TARGET:-17.0}"
SDK_PATH="$(xcrun --sdk "$SDK" --show-sdk-path)"
CC_BIN="$(xcrun --sdk "$SDK" --find clang)"
CXX_BIN="$(xcrun --sdk "$SDK" --find clang++)"
AR_BIN="$(xcrun --sdk "$SDK" --find ar)"

export SDKROOT="$SDK_PATH"
TARGET_UNDERSCORE="${RUST_TARGET//-/_}"
export "CC_${TARGET_UNDERSCORE}=$CC_BIN"
export "CXX_${TARGET_UNDERSCORE}=$CXX_BIN"
export "AR_${TARGET_UNDERSCORE}=$AR_BIN"
export CARGO_TARGET_DIR="$REPO_ROOT/target/ios-cargo/$VARIANT"

cargo_args=(
  build
  --manifest-path "$REPO_ROOT/Cargo.toml"
  -p koe-host-api
  --no-default-features
  --target "$RUST_TARGET"
  --release
  --locked
)
if [[ "${KOE_CARGO_OFFLINE:-0}" == "1" ]]; then
  cargo_args+=(--offline)
fi

cargo "${cargo_args[@]}"

BUILT_LIB="$CARGO_TARGET_DIR/$RUST_TARGET/release/libkoe_host_api.a"
[[ -f "$BUILT_LIB" ]] || die "expected Rust staticlib missing: $BUILT_LIB"

OUTPUT_DIR="$REPO_ROOT/target/ios/$VARIANT"
mkdir -p "$OUTPUT_DIR"
OUTPUT_LIB="$OUTPUT_DIR/libkoe_host_api.a"
cp "$BUILT_LIB" "$OUTPUT_LIB"

LIPO_INFO="$(lipo -info "$OUTPUT_LIB")"
grep -Eq '\barm64\b' <<< "$LIPO_INFO" || die "expected arm64 slice in $OUTPUT_LIB, got: $LIPO_INFO"

REQUIRED_SYMBOLS=(
  "_koe_host_api_version"
  "_koe_host_session_create"
  "_koe_host_session_create_with_credentials"
  "_koe_host_session_destroy"
  "_koe_host_session_generation"
  "_koe_host_session_snapshot_json"
  "_koe_host_session_export_diagnostics_json"
  "_koe_host_session_dispatch_json"
  "_koe_host_session_ingest_ble"
  "_koe_host_session_ingest_pcm"
  "_koe_host_session_report_playback_progress"
  "_koe_host_session_drain_ble_tx"
  "_koe_host_session_drain_local_asr"
  "_koe_host_session_poll_timers"
  "_koe_host_bytes_free"
  "_koe_host_string_free"
)

# Skip embedded LLVM bitcode so newer rustc LLVM attributes do not trip Xcode's older Apple LLVM nm.
EXPORTED_SYMBOLS="$(nm -gU --no-llvm-bc "$OUTPUT_LIB" | awk 'NF == 3 { print $3 }')"
for sym in "${REQUIRED_SYMBOLS[@]}"; do
  if ! grep -Fxq "$sym" <<< "$EXPORTED_SYMBOLS"; then
    die "$OUTPUT_LIB: missing exported symbol '$sym'"
  fi
done

printf 'ios build-native passed: variant=%s target=%s lib=%s (%d symbols, arm64)\n' \
  "$VARIANT" "$RUST_TARGET" "$OUTPUT_LIB" "${#REQUIRED_SYMBOLS[@]}"
