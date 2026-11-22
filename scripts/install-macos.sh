#!/usr/bin/env bash
# Install with a stable Developer ID identity so upgrades can read Keychain.
set -euo pipefail
export MACOSX_DEPLOYMENT_TARGET=14.0
CALLER_PWD="$(pwd -P)"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
TEAM_ID="${TEAM_ID:-LQAVR62TK2}"
TARGET="${MACOS_INSTALL_PATH:-/Applications/Koe.app}"
APP_NAME="Koe"
KEEP_LEGACY=0
SKIP_BUILD=0
VALIDATE_PATHS_ONLY=0
DUMP_INFO_PLIST=0
IDENTITY="${MACOS_SIGN_IDENTITY:-}"

usage() {
  echo 'Usage: scripts/install-macos.sh [--skip-build] [--identity NAME] [--keep-legacy] [--dump-info-plist] [--validate-paths-only]'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-build) SKIP_BUILD=1 ;;
    --keep-legacy) KEEP_LEGACY=1 ;;
    --validate-paths-only) VALIDATE_PATHS_ONLY=1 ;;
    --dump-info-plist) DUMP_INFO_PLIST=1 ;;
    --identity) IDENTITY="${2:?--identity requires a certificate name}"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
  shift
done
cd "$ROOT"

write_info_plist() {
  local out="$1"
  cat > "$out" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>zh_CN</string>
  <key>CFBundleDisplayName</key>
  <string>Koe</string>
  <key>CFBundleExecutable</key>
  <string>Koe</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleIdentifier</key>
  <string>com.anker.ankerRecorder</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>Koe</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>2.7.1</string>
  <key>CFBundleVersion</key>
  <string>17</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSBluetoothAlwaysUsageDescription</key>
  <string>Koe 需要蓝牙权限以连接 Soundcore Work D3200 录音豆。</string>
  <key>NSBluetoothPeripheralUsageDescription</key>
  <string>Koe 需要蓝牙外设权限以与 Soundcore Work D3200 录音豆通信。</string>
  <key>NSMicrophoneUsageDescription</key>
  <string>Koe 需要麦克风权限以进行实时语音同传与本地录音。</string>
  <key>NSAudioCaptureUsageDescription</key>
  <string>Koe 需要音频采集权限以同步录制会议与系统音频。</string>
  <key>NSSpeechRecognitionUsageDescription</key>
  <string>Koe 需要语音识别权限以提供端侧离线语音转写。</string>
  <key>NSLocalNetworkUsageDescription</key>
  <string>Koe 需要本地网络权限以连接录音豆 Wi-Fi SoftAP 快传热点与局域网 MCP 服务。</string>
  <key>NSCalendarsUsageDescription</key>
  <string>Koe 需要日历权限以关联顺带会议与 21 天日历待办。</string>
  <key>NSCalendarsFullAccessUsageDescription</key>
  <string>Koe 需要完整日历访问权限以同步会议议程与待办截止时间。</string>
  <key>NSRemindersUsageDescription</key>
  <string>Koe 需要提醒事项权限以双向同步随心记待办。</string>
  <key>NSRemindersFullAccessUsageDescription</key>
  <string>Koe 需要完整提醒事项访问权限以创建与勾选随心记待办。</string>
</dict>
</plist>
PLIST
}

if [[ "$DUMP_INFO_PLIST" -eq 1 ]]; then
  write_info_plist /dev/stdout
  exit 0
fi

SOURCE="${KOE_BUILD_APP:-$ROOT/build/macos/Build/Products/Release/${APP_NAME}.app}"
SIGN_SCRIPT="${KOE_SIGN_SCRIPT:-$ROOT/scripts/sign-macos.sh}"
OTOOL_BIN="${KOE_OTOOL_BIN:-otool}"
LSREGISTER="${KOE_LSREGISTER:-/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister}"
export KOE_LSREGISTER="$LSREGISTER"

if ! { IFS= read -r -d '' TARGET && IFS= read -r -d '' SOURCE; } < <(
  python3 - "$ROOT" "$CALLER_PWD" "$TARGET" "$SOURCE" "${HOME:-}" <<'PY'
import os
from pathlib import Path
import sys

root_arg, caller_pwd_arg, target_arg, source_arg, home_arg = sys.argv[1:6]
sys.path.insert(0, str(Path(root_arg) / "scripts"))
import cleanup_app_registrations as car

try:
    target, source = car.validate_install_paths(
        target_arg, source_arg, root_arg, caller_pwd_arg, home_arg
    )
except ValueError as exc:
    sys.stderr.write(f"error: {exc}\n")
    raise SystemExit(1)

sys.stdout.buffer.write(
    os.fsencode(str(target)) + b"\0" + os.fsencode(str(source)) + b"\0"
)
PY
); then
  exit 1
