#!/usr/bin/env bash
# Install with a stable Developer ID identity so upgrades can read Keychain.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEAM_ID="${TEAM_ID:-LQAVR62TK2}"
TARGET="${MACOS_INSTALL_PATH:-/Applications/Soundcore Manager.app}"
SKIP_BUILD=0
IDENTITY="${MACOS_SIGN_IDENTITY:-}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-build) SKIP_BUILD=1 ;;
    --identity) IDENTITY="${2:?--identity requires a certificate name}"; shift ;;
    -h|--help) echo 'Usage: scripts/install-macos.sh [--skip-build] [--identity NAME]'; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
  shift
done
cd "$ROOT"

designated_requirement() {
  codesign -d -r- "$1" 2>/dev/null | sed -n 's/^designated => //p'
}

# Do not replace files while the installed process is still running.
if pgrep -f "^${TARGET}/Contents/MacOS/Soundcore Manager$" >/dev/null; then
  echo 'Quit Soundcore Manager before installing.' >&2
  exit 1
fi
if [[ "$SKIP_BUILD" -eq 0 ]]; then flutter build macos --release; fi
SOURCE="$ROOT/build/macos/Build/Products/Release/Soundcore Manager.app"
[[ -d "$SOURCE" ]] || { echo 'Release build missing.' >&2; exit 1; }
STAGING="$(mktemp -d "${TMPDIR:-/tmp}/koe-install.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT
APP="$STAGING/Soundcore Manager.app"
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

ditto "$APP" "$TARGET"
"$ROOT/scripts/sign-macos.sh" --verify-only "$TARGET"
echo 'Installed signed macOS Release; existing app data retained.'
