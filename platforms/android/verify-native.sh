#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: platforms/android/verify-native.sh <llvm-readelf> <library-directory> <abi>

Verifies ELF64 architecture, 16 KB LOAD alignment, NEEDED allowlist,
DT_ANDROID_RELR dynamic tags, and exported C ABI v2 / JNI symbols.
USAGE
}

die() {
  printf 'verify-native error: %s\n' "$*" >&2
  exit 1
}

if [[ $# -ne 3 ]]; then
  usage >&2
  exit 2
fi

READELF="$1"
LIB_DIR="$2"
ABI="$3"

[[ -x "$READELF" ]] || die "readelf binary is not executable: $READELF"
[[ -d "$LIB_DIR" ]] || die "library directory not found: $LIB_DIR"

case "$ABI" in
  arm64-v8a) EXPECTED_MACHINE="AArch64" ;;
  x86_64) EXPECTED_MACHINE="Advanced Micro Devices X86-64" ;;
  *) die "unsupported ABI '$ABI' (expected arm64-v8a or x86_64)" ;;
esac

LIBRARIES=(
  "libkoe_host_api.so"
  "libkoe_android.so"
  "libc++_shared.so"
)

ALLOWED_NEEDED=(
  "libc.so"
  "libm.so"
  "libdl.so"
  "liblog.so"
  "libc++_shared.so"
  "libkoe_host_api.so"
)

REQUIRED_C_SYMBOLS=(
  "koe_host_api_version"
  "koe_host_session_create"
  "koe_host_session_create_with_credentials"
  "koe_host_session_destroy"
  "koe_host_session_generation"
  "koe_host_session_snapshot_json"
  "koe_host_session_dispatch_json"
  "koe_host_session_ingest_ble"
  "koe_host_session_ingest_pcm"
  "koe_host_session_report_playback_progress"
  "koe_host_session_drain_ble_tx"
  "koe_host_session_drain_local_asr"
  "koe_host_session_poll_timers"
  "koe_host_bytes_free"
  "koe_host_string_free"
)

REQUIRED_JNI_SYMBOLS=(
  "JNI_OnLoad"
  "Java_com_semanticcraft_koe_bridge_KoeNativeBridge_nativeApiVersion"
  "Java_com_semanticcraft_koe_bridge_KoeNativeBridge_nativeSessionCreate"
  "Java_com_semanticcraft_koe_bridge_KoeNativeBridge_nativeSessionCreateWithCredentials"
  "Java_com_semanticcraft_koe_bridge_KoeNativeBridge_nativeSessionDestroy"
  "Java_com_semanticcraft_koe_bridge_KoeNativeBridge_nativeSessionGeneration"
  "Java_com_semanticcraft_koe_bridge_KoeNativeBridge_nativeSessionSnapshotJson"
  "Java_com_semanticcraft_koe_bridge_KoeNativeBridge_nativeSessionDispatchJson"
  "Java_com_semanticcraft_koe_bridge_KoeNativeBridge_nativeSessionIngestBle"
  "Java_com_semanticcraft_koe_bridge_KoeNativeBridge_nativeSessionIngestPcm"
  "Java_com_semanticcraft_koe_bridge_KoeNativeBridge_nativeSessionReportPlaybackProgress"
  "Java_com_semanticcraft_koe_bridge_KoeNativeBridge_nativeSessionDrainBleTx"
  "Java_com_semanticcraft_koe_bridge_KoeNativeBridge_nativeSessionDrainLocalAsr"
  "Java_com_semanticcraft_koe_bridge_KoeNativeBridge_nativeSessionPollTimers"
)

is_allowed_needed() {
  local candidate="$1"
  local allowed
  for allowed in "${ALLOWED_NEEDED[@]}"; do
    if [[ "$candidate" == "$allowed" ]]; then
      return 0
    fi
  done
  return 1
}

check_elf_header() {
  local lib="$1"
  local path="$LIB_DIR/$lib"
  local header
  header="$("$READELF" -h "$path")"

  local elf_class
  elf_class="$(awk -F: '/^[[:space:]]*Class:/ { sub(/^[[:space:]]+/, "", $2); print $2; exit }' <<< "$header")"
  [[ "$elf_class" == "ELF64" ]] || die "$lib: expected Class ELF64, got '${elf_class:-<missing>}'"

  local elf_machine
  elf_machine="$(awk -F: '/^[[:space:]]*Machine:/ { sub(/^[[:space:]]+/, "", $2); print $2; exit }' <<< "$header")"
  [[ "$elf_machine" == "$EXPECTED_MACHINE" ]] || die "$lib: expected Machine '$EXPECTED_MACHINE', got '${elf_machine:-<missing>}'"
}

