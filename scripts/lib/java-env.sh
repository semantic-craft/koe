#!/usr/bin/env bash

valid_jdk17_home() {
  local require_jni=0
  if [[ "${1:-}" == "--require-jni" ]]; then
    require_jni=1
    shift
  fi
  local dir="${1:-}"
  [[ -n "$dir" && -x "$dir/bin/java" ]] || return 1
  if [[ "$require_jni" -eq 1 ]]; then
    [[ -x "$dir/bin/javac" && -f "$dir/include/jni.h" ]] || return 1
  fi
  local version_line major
  # macOS ships a /usr/bin/java stub that exits non-zero when no JDK is installed.
  version_line="$("$dir/bin/java" -version 2>&1 | head -n 1 || true)"
  major="$(sed -nE 's/.*version "([0-9]+).*/\1/p' <<< "$version_line")"
  [[ -n "$major" && "$major" -ge 17 ]]
}

resolve_java_home() {
  local require_jni=0
  if [[ "${1:-}" == "--require-jni" ]]; then
    require_jni=1
  fi

  _check_jdk_home() {
    if [[ "$require_jni" -eq 1 ]]; then
      valid_jdk17_home --require-jni "$1"
    else
      valid_jdk17_home "$1"
    fi
  }

  if [[ -n "${JAVA_HOME:-}" ]] && _check_jdk_home "$JAVA_HOME"; then
    printf '%s\n' "$JAVA_HOME"
    return 0
  fi

  local candidate=""
  if [[ -x /usr/libexec/java_home ]]; then
    candidate="$(/usr/libexec/java_home -v 17+ 2>/dev/null || true)"
    if _check_jdk_home "$candidate"; then
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
        if _check_jdk_home "$candidate"; then
          printf '%s\n' "$candidate"
          return 0
        fi
      fi
    done
  fi

  local jvm_dir
  for jvm_dir in /usr/lib/jvm/java-21-openjdk* /usr/lib/jvm/java-17-openjdk* /usr/lib/jvm/default-java; do
    if _check_jdk_home "$jvm_dir"; then
      printf '%s\n' "$jvm_dir"
      return 0
    fi
  done

  if candidate="$(command -v javac 2>/dev/null)"; then
    candidate="$(python3 -c 'import os, sys; print(os.path.dirname(os.path.dirname(os.path.realpath(sys.argv[1]))))' "$candidate")"
    if _check_jdk_home "$candidate"; then
      printf '%s\n' "$candidate"
      return 0
    fi
  fi

  return 1
}