fi

if [[ "$VALIDATE_PATHS_ONLY" -eq 1 ]]; then
  exit 0
fi

if [[ "$(uname -s)" == "Darwin" && ! -x "$LSREGISTER" ]]; then
  echo "error: lsregister not found or not executable at $LSREGISTER" >&2
  exit 1
fi

designated_requirement() {
  { codesign -d -r- "$1" 2>/dev/null || true; } | sed -n 's/^designated => //p'
}

ensure_target_not_running() {
  if ! python3 - "$ROOT" "$TARGET" "$APP_NAME" <<'PY'
from pathlib import Path
import sys

root_arg, target_arg, app_name = sys.argv[1:4]
sys.path.insert(0, str(Path(root_arg) / "scripts"))
import cleanup_app_registrations as car

if car.has_running_bundle(Path(target_arg), app_name):
    raise SystemExit(1)
PY
  then
    echo "Quit ${APP_NAME} before installing." >&2
    exit 1
  fi
}

atomic_swap_or_move() {
  python3 - "$ROOT" "$1" "$2" <<'PY'
from pathlib import Path
import sys

root_arg, src_arg, dst_arg = sys.argv[1:4]
sys.path.insert(0, str(Path(root_arg) / "scripts"))
import cleanup_app_registrations as car

sys.stdout.write(car.atomic_swap_or_move(Path(src_arg), Path(dst_arg)))
PY
}

verify_static_host_api_link() {
  local binary="$1"
  local require_macho="${2:-0}"
  [[ -f "$binary" ]] || { echo "error: executable missing: $binary" >&2; exit 1; }
  if ! command -v "$OTOOL_BIN" >/dev/null 2>&1; then
    if [[ "$require_macho" -eq 1 && "$(uname -s)" == "Darwin" ]]; then
      echo "error: otool not found: $OTOOL_BIN" >&2
      exit 1
    fi
    return 0
  fi
  python3 - "$OTOOL_BIN" "$ROOT" "$binary" "$require_macho" <<'PY'
from pathlib import Path
import subprocess
import sys

otool_bin, root_arg, binary_arg, require_macho_arg = sys.argv[1:5]
require_macho = require_macho_arg == "1"
binary_path = Path(binary_arg)
with binary_path.open("rb") as fh:
    header = fh.read(4)

macho_magics = {
    b"\xfe\xed\xfa\xce",
    b"\xce\xfa\xed\xfe",
    b"\xfe\xed\xfa\xcf",
    b"\xcf\xfa\xed\xfe",
    b"\xca\xfe\xba\xbe",
    b"\xbe\xba\xfe\xca",
    b"\xca\xfe\xba\xbf",
    b"\xbf\xba\xfe\xca",
}
if header not in macho_magics:
    if require_macho:
        sys.stderr.write(f"error: expected Mach-O executable at {binary_path}\n")
        raise SystemExit(1)
    raise SystemExit(0)

proc = subprocess.run(
    [otool_bin, "-L", str(binary_path)],
    capture_output=True,
    text=True,
    check=False,
)
if proc.returncode != 0:
    detail = (proc.stderr or proc.stdout).strip()
    sys.stderr.write(f"error: otool -L failed for {binary_path}: {detail}\n")
    raise SystemExit(1)

target_prefixes = (
    f"{root_arg.rstrip('/')}/target/",
    f"{Path(root_arg).resolve()}/target/",
)
offenders: list[str] = []
for raw_line in proc.stdout.splitlines():
    if not raw_line[:1].isspace():
        continue
    dylib_path = raw_line.strip().split(" (", 1)[0].strip()
    if not dylib_path:
        continue
    if (
        "libkoe_host_api" in dylib_path
        or any(dylib_path.startswith(prefix) for prefix in target_prefixes)
        or "/target/debug/" in dylib_path
        or "/target/release/" in dylib_path
    ):
        offenders.append(dylib_path)

if offenders:
    sys.stderr.write(
        "error: Koe must statically link libkoe_host_api.a; "
        "forbidden dynamic dependencies found in LC_LOAD_DYLIB:\n"
    )
    for path in offenders:
        sys.stderr.write(f"  - {path}\n")
    raise SystemExit(1)
PY
}

# Do not replace files while an installed executable is running.
ensure_target_not_running
if [[ -x "$ROOT/scripts/retire-legacy-macos-app.sh" ]]; then
  MACOS_INSTALL_PATH="$TARGET" "$ROOT/scripts/retire-legacy-macos-app.sh" --check-running
fi

