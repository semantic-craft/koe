#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: platforms/android/tests/jni/test-jni-host.sh [--check-jdk]

Builds host libkoe_host_api (--no-default-features), compiles the C++17 JNI
bridge and test hooks with -Wall -Wextra -Werror, and runs KoeJniHostTest on a
desktop JDK 17+ JVM.
USAGE
}

die() {
  printf 'test-jni-host error: %s\n' "$*" >&2
  exit 1
}

CHECK_JDK_ONLY=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --check-jdk) CHECK_JDK_ONLY=1 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
  shift
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || (cd "$SCRIPT_DIR/../../../.." && pwd))"
# shellcheck source=scripts/lib/java-env.sh
source "$REPO_ROOT/scripts/lib/java-env.sh"

if ! JDK_HOME="$(resolve_java_home --require-jni)"; then
  die "working JDK 17+ with JNI headers not found; install with 'brew install openjdk@17' or set JAVA_HOME"
fi

if [[ "$CHECK_JDK_ONLY" -eq 1 ]]; then
  printf '%s\n' "$JDK_HOME"
  exit 0
fi

OS_NAME="$(uname -s)"
case "$OS_NAME" in
  Darwin)
    JNI_OS_INCLUDE="darwin"
    LIB_EXT="dylib"
    CXX_BIN="${CXX:-clang++}"
    ;;
  Linux)
    JNI_OS_INCLUDE="linux"
    LIB_EXT="so"
    CXX_BIN="${CXX:-c++}"
    ;;
  *)
    die "unsupported host OS for desktop JNI test: $OS_NAME"
    ;;
esac

export CARGO_TARGET_DIR="$REPO_ROOT/target/jni-host-cargo"
cargo_args=(
  build
  --manifest-path "$REPO_ROOT/Cargo.toml"
  -p koe-host-api
  --no-default-features
  --locked
)
if [[ "${KOE_CARGO_OFFLINE:-0}" == "1" ]]; then
  cargo_args+=(--offline)
fi
cargo "${cargo_args[@]}"

HOST_LIB_SRC="$CARGO_TARGET_DIR/debug/libkoe_host_api.$LIB_EXT"
[[ -f "$HOST_LIB_SRC" ]] || die "expected host shared library missing: $HOST_LIB_SRC"

BUILD_DIR="$REPO_ROOT/target/jni-host"
CLASSES_DIR="$BUILD_DIR/classes"
rm -rf "$BUILD_DIR"
mkdir -p "$CLASSES_DIR"

cp "$HOST_LIB_SRC" "$BUILD_DIR/libkoe_host_api.$LIB_EXT"

cxx_platform_flags=()
if [[ "$OS_NAME" == "Darwin" ]]; then
  install_name_tool -id "@rpath/libkoe_host_api.dylib" "$BUILD_DIR/libkoe_host_api.dylib"
  cxx_platform_flags+=("-Wl,-rpath,@loader_path")
else
  cxx_platform_flags+=('-Wl,-rpath,$ORIGIN' -pthread)
fi

"$CXX_BIN" \
  -std=c++17 -O2 -g -shared -fPIC \
  -Wall -Wextra -Werror \
  -I"$JDK_HOME/include" \
  -I"$JDK_HOME/include/$JNI_OS_INCLUDE" \
  -I"$REPO_ROOT/platforms/apple-shared/Sources/CKoeHostApi/include" \
  -I"$REPO_ROOT/platforms/android/native" \
  "$REPO_ROOT/platforms/android/native/client_jni.cpp" \
  "$REPO_ROOT/platforms/android/native/JniCallbacks.cpp" \
  "$SCRIPT_DIR/JniTestHooks.cpp" \
  -L"$BUILD_DIR" -lkoe_host_api \
  "${cxx_platform_flags[@]}" \
  -o "$BUILD_DIR/libkoe_android_test.$LIB_EXT"

"$JDK_HOME/bin/javac" \
  -Xlint:all -Werror \
  -d "$CLASSES_DIR" \
  "$REPO_ROOT/platforms/android/gradle-app/app/src/main/java/com/semanticcraft/koe/bridge/KoeNativeBridge.java" \
  "$SCRIPT_DIR/KoeJniHostTest.java"

"$JDK_HOME/bin/java" \
  -ea \
  -cp "$CLASSES_DIR" \
  -Djava.library.path="$BUILD_DIR" \
  com.semanticcraft.koe.bridge.KoeJniHostTest
