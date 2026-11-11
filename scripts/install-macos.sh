#!/usr/bin/env bash
# Install with a stable Developer ID identity so upgrades can read Keychain.
set -euo pipefail
export MACOSX_DEPLOYMENT_TARGET=14.0
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
TEAM_ID="${TEAM_ID:-LQAVR62TK2}"
TARGET="${MACOS_INSTALL_PATH:-/Applications/Koe.app}"
APP_NAME="Koe"
KEEP_LEGACY=0
SKIP_BUILD=0
VALIDATE_PATHS_ONLY=0
WRITE_INFO_PLIST=""
IDENTITY="${MACOS_SIGN_IDENTITY:-}"

usage() {
  echo 'Usage: scripts/install-macos.sh [--skip-build] [--identity NAME] [--keep-legacy] [--write-info-plist PATH] [--validate-paths-only]'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-build) SKIP_BUILD=1 ;;
    --keep-legacy) KEEP_LEGACY=1 ;;
    --validate-paths-only) VALIDATE_PATHS_ONLY=1 ;;
    --write-info-plist) WRITE_INFO_PLIST="${2:?--write-info-plist requires an output path}"; shift ;;
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
  <string>2.0.0</string>
  <key>CFBundleVersion</key>
  <string>8</string>
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

if [[ -n "$WRITE_INFO_PLIST" ]]; then
  mkdir -p "$(dirname "$WRITE_INFO_PLIST")"
  write_info_plist "$WRITE_INFO_PLIST"
  exit 0
fi

SOURCE="${KOE_BUILD_APP:-$ROOT/build/macos/Build/Products/Release/${APP_NAME}.app}"
SIGN_SCRIPT="${KOE_SIGN_SCRIPT:-$ROOT/scripts/sign-macos.sh}"
LSREGISTER="${KOE_LSREGISTER:-/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister}"

if [[ "$TARGET" == "~/"* ]]; then
  TARGET="$HOME/${TARGET#\~/}"
fi
if [[ "$SOURCE" == "~/"* ]]; then
  SOURCE="$HOME/${SOURCE#\~/}"
fi
while [[ "$TARGET" != "/" && "$TARGET" == */ ]]; do
  TARGET="${TARGET%/}"
done
while [[ "$SOURCE" != "/" && "$SOURCE" == */ ]]; do
  SOURCE="${SOURCE%/}"
done

python3 - "$TARGET" "$SOURCE" "$ROOT" "${HOME:-}" <<'PY'
import os
from pathlib import Path
import sys

target_arg, source_arg, root_arg, home_arg = sys.argv[1:5]
if not target_arg or not source_arg:
    sys.stderr.write("error: empty install target or build source path\n")
    raise SystemExit(1)

raw_target = Path(os.path.abspath(target_arg))
raw_source = Path(os.path.abspath(source_arg))

for label, raw in (("MACOS_INSTALL_PATH", raw_target), ("KOE_BUILD_APP", raw_source)):
    if not raw.name.endswith(".app") or len(raw.name) <= 4:
        sys.stderr.write(f"error: {label} must name a .app bundle: {raw}\n")
        raise SystemExit(1)
    if raw.is_symlink():
        sys.stderr.write(f"error: {label} must not be a symlink: {raw}\n")
        raise SystemExit(1)


def is_case_insensitive(path: Path) -> bool:
    probe = path
    while not probe.exists() and probe != probe.parent:
        probe = probe.parent
    cur = probe
    while cur != cur.parent:
        alt = cur.with_name(cur.name.swapcase())
        if alt != cur:
            return alt.exists() and cur.samefile(alt)
        cur = cur.parent
    try:
        entries = list(probe.iterdir())
    except OSError:
        return False
    for entry in entries:
        alt = entry.with_name(entry.name.swapcase())
        if alt != entry:
            return alt.exists() and entry.samefile(alt)
    return False


def inside(path: Path, root: Path) -> bool:
    if path == root or root in path.parents:
        return True
    if path.exists() and root.exists() and path.samefile(root):
        return True
    if is_case_insensitive(root) or is_case_insensitive(path):
        parts = tuple(p.casefold() for p in path.parts)
        prefix = tuple(p.casefold() for p in root.parts)
        return len(parts) >= len(prefix) and parts[:len(prefix)] == prefix
    return False


target = raw_target.resolve()
source = raw_source.resolve()
root = Path(os.path.abspath(root_arg)).resolve()
home = Path(os.path.abspath(home_arg or str(Path.home()))).resolve()
sys_apps = Path("/Applications").resolve()
home_apps = (home / "Applications").resolve()

if inside(target, root) or inside(root, target):
    sys.stderr.write(f"error: MACOS_INSTALL_PATH overlaps repository root: {target}\n")
    raise SystemExit(1)
if inside(target, source) or inside(source, target):
    sys.stderr.write(f"error: MACOS_INSTALL_PATH overlaps KOE_BUILD_APP: {target}\n")
    raise SystemExit(1)