if [[ "$SKIP_BUILD" -eq 0 ]]; then
  mkdir -p "$ROOT/build"
  : > "$ROOT/build/.metadata_never_index"
  cargo build --manifest-path "$ROOT/Cargo.toml" --package koe-host-api --release --offline \
    || cargo build --manifest-path "$ROOT/Cargo.toml" --package koe-host-api --release
  swift build --package-path "$ROOT/platforms/macos" -c release
  verify_static_host_api_link "$ROOT/platforms/macos/.build/release/${APP_NAME}" 1
  rm -rf "$SOURCE"
  mkdir -p "$SOURCE/Contents/MacOS" "$SOURCE/Contents/Resources/product"
  cp "$ROOT/platforms/macos/.build/release/${APP_NAME}" "$SOURCE/Contents/MacOS/${APP_NAME}"
  chmod +x "$SOURCE/Contents/MacOS/${APP_NAME}"
  swift "$ROOT/scripts/generate-app-icons.swift" >/dev/null
  swift "$ROOT/scripts/verify-app-icon.swift" "$ROOT/build/macos/AppIcon.iconset" >/dev/null
  iconutil -c icns "$ROOT/build/macos/AppIcon.iconset" -o "$SOURCE/Contents/Resources/AppIcon.icns"
  cp "$ROOT/assets/product/"*.webp "$ROOT/assets/product/"*.png "$SOURCE/Contents/Resources/product/"
  printf 'APPL????' > "$SOURCE/Contents/PkgInfo"
  write_info_plist "$SOURCE/Contents/Info.plist"
fi

[[ -d "$SOURCE" ]] || { echo 'Release build missing.' >&2; exit 1; }
"$LSREGISTER" -u "$SOURCE" >/dev/null 2>&1 || true

DARWIN_TEMP="$(/usr/bin/getconf DARWIN_USER_TEMP_DIR 2>/dev/null || echo "${TMPDIR:-/tmp}")"
STAGING="$(mktemp -d "${DARWIN_TEMP%/}/koe-install.XXXXXX")"
TARGET_STAGE=""
ROLLBACK_MODE=""
cleanup_stage() {
  local status=$?
  trap - EXIT
  set +e
  if [[ "${ROLLBACK_MODE:-}" == "swap" && -n "${TARGET_STAGE:-}" && -d "$TARGET_STAGE/${APP_NAME}.app" ]]; then
    if atomic_swap_or_move "$TARGET_STAGE/${APP_NAME}.app" "$TARGET" >/dev/null 2>&1; then
      "$LSREGISTER" -f "$TARGET" >/dev/null 2>&1 || true
      if [[ -d "$TARGET_STAGE/${APP_NAME}.app" ]]; then
        "$LSREGISTER" -u "$TARGET_STAGE/${APP_NAME}.app" >/dev/null 2>&1 || true
      fi
      rm -rf "$TARGET_STAGE" || true
    else
      echo "rollback failed; previous app retained at $TARGET_STAGE/${APP_NAME}.app" >&2
      status=1
    fi
  elif [[ "${ROLLBACK_MODE:-}" == "new" ]]; then
    "$LSREGISTER" -u "$TARGET" >/dev/null 2>&1 || true
    rm -rf "$TARGET" || true
    if [[ -n "${TARGET_STAGE:-}" && -e "$TARGET_STAGE" ]]; then
      rm -rf "$TARGET_STAGE" || true
    fi
  elif [[ -n "${TARGET_STAGE:-}" && -e "$TARGET_STAGE" ]]; then
    if [[ -d "$TARGET_STAGE/${APP_NAME}.app" ]]; then
      "$LSREGISTER" -u "$TARGET_STAGE/${APP_NAME}.app" >/dev/null 2>&1 || true
    fi
    rm -rf "$TARGET_STAGE" || true
  fi
  if [[ -n "${STAGING:-}" && -e "$STAGING" ]]; then
    if ! python3 "$ROOT/scripts/cleanup_app_registrations.py" --remove "$STAGING"; then
      echo "cleanup: retained $STAGING; unregister failed or the build is running" >&2
      [[ "$status" != 0 ]] || status=1
    fi
  fi
  exit "$status"
}
trap cleanup_stage EXIT
: > "$STAGING/.metadata_never_index"

APP="$STAGING/${APP_NAME}.app"
ditto "$SOURCE" "$APP"
if [[ -L "$APP/Contents" || -L "$APP/Contents/Resources" ]]; then
  echo 'error: bundle Contents and Contents/Resources must be real directories, not symlinks.' >&2
  exit 1
