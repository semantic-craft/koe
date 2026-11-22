#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: platforms/android/install-sdk-packages.sh [--check-only] [-h|--help]

Bootstraps pinned Android SDK/NDK packages and the dedicated koe-test-api<N> AVD.

Environment overrides:
  KOE_ANDROID_API     Target emulator API level (default: 35)
  KOE_ANDROID_ABI     System image ABI (default: arm64-v8a on arm64, else x86_64)
  ANDROID_SDK_ROOT    Android SDK directory (default: $ANDROID_HOME or $HOME/Library/Android/sdk)
  ANDROID_AVD_HOME    Android AVD directory (default: $HOME/.android/avd)
  JAVA_HOME           JDK 17+ home
USAGE
}

CHECK_ONLY=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --check-only) CHECK_ONLY=1 ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'error: unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

# shellcheck source=scripts/lib/java-env.sh
source "$ROOT/scripts/lib/java-env.sh"

resolve_cmdline_tool() {
  local override="$1"
  local tool="$2"

  if [[ -n "$override" ]]; then
    [[ -x "$override" ]] || die "$tool override is not executable: $override"
    printf '%s\n' "$override"
    return 0
  fi

  local candidate="$ANDROID_SDK_ROOT/cmdline-tools/latest/bin/$tool"
  if [[ -x "$candidate" ]]; then
    printf '%s\n' "$candidate"
    return 0
  fi

  if command -v brew >/dev/null 2>&1; then
    local brew_prefix=""
    brew_prefix="$(brew --prefix 2>/dev/null || true)"
    candidate="$brew_prefix/share/android-commandlinetools/cmdline-tools/latest/bin/$tool"
    if [[ -x "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  fi

  if candidate="$(command -v "$tool" 2>/dev/null)"; then
    printf '%s\n' "$candidate"
    return 0
  fi

  die "$tool not found; install with 'brew install --cask android-commandlinetools' or set ANDROID_SDK_ROOT"
}

default_abi() {
  case "$(uname -m)" in
    arm64|aarch64) printf 'arm64-v8a\n' ;;
    *) printf 'x86_64\n' ;;
  esac
}

KOE_ANDROID_API="${KOE_ANDROID_API:-35}"
[[ "$KOE_ANDROID_API" =~ ^[0-9]+$ ]] || die "KOE_ANDROID_API must be numeric: $KOE_ANDROID_API"
KOE_ANDROID_ABI="${KOE_ANDROID_ABI:-$(default_abi)}"
[[ -n "$KOE_ANDROID_ABI" ]] || die "KOE_ANDROID_ABI must not be empty"

JAVA_HOME="$(resolve_java_home)" \
  || die "working JDK 17+ not found; install with 'brew install openjdk@17' or set JAVA_HOME"
export JAVA_HOME
export PATH="$JAVA_HOME/bin:$PATH"

ANDROID_SDK_ROOT="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-$HOME/Library/Android/sdk}}"
export ANDROID_SDK_ROOT
export ANDROID_HOME="$ANDROID_SDK_ROOT"
ANDROID_AVD_HOME="${ANDROID_AVD_HOME:-$HOME/.android/avd}"
export ANDROID_AVD_HOME

SDKMANAGER="$(resolve_cmdline_tool "${KOE_SDKMANAGER_BIN:-}" sdkmanager)"

AVD_NAME="koe-test-api${KOE_ANDROID_API}"
SYSTEM_IMAGE="system-images;android-${KOE_ANDROID_API};google_apis;${KOE_ANDROID_ABI}"
PACKAGES=(
  "cmdline-tools;latest"
  "platform-tools"
  "build-tools;35.0.0"
  "platforms;android-36"
  "ndk;28.2.13676358"
  "emulator"
  "$SYSTEM_IMAGE"
)

package_installed() {
  local pkg="$1"
  local dir="$ANDROID_SDK_ROOT/${pkg//;//}"
  case "$pkg" in
    cmdline-tools\;*) [[ -x "$dir/bin/avdmanager" ]] ;;
    platform-tools) [[ -x "$dir/adb" ]] ;;
    emulator) [[ -x "$dir/emulator" ]] ;;
    platforms\;*) [[ -f "$dir/android.jar" ]] ;;
    ndk\;*) [[ -f "$dir/source.properties" ]] ;;
    system-images\;*) [[ -f "$dir/source.properties" ]] ;;
    build-tools\;*) [[ -d "$dir" && ( -f "$dir/package.xml" || -f "$dir/source.properties" || -x "$dir/aapt2" ) ]] ;;
    *) [[ -f "$dir/package.xml" || -f "$dir/source.properties" ]] ;;
  esac
}

avd_exists() {
  local name="$1"
  [[ -f "$ANDROID_AVD_HOME/${name}.ini" && -f "$ANDROID_AVD_HOME/${name}.avd/config.ini" ]]
}

