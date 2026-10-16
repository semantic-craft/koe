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
# Before archiving, and again right before deleting, the script reads the
# target's Contents/Info.plist and requires all of: CFBundleIdentifier
# com.anker.ankerRecorder, CFBundleExecutable "Soundcore Manager", a
# CFBundleName / CFBundleDisplayName that is not Koe, a resolved path that is
# not a Koe.app install path, and a version older than the current Koe build or
# listed in LEGACY_VERSIONS. Koe.app shares the Bundle ID, so the identifier
# alone cannot tell the two apart. Any mismatch prints the reason, exits
# non-zero, and leaves the bundle registered and in place.
#
# Restore: ditto -x -k "<archive>.zip" /Applications
set -euo pipefail

LEGACY="${MACOS_LEGACY_INSTALL_PATH:-/Applications/Soundcore Manager.app}"
INSTALL_TARGET="${MACOS_INSTALL_PATH:-/Applications/Koe.app}"
LEGACY_BINARY_NAME="Soundcore Manager"
LEGACY_BUNDLE_ID="com.anker.ankerRecorder"
KOE_DEFAULT_INSTALL="/Applications/Koe.app"
# Pre-rename Soundcore Manager builds, as CFBundleShortVersionString+CFBundleVersion.
# The app version never moved off 1.0.0+1 before the rename, and early Koe
# builds carried that same number, so it is listed explicitly rather than
# relying only on "older than Koe". The identity checks above it still keep
# Koe.app from matching.
LEGACY_VERSIONS=("1.0.0+1")
SCRIPT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KOE_VERSION="$(sed -n 's/^version:[[:space:]]*\([^[:space:]]*\).*/\1/p' "$SCRIPT_ROOT/pubspec.yaml" 2>/dev/null | head -n 1)"
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

# Prints one Info.plist value, or nothing when the key is absent.
plist_value() {
  local plist="$1" key="$2"
  if [[ -x /usr/libexec/PlistBuddy ]]; then
    /usr/libexec/PlistBuddy -c "Print :${key}" "$plist" 2>/dev/null || true
  else
    defaults read "${plist%.plist}" "$key" 2>/dev/null || true
  fi
}

lowercase() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# Prints -1, 0 or 1 comparing two dotted numbers; missing components are 0.
compare_dotted() {
  local -a as bs
  local i x y
  IFS=. read -r -a as <<<"$1"
  IFS=. read -r -a bs <<<"$2"
  for ((i = 0; i < ${#as[@]} || i < ${#bs[@]}; i++)); do
    x="${as[i]:-0}" y="${bs[i]:-0}"
    if ((10#$x < 10#$y)); then echo -1; return; fi
    if ((10#$x > 10#$y)); then echo 1; return; fi
  done
  echo 0
}

# True when version $1 is strictly lower than $2. Both are name+build
# (CFBundleShortVersionString+CFBundleVersion, pubspec x.y.z+n): names are
# compared first, then builds. Anything non-numeric is never treated as lower.
version_lower() {
  local dotted='^[0-9]+(\.[0-9]+)*\+[0-9]+(\.[0-9]+)*$' names
  [[ "$1" =~ $dotted && "$2" =~ $dotted ]] || return 1
  names="$(compare_dotted "${1%%+*}" "${2%%+*}")"
  [[ "$names" == -1 ]] && return 0
  [[ "$names" == 0 && "$(compare_dotted "${1#*+}" "${2#*+}")" == -1 ]]
}

refuse_identity() {
  echo "error: ${LEGACY} $1; refusing to retire it, left in place." >&2
  exit 1
}

verify_legacy_identity() {
  local plist="${LEGACY}/Contents/Info.plist" id exe name display short build version known=0 v
  if ! command -v /usr/libexec/PlistBuddy >/dev/null 2>&1 && ! command -v defaults >/dev/null 2>&1; then
    refuse_identity "cannot be identified: neither PlistBuddy nor defaults is available"
  fi
  [[ -f "$plist" ]] || refuse_identity "has no Contents/Info.plist, so it cannot be confirmed as the old ${LEGACY_BINARY_NAME}"
  id="$(plist_value "$plist" CFBundleIdentifier)"
  [[ "$id" == "$LEGACY_BUNDLE_ID" ]] \
    || refuse_identity "has CFBundleIdentifier '${id}', expected ${LEGACY_BUNDLE_ID}"
  exe="$(plist_value "$plist" CFBundleExecutable)"
  [[ "$exe" == "$LEGACY_BINARY_NAME" ]] \
    || refuse_identity "has CFBundleExecutable '${exe}', expected '${LEGACY_BINARY_NAME}'"
  name="$(plist_value "$plist" CFBundleName)"
  display="$(plist_value "$plist" CFBundleDisplayName)"
  if [[ "$(lowercase "$name")" == koe || "$(lowercase "$display")" == koe ]]; then
    refuse_identity "is named Koe (CFBundleName '${name}', CFBundleDisplayName '${display}')"
  fi
  local here
  here="$(canonical_path "$LEGACY")" || refuse_identity "path cannot be resolved"
  for v in "$INSTALL_TARGET" "$KOE_DEFAULT_INSTALL"; do
    if [[ "$here" == "$(canonical_path "$v")" ]]; then
      refuse_identity "resolves to the Koe install path ${v}"
    fi
  done
  short="$(plist_value "$plist" CFBundleShortVersionString)"
  build="$(plist_value "$plist" CFBundleVersion)"
  [[ -n "$short" && -n "$build" ]] \
    || refuse_identity "has no CFBundleShortVersionString/CFBundleVersion"
  version="${short}+${build}"
  for v in "${LEGACY_VERSIONS[@]}"; do
    if [[ "$version" == "$v" ]]; then known=1; fi
  done
  if [[ "$known" -eq 0 ]] && ! { [[ -n "$KOE_VERSION" ]] && version_lower "$version" "$KOE_VERSION"; }; then
    refuse_identity "has version ${version}, which is neither older than the Koe build (${KOE_VERSION:-unknown}) nor a listed legacy version (${LEGACY_VERSIONS[*]})"
  fi
}

verify_legacy_identity

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
verify_legacy_identity
if [[ -x "$LSREGISTER" ]]; then
  "$LSREGISTER" -u "$LEGACY" >/dev/null 2>&1 || true
fi
rm -rf "$LEGACY"
echo "Retired ${LEGACY}; archive: ${ARCHIVE}"
echo "Restore with: ditto -x -k \"${ARCHIVE}\" \"$(dirname "$LEGACY")\""