fi
verify_static_host_api_link "$APP/Contents/MacOS/${APP_NAME}" 0
LICENSES="$APP/Contents/Resources/Licenses"
rm -rf "$LICENSES"
mkdir -p "$LICENSES/assets"
cp "$ROOT/THIRD_PARTY_NOTICES.md" "$LICENSES/"
ditto "$ROOT/assets/licenses" "$LICENSES/assets/licenses"
if [[ -n "$IDENTITY" ]]; then
  "$SIGN_SCRIPT" --identity "$IDENTITY" "$APP"
else
  "$SIGN_SCRIPT" "$APP"
fi

# A build with a different code requirement cannot reuse an existing Keychain
# authorization. macOS asks the user once when the item is first read.
NEXT="$(designated_requirement "$APP")"
if [[ -e "$TARGET" ]]; then
  PREVIOUS="$(designated_requirement "$TARGET")"
  if [[ "$PREVIOUS" == "$NEXT" ]]; then
    echo 'Existing install shares this code requirement; saved Keychain access stays valid.'
  else
    echo 'NOTE: the installed build carries a different code requirement:'
    echo "  installed: $PREVIOUS"
    echo "  new:       $NEXT"
    echo 'The first read of an existing Keychain item needs a one-time authorization in the app.'
  fi
fi

mkdir -p "$(dirname "$TARGET")"
TARGET_PARENT="$(cd "$(dirname "$TARGET")" && pwd -P)"
ensure_target_not_running
for orphan_stage in "$TARGET_PARENT"/."${APP_NAME}".stage.*; do
  [[ -e "$orphan_stage" || -L "$orphan_stage" ]] || continue
  if [[ -d "$orphan_stage" && ! -L "$orphan_stage" ]]; then
    for orphan_app in "$orphan_stage"/*.app; do
      if [[ -d "$orphan_app" && ! -L "$orphan_app" ]]; then
        "$LSREGISTER" -u "$orphan_app" >/dev/null 2>&1 || true
      fi
    done
  fi
  rm -rf "$orphan_stage"
done

TARGET_STAGE="$(mktemp -d "$TARGET_PARENT/.${APP_NAME}.stage.XXXXXX")"
: > "$TARGET_STAGE/.metadata_never_index"
ditto "$APP" "$TARGET_STAGE/${APP_NAME}.app"
"$SIGN_SCRIPT" --verify-only "$TARGET_STAGE/${APP_NAME}.app"
"$TARGET_STAGE/${APP_NAME}.app/Contents/MacOS/$APP_NAME" --verify-self
"$TARGET_STAGE/${APP_NAME}.app/Contents/MacOS/$APP_NAME" --smoke-test

ensure_target_not_running
ROLLBACK_MODE="$(atomic_swap_or_move "$TARGET_STAGE/${APP_NAME}.app" "$TARGET")"

"$SIGN_SCRIPT" --verify-only "$TARGET"
"$LSREGISTER" -f "$TARGET"
"$TARGET/Contents/MacOS/$APP_NAME" --verify-self
"$TARGET/Contents/MacOS/$APP_NAME" --smoke-test

ROLLBACK_MODE=""
if [[ "$TARGET" == "/Applications/${APP_NAME}.app" || "$TARGET" == "$HOME/Applications/${APP_NAME}.app" ]]; then
  DARWIN_CACHE="$(/usr/bin/getconf DARWIN_USER_CACHE_DIR 2>/dev/null || true)"
  if [[ -n "$DARWIN_CACHE" && -d "$DARWIN_CACHE" ]]; then
    rm -f "${DARWIN_CACHE%/}"/com.apple.dock.iconcache* || true
  fi
fi
if [[ "$TARGET" == "/Applications/Koe.app" && -d "/Applications/KoeSwiftUI.app" ]]; then
  "$LSREGISTER" -u "/Applications/KoeSwiftUI.app" >/dev/null 2>&1 || true
  rm -rf "/Applications/KoeSwiftUI.app"
fi
if [[ -d "$TARGET_STAGE/${APP_NAME}.app" ]]; then
  "$LSREGISTER" -u "$TARGET_STAGE/${APP_NAME}.app" >/dev/null 2>&1 || true
fi
rm -rf "$TARGET_STAGE"
TARGET_STAGE=""
if [[ "$SOURCE" != "$STAGING"/* ]]; then
  python3 "$ROOT/scripts/cleanup_app_registrations.py" "$SOURCE"
fi

if [[ "$KEEP_LEGACY" -eq 1 ]]; then
  echo 'NOTE: --keep-legacy left the old Soundcore Manager.app in place; it shares the Bundle ID and may still be launched.'
elif [[ -x "$ROOT/scripts/retire-legacy-macos-app.sh" ]]; then
  MACOS_INSTALL_PATH="$TARGET" "$ROOT/scripts/retire-legacy-macos-app.sh"
fi
echo 'Installed signed macOS Release; existing app data retained.'
