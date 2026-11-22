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

valid_jdk17_home() {
  local dir="$1"
  [[ -n "$dir" && -x "$dir/bin/java" && -x "$dir/bin/javac" && -f "$dir/include/jni.h" ]] || return 1
  local version_line major
  version_line="$("$dir/bin/java" -version 2>&1 | head -n 1 || true)"
  major="$(sed -nE 's/.*version "([0-9]+).*/\1/p' <<< "$version_line")"
  [[ -n "$major" && "$major" -ge 17 ]]
}

resolve_java_home() {
  if [[ -n "${JAVA_HOME:-}" ]] && valid_jdk17_home "$JAVA_HOME"; then
    printf '%s\n' "$JAVA_HOME"
    return 0
  fi

  local candidate=""
  if [[ -x /usr/libexec/java_home ]]; then
    candidate="$(/usr/libexec/java_home -v 17+ 2>/dev/null || true)"
    if valid_jdk17_home "$candidate"; then
      printf '%s\n' "$candidate"
      return 0
    fi
  fi

  if command -v brew >/dev/null 2>&1; then
    local formula brew_prefix
    for formula in openjdk@17 openjdk@21 openjdk; do
      brew_prefix="$(brew --prefix "$formula" 2>/dev/null || true)"
      if [[ -n "$brew_prefix" ]]; then
        candidate="$brew_prefix/libexec/openjdk.jdk/Contents/Home"
        if valid_jdk17_home "$candidate"; then
          printf '%s\n' "$candidate"
          return 0
        fi
      fi
    done
  fi

  local jvm_dir
  for jvm_dir in /usr/lib/jvm/java-21-openjdk* /usr/lib/jvm/java-17-openjdk* /usr/lib/jvm/default-java; do
    if valid_jdk17_home "$jvm_dir"; then
      printf '%s\n' "$jvm_dir"
      return 0
    fi
  done

  if candidate="$(command -v javac 2>/dev/null)"; then
    candidate="$(python3 -c 'import os, sys; print(os.path.dirname(os.path.dirname(os.path.realpath(sys.argv[1]))))' "$candidate")"
    if valid_jdk17_home "$candidate"; then
      printf '%s\n' "$candidate"
      return 0
    fi
  fi

  return 1
}

if ! JDK_HOME="$(resolve_java_home)"; then
  die "working JDK 17+ with JNI headers not found; install with 'brew install openjdk@17' or set JAVA_HOME"
fi

if [[ "$CHECK_JDK_ONLY" -eq 1 ]]; then
  printf '%s\n' "$JDK_HOME"
  exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || (cd "$SCRIPT_DIR/../../../.." && pwd))"

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