for protected in (Path("/"), sys_apps, home, home_apps):
    if inside(protected, target):
        sys.stderr.write(f"error: MACOS_INSTALL_PATH cannot equal or contain {protected}: {target}\n")
        raise SystemExit(1)
    if inside(protected, source):
        sys.stderr.write(f"error: KOE_BUILD_APP cannot equal or contain {protected}: {source}\n")
        raise SystemExit(1)

if inside(root, source) or inside(source, sys_apps) or inside(source, home_apps):
    sys.stderr.write(f"error: unsafe KOE_BUILD_APP location: {source}\n")
    raise SystemExit(1)
PY

if [[ "$VALIDATE_PATHS_ONLY" -eq 1 ]]; then
  exit 0
fi

designated_requirement() {
  { codesign -d -r- "$1" 2>/dev/null || true; } | sed -n 's/^designated => //p'
}

# Do not replace files while the installed process is still running.
if pgrep -f "^${TARGET}/Contents/MacOS/${APP_NAME}([[:space:]]|$)" >/dev/null; then
  echo "Quit ${APP_NAME} before installing." >&2
  exit 1
fi
if [[ -x "$ROOT/scripts/retire-legacy-macos-app.sh" ]]; then
  MACOS_INSTALL_PATH="$TARGET" "$ROOT/scripts/retire-legacy-macos-app.sh" --check-running
fi

if [[ "$SKIP_BUILD" -eq 0 ]]; then
  mkdir -p "$ROOT/build"
  : > "$ROOT/build/.metadata_never_index"
  cargo build --manifest-path "$ROOT/Cargo.toml" --package koe-host-api --release --offline \
    || cargo build --manifest-path "$ROOT/Cargo.toml" --package koe-host-api --release
  swift build --package-path "$ROOT/platforms/macos" -c release
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
if [[ -x "$LSREGISTER" ]]; then
  "$LSREGISTER" -u "$SOURCE" >/dev/null 2>&1 || true
fi

DARWIN_TEMP="$(/usr/bin/getconf DARWIN_USER_TEMP_DIR 2>/dev/null || echo "${TMPDIR:-/tmp}")"
STAGING="$(mktemp -d "${DARWIN_TEMP%/}/koe-install.XXXXXX")"
TARGET_STAGE=""
cleanup_stage() {
  local status=$?
  trap - EXIT
  if [[ -n "${TARGET_STAGE:-}" && -e "$TARGET_STAGE" ]]; then
    rm -rf "$TARGET_STAGE"
  fi
  if ! python3 "$ROOT/scripts/cleanup_app_registrations.py" --remove "$STAGING"; then
    echo "cleanup: retained $STAGING; unregister failed or the build is running" >&2
    [[ "$status" != 0 ]] || status=1
  fi
  exit "$status"
}
trap cleanup_stage EXIT
: > "$STAGING/.metadata_never_index"

APP="$STAGING/${APP_NAME}.app"
ditto "$SOURCE" "$APP"
if [[ -n "$IDENTITY" ]]; then
  "$SIGN_SCRIPT" --identity "$IDENTITY" "$APP"
else
  "$SIGN_SCRIPT" "$APP"
fi

# A build with a different code requirement cannot reuse an existing Keychain
# authorization: macOS asks the user once, when the item is first read.
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
TARGET_STAGE="$(mktemp -d "$TARGET_PARENT/.${APP_NAME}.stage.XXXXXX")"
: > "$TARGET_STAGE/.metadata_never_index"
ditto "$APP" "$TARGET_STAGE/${APP_NAME}.app"
"$SIGN_SCRIPT" --verify-only "$TARGET_STAGE/${APP_NAME}.app"
if [[ -e "$TARGET" ]]; then
  mv "$TARGET" "$TARGET_STAGE/previous.app"
fi
if ! mv "$TARGET_STAGE/${APP_NAME}.app" "$TARGET"; then
  if [[ -e "$TARGET_STAGE/previous.app" && ! -e "$TARGET" ]]; then
    mv "$TARGET_STAGE/previous.app" "$TARGET" || true
  fi
  echo "Failed to replace $TARGET atomically." >&2
  exit 1
fi
if [[ "$TARGET" == "/Applications/Koe.app" && -d "/Applications/KoeSwiftUI.app" ]]; then
  rm -rf "/Applications/KoeSwiftUI.app"
fi
rm -rf "$TARGET_STAGE"
TARGET_STAGE=""

"$SIGN_SCRIPT" --verify-only "$TARGET"
if [[ -x "$LSREGISTER" ]]; then
  "$LSREGISTER" -f "$TARGET"
fi
"$TARGET/Contents/MacOS/$APP_NAME" --verify-self
"$TARGET/Contents/MacOS/$APP_NAME" --smoke-test

if [[ "$KEEP_LEGACY" -eq 1 ]]; then
  echo 'NOTE: --keep-legacy left the old Soundcore Manager.app in place; it shares the Bundle ID and may still be launched.'
elif [[ -x "$ROOT/scripts/retire-legacy-macos-app.sh" ]]; then
  MACOS_INSTALL_PATH="$TARGET" "$ROOT/scripts/retire-legacy-macos-app.sh"
fi
echo 'Installed signed macOS Release; existing app data retained.'
