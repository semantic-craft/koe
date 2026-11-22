#!/usr/bin/env bash
set -euo pipefail

export MACOSX_DEPLOYMENT_TARGET=14.0
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
TEAM_ID="${TEAM_ID:-LQAVR62TK2}"
BUNDLE_ID="${BUNDLE_ID:-com.anker.ankerRecorder}"
APP_NAME="Koe"
ENTITLEMENTS="${MACOS_SIGN_ENTITLEMENTS:-$ROOT/platforms/macos/Release.entitlements}"
INSTALL_SCRIPT="${KOE_INSTALL_SCRIPT:-$ROOT/scripts/install-macos.sh}"
SIGN_SCRIPT="${KOE_SIGN_SCRIPT:-$ROOT/scripts/sign-macos.sh}"
CODESIGN_BIN="${KOE_CODESIGN_BIN:-codesign}"
DITTO_BIN="${KOE_DITTO_BIN:-ditto}"
MACOS_NOTARY_BIN="${MACOS_NOTARY_BIN:-macos-notary}"
MACOS_NOTARY_PROFILE_BIN="${MACOS_NOTARY_PROFILE_BIN:-macos-notary-profile}"
LSREGISTER="${KOE_LSREGISTER:-/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister}"
export KOE_LSREGISTER="$LSREGISTER"

OUTPUT_DIR="$ROOT/dist"
APP_INPUT=""
IDENTITY="${MACOS_SIGN_IDENTITY:-}"
PROFILE=""
SKIP_BUILD="${KOE_RELEASE_SKIP_BUILD:-0}"
DRY_RUN=0

usage() {
  cat <<'EOF'
Usage: scripts/release-macos.sh [options]

  --app PATH          Sign, verify, notarize, and package an existing .app bundle
                      copied into a clean staging directory.
  -o, --output-dir D  Directory for release zip and SHA256SUMS.txt (default: dist).
  --identity NAME     Developer ID Application certificate name.
  --profile NAME      Notary keychain profile override.
  --skip-build        Forward --skip-build to scripts/install-macos.sh.
  --dry-run           Run staging, timestamped signing, verification, packaging,
                      and `macos-notary submit --dry-run` without uploading.
  -h, --help          Show this help text.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app)
      APP_INPUT="${2:?--app requires a .app bundle path}"
      shift
      ;;
    -o|--output-dir)
      OUTPUT_DIR="${2:?--output-dir requires a directory path}"
      shift
      ;;
    --identity)
      IDENTITY="${2:?--identity requires a certificate name}"
      shift
      ;;
    --profile)
      PROFILE="${2:?--profile requires a profile name}"
      shift
      ;;
    --skip-build)
      SKIP_BUILD=1
      ;;
    --dry-run)
      DRY_RUN=1
      ;;
    --timestamp=none|--no-timestamp)
      echo "error: --timestamp=none is forbidden for release notarization; a secure timestamp is required." >&2
      exit 1
      ;;
    --timestamp)
      if [[ "${2:-}" == "none" ]]; then
        echo "error: --timestamp=none is forbidden for release notarization; a secure timestamp is required." >&2
        exit 1
      fi
      echo "error: unexpected option $1 (secure timestamp is always enabled)." >&2
      exit 1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
  shift
done

[[ -f "$ENTITLEMENTS" ]] || { echo "error: missing entitlements: $ENTITLEMENTS" >&2; exit 1; }
[[ -x "$SIGN_SCRIPT" ]] || { echo "error: missing executable sign script: $SIGN_SCRIPT" >&2; exit 1; }
if [[ -z "$APP_INPUT" ]]; then
  [[ -x "$INSTALL_SCRIPT" ]] || { echo "error: missing executable install script: $INSTALL_SCRIPT" >&2; exit 1; }
else
  APP_INPUT="${APP_INPUT%/}"
  [[ -n "$APP_INPUT" && ! -L "$APP_INPUT" && -d "$APP_INPUT" && "$APP_INPUT" == *.app ]] || {
    echo "error: --app must point to an existing .app directory (not a symlink): $APP_INPUT" >&2
    exit 1
  }
fi

if ! command -v "$MACOS_NOTARY_BIN" >/dev/null 2>&1; then
  echo "error: macos-notary not found: $MACOS_NOTARY_BIN" >&2
  exit 1
fi

# shellcheck source=scripts/lib/macos-signing.sh
source "$ROOT/scripts/lib/macos-signing.sh"

resolve_notary_profile() {
  local resolved=""
  if [[ -n "$PROFILE" ]]; then
    resolved="$PROFILE"
  elif [[ -n "${KOE_NOTARY_PROFILE:-}" ]]; then
    resolved="$KOE_NOTARY_PROFILE"
  elif [[ -n "${NOTARY_PROFILE:-}" ]]; then
    resolved="$NOTARY_PROFILE"
  elif command -v "$MACOS_NOTARY_PROFILE_BIN" >/dev/null 2>&1; then
    resolved="$("$MACOS_NOTARY_PROFILE_BIN" 2>/dev/null || true)"
  fi
  resolved="$(printf '%s' "$resolved" | tr -d '\r\n' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  printf '%s' "${resolved:-xw-notary}"
}

