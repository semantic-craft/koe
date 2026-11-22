#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEAM_ID="${TEAM_ID:-LQAVR62TK2}"
BUNDLE_ID="${BUNDLE_ID:-com.anker.ankerRecorder}"
IDENTITY="${MACOS_SIGN_IDENTITY:-}"
ENTITLEMENTS="${MACOS_SIGN_ENTITLEMENTS:-$ROOT/platforms/macos/Release.entitlements}"
VERIFY_ONLY=0
APP=""

usage() {
  cat <<'EOF'
Usage: scripts/sign-macos.sh [--identity NAME] [--verify-only] APP

  --identity NAME   Certificate to use; default is the unique Developer ID
                    Application certificate of TEAM_ID.
  --verify-only     Check the seal and trust boundary without signing.

An unstable signature (ad-hoc, or a certificate from another team) makes macOS
ask for the login keychain password again after every rebuild, so this script
has no ad-hoc fallback: it stops instead.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --identity) IDENTITY="${2:?--identity requires a certificate name}"; shift ;;
    --verify-only) VERIFY_ONLY=1 ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
    *) APP="$1" ;;
  esac
  shift
done
[[ -n "$APP" ]] || { usage >&2; exit 1; }
[[ -d "$APP" ]] || { echo "error: not an app bundle: $APP" >&2; exit 1; }

REQUIREMENT="=identifier \"$BUNDLE_ID\" and anchor apple generic and certificate leaf[subject.OU] = \"$TEAM_ID\""

# shellcheck source=scripts/lib/macos-signing.sh
source "$ROOT/scripts/lib/macos-signing.sh"

# `codesign -dv` does not print CDHash; -dvvv is the level that does.
cdhash_of() {
  codesign -dvvv "$1" 2>&1 | sed -n 's/^CDHash=//p'
}

verify() {
  codesign --verify --deep --strict "$1"
  codesign --verify --strict -R "$REQUIREMENT" "$1"
}

if [[ "$VERIFY_ONLY" -eq 1 ]]; then
  verify "$APP"
  echo "Verified: $APP"
  echo "Designated requirement: $(designated_requirement "$APP")"
  exit 0
fi

IDENTITY="$(resolve_signing_identity "$IDENTITY" "$TEAM_ID")"
[[ -f "$ENTITLEMENTS" ]] || { echo "error: missing entitlements: $ENTITLEMENTS" >&2; exit 1; }

# Sign nested code inside-out. --deep is a verification aid, not a signing policy.
while IFS= read -r target; do
  codesign --force --sign "$IDENTITY" --options runtime --timestamp=none "$target"
done < <(find "$APP/Contents/Frameworks" -mindepth 1 -maxdepth 1 \
           \( -name '*.framework' -o -name '*.dylib' \) 2>/dev/null | sort -r)
codesign --force --sign "$IDENTITY" --options runtime --timestamp=none \
  --entitlements "$ENTITLEMENTS" "$APP"

verify "$APP"
echo "Signed: $APP"
echo "Identity: $IDENTITY"
echo "CDHash: $(cdhash_of "$APP")"
echo "Designated requirement: $(designated_requirement "$APP")"