collect_missing_packages() {
  MISSING_PACKAGES=()
  local pkg
  for pkg in "${PACKAGES[@]}"; do
    if ! package_installed "$pkg"; then
      MISSING_PACKAGES+=("$pkg")
    fi
  done
}

run_with_yes() {
  # Ignore SIGPIPE from yes(1) closing early while preserving the consumer's real exit code.
  local status=0
  set +o pipefail
  if yes 2>/dev/null | "$@"; then
    status="${PIPESTATUS[1]:-0}"
  else
    status="${PIPESTATUS[1]:-1}"
  fi
  set -o pipefail
  return "$status"
}

ensure_headless_avd_config() {
  local config_path="$1"
  python3 - "$config_path" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
desired = [
    ("hw.audioInput", "no"),
    ("hw.audioOutput", "no"),
    ("hw.ramSize", "3072"),
    ("disk.dataPartition.size", "4096M"),
]
desired_map = dict(desired)

original = path.read_text(encoding="utf-8") if path.exists() else ""
lines = original.splitlines()
seen = set()
updated = []
for line in lines:
    if "=" in line and not line.lstrip().startswith("#"):
        key, _, _ = line.partition("=")
        k = key.strip()
        if k in desired_map:
            if k not in seen:
                updated.append(f"{k}={desired_map[k]}")
                seen.add(k)
            continue
    updated.append(line)

for k, v in desired:
    if k not in seen:
        updated.append(f"{k}={v}")

rendered = "\n".join(updated) + "\n"
if rendered != original:
    path.write_text(rendered, encoding="utf-8")
PY
}

MISSING_PACKAGES=()
collect_missing_packages

if [[ "$CHECK_ONLY" -eq 1 ]]; then
  missing_items=()
  if [[ ${#MISSING_PACKAGES[@]} -gt 0 ]]; then
    for pkg in "${MISSING_PACKAGES[@]}"; do
      missing_items+=("package:$pkg")
    done
  fi
  if ! avd_exists "$AVD_NAME"; then
    missing_items+=("avd:$AVD_NAME")
  fi
  if [[ ${#missing_items[@]} -gt 0 ]]; then
    printf 'missing Android SDK prerequisites:\n' >&2
    printf '  - %s\n' "${missing_items[@]}" >&2
    exit 1
  fi
  printf 'Android SDK check passed (sdk=%s, avd=%s, abi=%s)\n' "$ANDROID_SDK_ROOT" "$AVD_NAME" "$KOE_ANDROID_ABI"
  exit 0
fi

if [[ ${#MISSING_PACKAGES[@]} -gt 0 ]]; then
  mkdir -p "$ANDROID_SDK_ROOT"
  max_attempts=3
  attempt=1
  while [[ $attempt -le $max_attempts ]]; do
    printf 'Installing Android SDK packages (attempt %d/%d): %s\n' "$attempt" "$max_attempts" "${MISSING_PACKAGES[*]}"
    run_with_yes "$SDKMANAGER" --sdk_root="$ANDROID_SDK_ROOT" --licenses >/dev/null || true
    if run_with_yes "$SDKMANAGER" --sdk_root="$ANDROID_SDK_ROOT" "${MISSING_PACKAGES[@]}"; then
      collect_missing_packages
      if [[ ${#MISSING_PACKAGES[@]} -eq 0 ]]; then
        break
      fi
    fi
    if [[ $attempt -lt $max_attempts ]]; then
      rm -rf "$ANDROID_SDK_ROOT/.temp" "$ANDROID_SDK_ROOT/.downloadIntermediates"
    fi
    attempt=$((attempt + 1))
  done

  collect_missing_packages
  if [[ ${#MISSING_PACKAGES[@]} -gt 0 ]]; then
    die "failed to install Android SDK packages after $max_attempts attempts: ${MISSING_PACKAGES[*]}"
  fi
fi

# Resolve after installing cmdline-tools;latest so SDK-local avdmanager is preferred over Homebrew's.
AVDMANAGER="$(resolve_cmdline_tool "${KOE_AVDMANAGER_BIN:-}" avdmanager)"

if ! avd_exists "$AVD_NAME"; then
  mkdir -p "$ANDROID_AVD_HOME"
  printf 'Creating dedicated test AVD %s (%s)\n' "$AVD_NAME" "$SYSTEM_IMAGE"
  "$AVDMANAGER" create avd --force -n "$AVD_NAME" -k "$SYSTEM_IMAGE" --device pixel_8 <<< "no"
fi

avd_exists "$AVD_NAME" || die "AVD $AVD_NAME was not created in $ANDROID_AVD_HOME"
ensure_headless_avd_config "$ANDROID_AVD_HOME/${AVD_NAME}.avd/config.ini"

printf 'Android SDK bootstrap complete (sdk=%s, avd=%s, abi=%s)\n' "$ANDROID_SDK_ROOT" "$AVD_NAME" "$KOE_ANDROID_ABI"
