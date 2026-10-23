#!/usr/bin/env bash
# Install with a stable Developer ID identity so upgrades can read Keychain.
set -euo pipefail
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
if pgrep -f "^${TARGET}/Contents/MacOS/${APP_NAME}$" >/dev/null; then
  echo "Quit ${APP_NAME} before installing." >&2
  exit 1
fi
# The pre-rename bundle shares the Bundle ID; it must not be running either.
# It also refuses when the install target is the old bundle path.
MACOS_INSTALL_PATH="$TARGET" "$ROOT/scripts/retire-legacy-macos-app.sh" --check-running
if [[ "$SKIP_BUILD" -eq 0 ]]; then flutter build macos --release; fi
SOURCE="$ROOT/build/macos/Build/Products/Release/${APP_NAME}.app"
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
ditto "$APP" "$TARGET"
"$ROOT/scripts/sign-macos.sh" --verify-only "$TARGET"

# Keep a single launchable copy: archive, then remove the pre-rename bundle.
if [[ "$KEEP_LEGACY" -eq 1 ]]; then
  echo 'NOTE: --keep-legacy left the old Soundcore Manager.app in place; it shares the Bundle ID and may still be launched.'
else
  MACOS_INSTALL_PATH="$TARGET" "$ROOT/scripts/retire-legacy-macos-app.sh"
fi
echo 'Installed signed macOS Release; existing app data retained.'
