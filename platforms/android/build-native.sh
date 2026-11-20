#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: platforms/android/build-native.sh [arm64-v8a|x86_64]

Cross-compiles libkoe_host_api.so (Rust, --no-default-features) and
libkoe_android.so (C++17 JNI bridge) with NDK 28.2.13676358 (API 29),
copies libc++_shared.so into target/android/jniLibs/<abi>/, and runs
platforms/android/verify-native.sh.
USAGE
}

die() {
  printf 'build-native error: %s\n' "$*" >&2
  exit 1
}

if [[ $# -gt 1 ]]; then
  usage >&2
  exit 2
fi

case "${1:-arm64-v8a}" in
  -h|--help) usage; exit 0 ;;
  arm64-v8a)
    ABI="arm64-v8a"
    RUST_TARGET="aarch64-linux-android"
    COMPILER_TARGET="aarch64-linux-android"
    CARGO_ENV_TARGET="AARCH64_LINUX_ANDROID"
    ;;
  x86_64)
    ABI="x86_64"
    RUST_TARGET="x86_64-linux-android"
    COMPILER_TARGET="x86_64-linux-android"
    CARGO_ENV_TARGET="X86_64_LINUX_ANDROID"
    ;;
  *)
    die "unsupported ABI '$1' (expected arm64-v8a or x86_64)"
    ;;
esac

NDK_VERSION="28.2.13676358"
ANDROID_API="29"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || (cd "$SCRIPT_DIR/../.." && pwd))"

resolve_ndk() {
  if [[ -n "${KOE_ANDROID_NDK:-}" ]]; then
    [[ -d "$KOE_ANDROID_NDK" ]] || die "KOE_ANDROID_NDK does not exist: $KOE_ANDROID_NDK"
    printf '%s\n' "$KOE_ANDROID_NDK"
    return 0
  fi

  local candidate
  for candidate in \
    "${ANDROID_SDK_ROOT:-}/ndk/$NDK_VERSION" \
    "${ANDROID_HOME:-}/ndk/$NDK_VERSION" \
    "$HOME/Library/Android/sdk/ndk/$NDK_VERSION" \
    "$HOME/Android/Sdk/ndk/$NDK_VERSION"
  do
    if [[ -n "$candidate" && -d "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  die "Android NDK $NDK_VERSION not found; run platforms/android/install-sdk-packages.sh or set KOE_ANDROID_NDK"
}

resolve_toolchain() {
  local ndk="$1"
  local host_tag
  for host_tag in darwin-arm64 darwin-x86_64 linux-x86_64; do
    local dir="$ndk/toolchains/llvm/prebuilt/$host_tag"
    if [[ -x "$dir/bin/llvm-readelf" ]]; then
      printf '%s\n' "$dir"
      return 0
    fi
  done
  die "LLVM prebuilt toolchain not found under $ndk/toolchains/llvm/prebuilt"
}

NDK="$(resolve_ndk)"
TOOLCHAIN="$(resolve_toolchain "$NDK")"

CC_BIN="$TOOLCHAIN/bin/${COMPILER_TARGET}${ANDROID_API}-clang"
CXX_BIN="$TOOLCHAIN/bin/${COMPILER_TARGET}${ANDROID_API}-clang++"
AR_BIN="$TOOLCHAIN/bin/llvm-ar"
READELF_BIN="$TOOLCHAIN/bin/llvm-readelf"
LIBCXX_SHARED="$TOOLCHAIN/sysroot/usr/lib/${COMPILER_TARGET}/libc++_shared.so"

[[ -x "$CC_BIN" ]] || die "NDK clang not found: $CC_BIN"
[[ -x "$CXX_BIN" ]] || die "NDK clang++ not found: $CXX_BIN"
[[ -x "$AR_BIN" ]] || die "NDK llvm-ar not found: $AR_BIN"
[[ -f "$LIBCXX_SHARED" ]] || die "libc++_shared.so not found: $LIBCXX_SHARED"

OUTPUT_DIR="$REPO_ROOT/target/android/jniLibs/$ABI"
rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"

export CARGO_TARGET_DIR="$REPO_ROOT/target/android-cargo"
export ANDROID_NDK="$NDK"
export CMAKE_GENERATOR="Unix Makefiles"
# Do not inherit CMAKE_TOOLCHAIN_FILE without -DANDROID_ABI, which causes audiopus_sys to build 32-bit EM_ARM.
unset CMAKE_TOOLCHAIN_FILE

TARGET_UNDERSCORE="${RUST_TARGET//-/_}"
export "CC_${TARGET_UNDERSCORE}=$CC_BIN"
export "CXX_${TARGET_UNDERSCORE}=$CXX_BIN"
export "AR_${TARGET_UNDERSCORE}=$AR_BIN"
export "CARGO_TARGET_${CARGO_ENV_TARGET}_LINKER=$CC_BIN"

export RUSTFLAGS="-C link-arg=-Wl,-z,max-page-size=16384 -C link-arg=-Wl,--build-id=sha1 -C link-arg=-Wl,--pack-dyn-relocs=relr -C link-arg=-Wl,--use-android-relr-tags -C link-arg=-Wl,-soname,libkoe_host_api.so"

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

HOST_SO="$CARGO_TARGET_DIR/$RUST_TARGET/release/libkoe_host_api.so"
[[ -f "$HOST_SO" ]] || die "expected Rust output missing: $HOST_SO"

cp "$HOST_SO" "$OUTPUT_DIR/libkoe_host_api.so"
cp "$LIBCXX_SHARED" "$OUTPUT_DIR/libc++_shared.so"

"$CXX_BIN" \
  -std=c++17 -O2 -g -shared -fPIC \
  -Wall -Wextra -Werror \
  -Wl,--no-undefined \
  -Wl,-z,max-page-size=16384 \
  -Wl,--build-id=sha1 \
  -Wl,-soname,libkoe_android.so \
  -I"$REPO_ROOT/platforms/apple-shared/Sources/CKoeHostApi/include" \
  -I"$REPO_ROOT/platforms/android/native" \
  "$REPO_ROOT/platforms/android/native/client_jni.cpp" \
  "$REPO_ROOT/platforms/android/native/JniCallbacks.cpp" \
  -L"$OUTPUT_DIR" -lkoe_host_api -ldl -llog \
  -o "$OUTPUT_DIR/libkoe_android.so"

"$SCRIPT_DIR/verify-native.sh" "$READELF_BIN" "$OUTPUT_DIR" "$ABI"
