#!/usr/bin/env bash

designated_requirement() {
  local codesign_bin="${CODESIGN_BIN:-${KOE_CODESIGN_BIN:-codesign}}"
  { "$codesign_bin" -d -r- "$1" 2>&1 || true; } | sed -n 's/^designated => //p'
}

resolve_signing_identity() {
  local identity="${1:-}"
  if [[ -n "$identity" ]]; then
    printf '%s\n' "$identity"
    return 0
  fi
  local team_id="${2:-${TEAM_ID:-LQAVR62TK2}}"
  local security_bin="${SECURITY_BIN:-${KOE_SECURITY_BIN:-security}}"
  local identities=()
  local value
  while IFS= read -r value; do
    [[ -z "$value" ]] || identities+=("$value")
  done < <("$security_bin" find-identity -v -p codesigning \
    | sed -nE 's/.*"(Developer ID Application:[^"]*)".*/\1/p' \
    | awk -v team="($team_id)" 'index($0,team)')
  if [[ ${#identities[@]} -ne 1 ]]; then
    echo 'error: a unique Developer ID Application certificate is required; pass --identity. No ad-hoc fallback.' >&2
    return 1
  fi
  printf '%s\n' "${identities[0]}"
}