check_load_alignment() {
  local lib="$1"
  local path="$LIB_DIR/$lib"
  local phdrs
  phdrs="$("$READELF" -lW "$path")"

  local count=0
  local align_token
  while IFS= read -r align_token; do
    [[ -n "$align_token" ]] || continue
    count=$((count + 1))
    if [[ ! "$align_token" =~ ^(0[xX][0-9a-fA-F]+|[0-9]+)$ ]]; then
      die "$lib: unparseable LOAD alignment '$align_token'"
    fi
    local align_dec=$((align_token))
    if (( align_dec < 16384 )); then
      die "$lib: LOAD segment alignment $align_token ($align_dec bytes) is below 16384"
    fi
  done < <(awk '$1 == "LOAD" { print $NF }' <<< "$phdrs")

  (( count > 0 )) || die "$lib: no LOAD segments found"
}

check_needed_allowlist() {
  local lib="$1"
  local dynamic_out="$2"
  local dep
  while IFS= read -r dep; do
    [[ -n "$dep" ]] || continue
    if ! is_allowed_needed "$dep"; then
      die "$lib: forbidden NEEDED dependency '$dep'"
    fi
  done < <(
    awk '
      /\(NEEDED\)/ && match($0, /\[[^]]+\]/) {
        print substr($0, RSTART + 1, RLENGTH - 2)
      }
    ' <<< "$dynamic_out"
  )
}

check_android_relr_tags() {
  local lib="$1"
  local dynamic_out="$2"

  if ! grep -Eq '\(ANDROID_RELR\)' <<< "$dynamic_out"; then
    die "$lib: missing required (ANDROID_RELR) dynamic tag"
  fi
  local forbidden_tag
  for forbidden_tag in RELR RELRSZ RELRENT; do
    if grep -Eq "\(${forbidden_tag}\)" <<< "$dynamic_out"; then
      die "$lib: forbidden standard (${forbidden_tag}) tag present (breaks Android < 11 / API 29)"
    fi
  done
}

check_exported_symbols() {
  local lib="$1"
  shift
  local path="$LIB_DIR/$lib"
  local dynsyms
  dynsyms="$("$READELF" --dyn-syms -W "$path")"

  local exported
  exported="$(
    awk '
      NF >= 8 && $1 ~ /^[0-9]+:$/ && $7 != "UND" && ($5 == "GLOBAL" || $5 == "WEAK") && $6 == "DEFAULT" {
        sym = $8
        sub(/@.*/, "", sym)
        print sym
      }
    ' <<< "$dynsyms"
  )"

  local sym
  for sym in "$@"; do
    if ! grep -Fxq "$sym" <<< "$exported"; then
      die "$lib: missing exported symbol '$sym'"
    fi
  done
}

HOST_DYNAMIC=""
for lib in "${LIBRARIES[@]}"; do
  path="$LIB_DIR/$lib"
  [[ -f "$path" ]] || die "required library missing: $path"
  check_elf_header "$lib"
  check_load_alignment "$lib"
  dynamic_out="$("$READELF" -dW "$path")"
  check_needed_allowlist "$lib" "$dynamic_out"
  if [[ "$lib" == "libkoe_host_api.so" ]]; then
    HOST_DYNAMIC="$dynamic_out"
  fi
done

check_android_relr_tags "libkoe_host_api.so" "$HOST_DYNAMIC"
check_exported_symbols "libkoe_host_api.so" "${REQUIRED_C_SYMBOLS[@]}"
check_exported_symbols "libkoe_android.so" "${REQUIRED_JNI_SYMBOLS[@]}"

printf 'verify-native passed: abi=%s dir=%s (%d C ABI + %d JNI symbols, 16 KB aligned, ANDROID_RELR ok)\n' \
  "$ABI" "$LIB_DIR" "${#REQUIRED_C_SYMBOLS[@]}" "${#REQUIRED_JNI_SYMBOLS[@]}"
