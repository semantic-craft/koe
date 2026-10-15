#!/usr/bin/env bash
# Install with a stable Developer ID identity so upgrades can read Keychain.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEAM_ID="${TEAM_ID:-LQAVR62TK2}"
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
if [[ -z "$IDENTITY" ]]; then
  identities=()
  while IFS= read -r value; do
    [[ -z "$value" ]] || identities+=("$value")
  done < <(security find-identity -v -p codesigning | sed -nE 's/.*"(Developer ID Application:[^"]*)".*/\1/p' | awk -v team="($TEAM_ID)" 'index($0,team)')
  if [[ ${#identities[@]} -ne 1 ]]; then
    echo 'A unique Developer ID Application certificate is required; pass --identity. No ad-hoc fallback.' >&2
    exit 1
  fi
  IDENTITY="${identities[0]}"
fi
# Do not replace files while the installed process is still running.
if pgrep -f '^/Applications/Soundcore Manager.app/Contents/MacOS/Soundcore Manager$' >/dev/null; then
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
codesign --force --deep --sign "$IDENTITY" --options runtime --timestamp=none \
  --entitlements macos/Runner/Release.entitlements "$APP"
codesign --verify --deep --strict "$APP"
# Verify the stable trust boundary before replacing the installed app.
REQUIREMENT="=identifier \"com.anker.ankerRecorder\" and anchor apple generic and certificate leaf[subject.OU] = \"$TEAM_ID\""
codesign --verify --strict -R "$REQUIREMENT" "$APP"
ditto "$APP" '/Applications/Soundcore Manager.app'
codesign --verify --deep --strict -R "$REQUIREMENT" '/Applications/Soundcore Manager.app'
echo 'Installed signed macOS Release; existing app data retained.'