verify_codesign_release_metadata() {
  local app="$1"
  local details entitlements_xml
  details="$("$CODESIGN_BIN" -dvvv "$app" 2>&1)"
  entitlements_xml="$("$CODESIGN_BIN" -d --entitlements :- "$app" 2>/dev/null || true)"
  python3 - "$details" "$entitlements_xml" "$ENTITLEMENTS" <<'PY'
import plistlib
import re
import sys

details, ent_xml, expected_ent_path = sys.argv[1:4]

if re.search(r"^Signature=adhoc\b", details, re.M):
    sys.stderr.write("error: ad-hoc signature is forbidden for release notarization.\n")
    raise SystemExit(1)

ts_match = re.search(r"^Timestamp=(.+)$", details, re.M)
if not ts_match or ts_match.group(1).strip().lower() == "none":
    sys.stderr.write("error: missing secure Apple timestamp (--timestamp=none is forbidden).\n")
    raise SystemExit(1)

cd_match = re.search(r"^CodeDirectory\b.*\bflags=[^\n]*\(([^)\n]*)\)", details, re.M)
flags = {flag.strip() for flag in cd_match.group(1).split(",")} if cd_match else set()
if "runtime" not in flags:
    sys.stderr.write("error: hardened runtime flag (--options runtime) is missing.\n")
    raise SystemExit(1)

if not ent_xml.strip():
    sys.stderr.write("error: signed bundle is missing embedded entitlements.\n")
    raise SystemExit(1)

try:
    actual_ent = plistlib.loads(ent_xml.encode("utf-8"))
    with open(expected_ent_path, "rb") as fh:
        expected_ent = plistlib.load(fh)
except Exception as exc:
    sys.stderr.write(f"error: failed to inspect bundle entitlements: {exc}\n")
    raise SystemExit(1)

for key, val in expected_ent.items():
    if actual_ent.get(key) != val:
        sys.stderr.write(f"error: entitlement mismatch for {key}: expected {val!r}, got {actual_ent.get(key)!r}\n")
        raise SystemExit(1)
PY
}

DARWIN_TEMP="${KOE_RELEASE_TEMP_DIR:-$(/usr/bin/getconf DARWIN_USER_TEMP_DIR 2>/dev/null || echo "${TMPDIR:-/tmp}")}"
mkdir -p "$DARWIN_TEMP"
STAGING="$(mktemp -d "${DARWIN_TEMP%/}/koe-release.XXXXXX")"
cleanup_stage() {
  local status=$?
  trap - EXIT
  set +e
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

staged_app="$STAGING/${APP_NAME}.app"
if [[ -n "$APP_INPUT" ]]; then
  "$DITTO_BIN" "$APP_INPUT" "$staged_app"
else
  install_args=(--skip-self-check)
  if [[ "$SKIP_BUILD" -eq 1 ]]; then
    install_args+=(--skip-build)
  fi
  if [[ -n "$IDENTITY" ]]; then
    install_args+=(--identity "$IDENTITY")
  fi
  MACOS_INSTALL_PATH="$staged_app" "$INSTALL_SCRIPT" "${install_args[@]}"
fi

[[ -d "$staged_app" ]] || { echo "error: staged app missing at $staged_app" >&2; exit 1; }

pre_requirement="$(designated_requirement "$staged_app")"
IDENTITY="$(resolve_signing_identity "$IDENTITY" "$TEAM_ID")"

while IFS= read -r target; do
  "$CODESIGN_BIN" --force --sign "$IDENTITY" --options runtime --timestamp "$target"
done < <(find "$staged_app/Contents/Frameworks" -mindepth 1 -maxdepth 1 \
           \( -name '*.framework' -o -name '*.dylib' \) 2>/dev/null | sort -r)

"$CODESIGN_BIN" --force --sign "$IDENTITY" --options runtime --timestamp \
  --entitlements "$ENTITLEMENTS" "$staged_app"

"$SIGN_SCRIPT" --verify-only "$staged_app"
verify_codesign_release_metadata "$staged_app"

post_requirement="$(designated_requirement "$staged_app")"
if [[ -z "$post_requirement" ]]; then
  echo "error: signed bundle is missing a designated requirement." >&2
  exit 1
fi
if [[ -n "$pre_requirement" && "$pre_requirement" != "$post_requirement" ]]; then
  echo "error: designated requirement changed during release signing:" >&2
  echo "  before: $pre_requirement" >&2
  echo "  after:  $post_requirement" >&2
  exit 1
fi

"$staged_app/Contents/MacOS/$APP_NAME" --verify-self
"$staged_app/Contents/MacOS/$APP_NAME" --smoke-test

notary_profile="$(resolve_notary_profile | tr -d '\r\n')"
if [[ -z "$notary_profile" ]]; then
  echo "error: resolved notary profile is empty." >&2
  exit 1
fi

notary_args=(submit "$staged_app" --profile "$notary_profile")
if [[ "$DRY_RUN" -eq 1 ]]; then
  notary_args+=(--dry-run)
fi
"$MACOS_NOTARY_BIN" "${notary_args[@]}"

bundle_version="$(python3 - "$staged_app/Contents/Info.plist" <<'PY'
import plistlib
import sys

with open(sys.argv[1], "rb") as fh:
    data = plistlib.load(fh)
print(data.get("CFBundleShortVersionString") or "0.0.0")
PY
)"
arch="$(uname -m)"
mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd -P)"
zip_name="${APP_NAME}-${bundle_version}-macos-${arch}.zip"
zip_path="$OUTPUT_DIR/$zip_name"
rm -f "$zip_path"
"$DITTO_BIN" -c -k --sequesterRsrc --keepParent "$staged_app" "$zip_path"
(cd "$OUTPUT_DIR" && shasum -a 256 "$zip_name" > SHA256SUMS.txt)

echo "Released: $zip_path"
echo "Checksums: $OUTPUT_DIR/SHA256SUMS.txt"
echo "Profile: $notary_profile"
echo "Designated requirement: $post_requirement"
