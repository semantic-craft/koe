#!/usr/bin/env bash
# Install with a stable Developer ID identity so upgrades can read Keychain.
set -euo pipefail
export MACOSX_DEPLOYMENT_TARGET=14.0
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEAM_ID="${TEAM_ID:-LQAVR62TK2}"
TARGET="${MACOS_INSTALL_PATH:-/Applications/Koe.app}"
APP_NAME="Koe"
KEEP_LEGACY=0
SKIP_BUILD=0
IDENTITY="${MACOS_SIGN_IDENTITY:-}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-build) SKIP_BUILD=1 ;;
    --keep-legacy) KEEP_LEGACY=1 ;;
    --identity) IDENTITY="${2:?--identity requires a certificate name}"; shift ;;
    -h|--help) echo 'Usage: scripts/install-macos.sh [--skip-build] [--identity NAME] [--keep-legacy]'; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
  shift
done
cd "$ROOT"

designated_requirement() {
  codesign -d -r- "$1" 2>/dev/null | sed -n 's/^designated => //p'
}

# Do not replace files while the installed process is still running.
if pgrep -f "^${TARGET}/Contents/MacOS/${APP_NAME}([[:space:]]|$)" >/dev/null; then
  echo "Quit ${APP_NAME} before installing." >&2
  exit 1
fi
if [[ -x "$ROOT/scripts/retire-legacy-macos-app.sh" ]]; then
  MACOS_INSTALL_PATH="$TARGET" "$ROOT/scripts/retire-legacy-macos-app.sh" --check-running
fi
SOURCE="$ROOT/build/macos/Build/Products/Release/${APP_NAME}.app"
if [[ "$SKIP_BUILD" -eq 0 ]]; then
  cargo build --manifest-path "$ROOT/Cargo.toml" --package koe-host-api --release --offline \
    || cargo build --manifest-path "$ROOT/Cargo.toml" --package koe-host-api --release
  swift build --package-path "$ROOT/platforms/macos" -c release
  rm -rf "$SOURCE"
  mkdir -p "$SOURCE/Contents/MacOS" "$SOURCE/Contents/Resources"
  cp "$ROOT/platforms/macos/.build/release/${APP_NAME}" "$SOURCE/Contents/MacOS/${APP_NAME}"
  chmod +x "$SOURCE/Contents/MacOS/${APP_NAME}"
  swift "$ROOT/scripts/generate-app-icons.swift" >/dev/null
  iconutil -c icns "$ROOT/build/macos/AppIcon.iconset" -o "$SOURCE/Contents/Resources/AppIcon.icns"
  cp "$ROOT/assets/artwork/koe-schoolgirl-b-cheerful.png" "$SOURCE/Contents/Resources/AppIcon.png"
  printf 'APPL????' > "$SOURCE/Contents/PkgInfo"
  cat > "$SOURCE/Contents/Info.plist" <<'PLIST'
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
  <key>CFBundleIconName</key>
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
fi
[[ -d "$SOURCE" ]] || { echo 'Release build missing.' >&2; exit 1; }
STAGING="$(mktemp -d "${TMPDIR:-/tmp}/koe-install.XXXXXX")"
cleanup_stage() {
  local status=$?
  trap - EXIT
  if ! python3 "$ROOT/scripts/cleanup_app_registrations.py" --remove "$STAGING"; then
    echo "cleanup: retained $STAGING; unregister failed or the build is running" >&2
    [[ "$status" != 0 ]] || status=1
  fi
  exit "$status"
}
trap cleanup_stage EXIT
APP="$STAGING/${APP_NAME}.app"
ditto "$SOURCE" "$APP"
if [[ -n "$IDENTITY" ]]; then
  "$ROOT/scripts/sign-macos.sh" --identity "$IDENTITY" "$APP"
else
  "$ROOT/scripts/sign-macos.sh" "$APP"
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

# ditto merges into an existing bundle: files the new build no longer ships
# would stay behind and break the code seal. Replace the bundle whole.
rm -rf "$TARGET"
if [[ "$TARGET" == "/Applications/Koe.app" && -d "/Applications/KoeSwiftUI.app" ]]; then
  rm -rf "/Applications/KoeSwiftUI.app"
fi
ditto "$APP" "$TARGET"
"$ROOT/scripts/sign-macos.sh" --verify-only "$TARGET"
"$TARGET/Contents/MacOS/$APP_NAME" --verify-self
"$TARGET/Contents/MacOS/$APP_NAME" --smoke-test

if [[ "$KEEP_LEGACY" -eq 1 ]]; then
  echo 'NOTE: --keep-legacy left the old Soundcore Manager.app in place; it shares the Bundle ID and may still be launched.'
elif [[ -x "$ROOT/scripts/retire-legacy-macos-app.sh" ]]; then
  MACOS_INSTALL_PATH="$TARGET" "$ROOT/scripts/retire-legacy-macos-app.sh"
fi
echo 'Installed signed macOS Release; existing app data retained.'
