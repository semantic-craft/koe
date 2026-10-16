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
# The script refuses to run when the old bundle and the Koe install target
# overlap: the same path after trailing slashes and symlinks, the same file, or
# one inside the other. Deleting the old bundle then can never delete or damage
# the bundle that is being installed. The archive is
# accepted only when every restored file has the same SHA-256 content, symlink
# target and type as the original, and, when the original carries a valid code
# signature, the restored copy passes codesign --verify --deep --strict too.
#
# Restore: ditto -x -k "<archive>.zip" /Applications
set -euo pipefail

LEGACY="${MACOS_LEGACY_INSTALL_PATH:-/Applications/Soundcore Manager.app}"
INSTALL_TARGET="${MACOS_INSTALL_PATH:-/Applications/Koe.app}"
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
  MACOS_INSTALL_PATH         Koe install target (default /Applications/Koe.app);
                             the script refuses to run if it is, contains or
                             lies inside the old bundle
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

# Absolute path with trailing slashes removed and symlinks resolved, also for
# paths that do not exist yet (the install target before the first install):
# the nearest existing ancestor is resolved and the rest appended.
canonical_path() {
  local p="$1" hops=0 target dir rest=""
  [[ "$p" == /* ]] || p="$PWD/$p"
  while [[ "$p" == */ && "$p" != / ]]; do p="${p%/}"; done
  while [[ -L "$p" ]]; do
    hops=$((hops + 1))
    if [[ "$hops" -gt 40 ]]; then
      echo "error: too many symlinks resolving $1" >&2
      return 1
    fi
    target="$(readlink "$p")"
    [[ "$target" == /* ]] || target="$(dirname "$p")/$target"
    p="$target"
    while [[ "$p" == */ && "$p" != / ]]; do p="${p%/}"; done
  done
  dir="$(dirname "$p")"
  rest="$(basename "$p")"
  while [[ ! -d "$dir" && "$dir" != / ]]; do
    rest="$(basename "$dir")/$rest"
    dir="$(dirname "$dir")"
  done
  dir="$(cd "$dir" && pwd -P)"
  printf '%s/%s\n' "${dir%/}" "$rest"
}

# True when $1 is $2 or lies inside it: by resolved path, or because $1 or one
# of its existing ancestors is the same file as $2 (which also catches a
# differently cased path on a case-insensitive volume).
path_within() {
  local p c
  p="$(canonical_path "$1")" || return 0
  c="$(canonical_path "$2")" || return 0
  [[ "$p" == "$c" || "$p" == "$c"/* ]] && return 0
  [[ -e "$2" ]] || return 1
  while :; do
    [[ -e "$p" && "$p" -ef "$2" ]] && return 0
    [[ "$p" == / ]] && return 1
    p="$(dirname "$p")"
  done
}

refuse_if_overlapping() {
  if path_within "$INSTALL_TARGET" "$LEGACY" || path_within "$LEGACY" "$INSTALL_TARGET"; then
    echo "error: legacy bundle ${LEGACY} overlaps the Koe install target ${INSTALL_TARGET} (same path, or one inside the other); refusing to retire it." >&2
    exit 1
  fi
}

refuse_if_overlapping

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

# One line per entry: type, path and, for files, the SHA-256 of the content and,
# for symlinks, the link target. A file list alone misses changed content.
bundle_manifest() {
  (
    cd "$1"
    find . -print0 | LC_ALL=C sort -z | while IFS= read -r -d '' entry; do
      if [[ -L "$entry" ]]; then
        printf 'L %s -> %s\n' "$entry" "$(readlink "$entry")"
      elif [[ -f "$entry" ]]; then
        printf 'F %s %s\n' "$(shasum -a 256 <"$entry" | cut -d' ' -f1)" "$entry"
      elif [[ -d "$entry" ]]; then
        printf 'D %s\n' "$entry"
      else
        printf 'O %s\n' "$entry"
      fi
    done
  )
}

archive_failed() {
  echo "error: archive ${ARCHIVE} $1; ${LEGACY} left in place." >&2
  exit 1
}

# Prove the archive restores to an identical bundle before deleting anything.
PROBE="$(mktemp -d "${TMPDIR:-/tmp}/koe-legacy-probe.XXXXXX")"
trap 'rm -rf "$PROBE"' EXIT
ditto -x -k "$ARCHIVE" "$PROBE" || archive_failed "could not be unpacked"
RESTORED="${PROBE}/$(basename "$LEGACY")"
[[ -f "${RESTORED}/Contents/Info.plist" ]] \
  || archive_failed "does not restore the full bundle"
LEGACY_MANIFEST="$(bundle_manifest "$LEGACY")" \
  || archive_failed "could not be compared: reading ${LEGACY} failed"
RESTORED_MANIFEST="$(bundle_manifest "$RESTORED")" \
  || archive_failed "could not be compared: reading the restored copy failed"
[[ "$LEGACY_MANIFEST" == "$RESTORED_MANIFEST" ]] \
  || archive_failed "does not restore identical file contents"
if command -v codesign >/dev/null 2>&1 \
  && codesign --verify --deep --strict "$LEGACY" >/dev/null 2>&1 \
  && ! codesign --verify --deep --strict "$RESTORED" >/dev/null 2>&1; then
  archive_failed "restores a bundle that fails codesign --verify --deep --strict"
fi

# The target may have appeared or been replaced while archiving; check again
# right before deleting.
refuse_if_overlapping
if [[ -x "$LSREGISTER" ]]; then
  "$LSREGISTER" -u "$LEGACY" >/dev/null 2>&1 || true
fi
rm -rf "$LEGACY"
echo "Retired ${LEGACY}; archive: ${ARCHIVE}"
echo "Restore with: ditto -x -k \"${ARCHIVE}\" \"$(dirname "$LEGACY")\""
