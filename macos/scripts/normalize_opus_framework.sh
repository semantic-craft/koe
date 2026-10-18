#!/bin/sh
set -eu

# opus_codec_macos 3.0.5 ships a shallow macOS framework: the dylib and
# Info.plist sit at the framework root while Versions/A is empty. Xcode
# rejects that layout when signing the app ("contains Info.plist, expected
# Versions/Current/Resources/Info.plist"). Normalize the CocoaPods
# XCFrameworkIntermediates copy before [CP] Embed Pods Frameworks copies and
# signs it. Moving the dylib does not change its install name or rpaths.
xcframeworks_dir="${PODS_XCFRAMEWORKS_BUILD_DIR:-${PODS_CONFIGURATION_BUILD_DIR:-}}"
if [ -z "$xcframeworks_dir" ]; then
  echo "error: CocoaPods xcframework build directory is not set" >&2
  exit 1
fi
framework="${xcframeworks_dir}/opus_codec_macos/opus.framework"

if [ ! -d "$framework" ]; then
  echo "error: opus.framework not found at $framework" >&2
  exit 1
fi

# Drop a signature left by an earlier failed build; CocoaPods signs the
# embedded copy after this phase.
rm -rf "$framework/_CodeSignature" "$framework/Versions/A/_CodeSignature"

# Idempotent: a previous build already normalized the intermediate.
if [ -L "$framework/Versions/Current" ] &&
  [ -f "$framework/Versions/A/opus" ] &&
  [ -f "$framework/Versions/A/Resources/Info.plist" ] &&
  [ -L "$framework/opus" ] &&
  [ -L "$framework/Resources" ]; then
  exit 0
fi

mkdir -p "$framework/Versions/A/Resources"

if [ -f "$framework/Info.plist" ] && [ ! -L "$framework/Info.plist" ]; then
  mv "$framework/Info.plist" "$framework/Versions/A/Resources/Info.plist"
fi

if [ -f "$framework/opus" ] && [ ! -L "$framework/opus" ]; then
  mv "$framework/opus" "$framework/Versions/A/opus"
fi

for dir in Headers Modules; do
  if [ -d "$framework/$dir" ] && [ ! -L "$framework/$dir" ]; then
    if [ -d "$framework/Versions/A/$dir" ]; then
      rm -rf "$framework/$dir"
    else
      mv "$framework/$dir" "$framework/Versions/A/$dir"
    fi
  fi
done

if [ -e "$framework/Versions/Current" ] && [ ! -L "$framework/Versions/Current" ]; then
  rm -rf "$framework/Versions/Current"
fi
ln -sfn A "$framework/Versions/Current"

if [ -e "$framework/Resources" ] && [ ! -L "$framework/Resources" ]; then
  rm -rf "$framework/Resources"
fi
ln -sfn Versions/Current/Resources "$framework/Resources"
ln -sfn Versions/Current/opus "$framework/opus"

for dir in Headers Modules; do
  if [ -d "$framework/Versions/A/$dir" ]; then
    if [ -e "$framework/$dir" ] && [ ! -L "$framework/$dir" ]; then
      rm -rf "$framework/$dir"
    fi
    ln -sfn "Versions/Current/$dir" "$framework/$dir"
  fi
done

for path in \
  "$framework/Versions/Current/opus" \
  "$framework/Versions/Current/Resources/Info.plist"; do
  if [ ! -e "$path" ]; then
    echo "error: opus.framework normalization failed: $path is missing" >&2
    exit 1
  fi
done
