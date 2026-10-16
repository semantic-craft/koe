#!/usr/bin/env bash
# Retire the pre-rename "Soundcore Manager.app" after Koe.app is installed.
#
# Both bundles share the Bundle ID com.anker.ankerRecorder and the soundcore://
# URL scheme, so leaving the old copy in place lets Launch Services, Spotlight or
# a URL open the old build. The old bundle is first archived to a zip (not a
# launchable .app, so it cannot be picked by Launch Services), the archive is
# checked, and only then the bundle is removed and unregistered. App data lives
# in the sandbox container keyed by the Bundle ID and is not touched.
#
# Restore: ditto -x -k "<archive>.zip" /Applications
set -euo pipefail

LEGACY="${MACOS_LEGACY_INSTALL_PATH:-/Applications/Soundcore Manager.app}"
LEGACY_BINARY_NAME="Soundcore Manager"
BACKUP_DIR="${MACOS_LEGACY_BACKUP_DIR:-$HOME/Library/Application Support/Koe Install Backups}"
LSREGISTER='/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister'
CHECK_ONLY=0

usage() {
  cat <<'EOF'
Usage: scripts/retire-legacy-macos-app.sh [--check-running]

  Archive the old "Soundcore Manager.app" to a zip, verify the archive, then
  remove and unregister the bundle so only Koe.app can be launched.

  --check-running  Only fail (exit 1) if the old app is running; change nothing.

Environment:
  MACOS_LEGACY_INSTALL_PATH  Old bundle (default /Applications/Soundcore Manager.app)
  MACOS_LEGACY_BACKUP_DIR    Archive directory
                             (default ~/Library/Application Support/Koe Install Backups)
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --check-running) CHECK_ONLY=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
  esac
  shift
done

if pgrep -f "^${LEGACY}/Contents/MacOS/${LEGACY_BINARY_NAME}$" >/dev/null; then
  echo "Quit the old ${LEGACY_BINARY_NAME} (${LEGACY}) before installing Koe." >&2
  exit 1
fi
[[ "$CHECK_ONLY" -eq 1 ]] && exit 0

if [[ ! -e "$LEGACY" ]]; then
  echo "No legacy app at ${LEGACY}; nothing to retire."
  exit 0
fi

mkdir -p "$BACKUP_DIR"
ARCHIVE="${BACKUP_DIR}/$(basename "$LEGACY" .app)-$(date +%Y%m%d-%H%M%S).zip"
ditto -c -k --sequesterRsrc --keepParent "$LEGACY" "$ARCHIVE"

# Prove the archive restores to a complete bundle before deleting anything.
PROBE="$(mktemp -d "${TMPDIR:-/tmp}/koe-legacy-probe.XXXXXX")"
trap 'rm -rf "$PROBE"' EXIT
ditto -x -k "$ARCHIVE" "$PROBE"
RESTORED="${PROBE}/$(basename "$LEGACY")"
if [[ ! -f "${RESTORED}/Contents/Info.plist" ]] \
  || [[ "$(cd "$LEGACY" && find . | LC_ALL=C sort | shasum -a 256)" != "$(cd "$RESTORED" && find . | LC_ALL=C sort | shasum -a 256)" ]]; then
  echo "error: archive ${ARCHIVE} does not restore the full bundle; ${LEGACY} left in place." >&2
  exit 1
fi

if [[ -x "$LSREGISTER" ]]; then
  "$LSREGISTER" -u "$LEGACY" >/dev/null 2>&1 || true
fi
rm -rf "$LEGACY"
echo "Retired ${LEGACY}; archive: ${ARCHIVE}"
echo "Restore with: ditto -x -k \"${ARCHIVE}\" \"$(dirname "$LEGACY")\""
