#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

INSTALL_APP=0
for arg in "$@"; do
  case "$arg" in
    --install) INSTALL_APP=1 ;;
    *) echo "Unknown argument: $arg" >&2; exit 1 ;;
  esac
done

cargo build --manifest-path rust/Cargo.toml --package koe_core_ffi --release --quiet

APP_DIR="$ROOT/build/native/KoeSwiftUI.app"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Frameworks" "$APP_DIR/Contents/Resources"

cat > "$APP_DIR/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>zh-Hans</string>
  <key>CFBundleDisplayName</key>
  <string>Koe SwiftUI</string>
  <key>CFBundleExecutable</key>
  <string>KoeSwiftUI</string>
  <key>CFBundleIdentifier</key>
  <string>com.anker.ankerRecorder</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>KoeSwiftUI</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>2.0.0</string>
  <key>CFBundleVersion</key>
  <string>8</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
  <key>NSBluetoothAlwaysUsageDescription</key>
  <string>Koe 使用蓝牙查找并连接已适配的安克录音豆（soundcore Work / D3200），管理录音。</string>
  <key>NSSpeechRecognitionUsageDescription</key>
  <string>Koe 使用本机语音识别显示录音的实时文字。</string>
  <key>NSMicrophoneUsageDescription</key>
  <string>Koe 使用麦克风录制并实时转写语音。</string>
</dict>
</plist>
EOF

cp rust/target/release/libkoe_core_ffi.dylib "$APP_DIR/Contents/Frameworks/libkoe_core_ffi.dylib"
install_name_tool -id "@rpath/libkoe_core_ffi.dylib" "$APP_DIR/Contents/Frameworks/libkoe_core_ffi.dylib"

ARCH=$(uname -m)
swiftc \
  -O \
  -target "${ARCH}-apple-macos14.0" \
  -DKOE_STANDALONE_SWIFTUI \
  -import-objc-header rust/koe_core_ffi/include/koe_core_ffi.h \
  -L "$APP_DIR/Contents/Frameworks" \
  -lkoe_core_ffi \
  -Xlinker -rpath -Xlinker "@executable_path/../Frameworks" \
  darwin/KoeCore.swift \
  darwin/KeychainStore.swift \
  darwin/KoeNativeTransport.swift \
  darwin/KoeNativeHost.swift \
  darwin/KoeNativeAppMain.swift \
  -o "$APP_DIR/Contents/MacOS/KoeSwiftUI"

if security find-identity -v -p codesigning | grep -q "Developer ID Application:.*(LQAVR62TK2)"; then
  ./scripts/sign-macos.sh "$APP_DIR"
fi

if [[ "$INSTALL_APP" -eq 1 ]]; then
  rm -rf /Applications/KoeSwiftUI.app
  ditto "$APP_DIR" /Applications/KoeSwiftUI.app
  ./scripts/sign-macos.sh --verify-only /Applications/KoeSwiftUI.app
  echo "Installed: /Applications/KoeSwiftUI.app"
fi
