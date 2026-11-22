#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
ANDROID_DIR="$ROOT/platforms/android"
GRADLE_DIR="$ANDROID_DIR/gradle-app"
APP_PACKAGE="com.semanticcraft.koe"
APP_ACTIVITY="com.semanticcraft.koe/.MainActivity"
DEFAULT_APK="$GRADLE_DIR/app/build/outputs/apk/github/debug/app-github-debug.apk"
LIVE_FLOW="$ANDROID_DIR/tests/maestro/smoke-android-live.yaml"
FIXTURE_FLOW="$ANDROID_DIR/tests/maestro/smoke-android-fixture.yaml"
FAIL_PROBE_FLOW="$ANDROID_DIR/tests/maestro/fail-probe-android.yaml"
RICH_FIXTURE="$ANDROID_DIR/tests/fixtures/android-rich-snapshot.json"
TEST_AVD_REGEX='^koe-test-api[0-9]+$'

AVD_NAME="koe-test-api35"
PORT="5580"
REUSE_SERIAL=""
SKIP_NATIVE=0
SKIP_GRADLE=0
KEEP_ARTIFACTS=0
WITH_FAIL_PROBE=0
ARTIFACTS_DIR=""
APK_PATH="${KOE_ANDROID_APK:-$DEFAULT_APK}"

usage() {
  cat <<'USAGE'
Usage: platforms/android/smoke.sh [options]

Builds native Android libraries and Gradle APK, then runs live, fixture, and
optional expected-failure Maestro flows on headless koe-test-api<N>.

Options:
  --avd <name>              Dedicated test AVD matching ^koe-test-api[0-9]+$ (default: koe-test-api35)
  --port <even-int>         Emulator console port (default: 5580)
  --reuse-serial <serial>   Attach to a running koe-test-api<N> emulator serial
  --apk <path.apk>          Override APK path (default: app-github-debug.apk)
  --skip-native             Skip platforms/android/build-native.sh arm64-v8a
  --skip-gradle             Skip Gradle unit tests, release lint, and debug APK build
  --keep-artifacts          Keep 4-artifact forensics bundles for passing runs
  --with-fail-probe         Also run fail-probe-android.yaml with --expect-failure
  --artifacts-dir <dir>     Output root (default: target/verify-artifacts/android-smoke-<run-id>)
  -h, --help                Show this help
USAGE
}

die() {
  printf 'android smoke error: %s\n' "$*" >&2
  exit 1
}

die_usage() {
  printf 'android smoke error: %s\n' "$*" >&2
  usage >&2
  exit 2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --avd)
      [[ $# -ge 2 ]] || die_usage "--avd requires a value"
      AVD_NAME="$2"
      shift
      ;;
    --port)
      [[ $# -ge 2 ]] || die_usage "--port requires a value"
      PORT="$2"
      shift
      ;;
    --reuse-serial)
      [[ $# -ge 2 ]] || die_usage "--reuse-serial requires a value"
      REUSE_SERIAL="$2"
      shift
      ;;
    --apk)
      [[ $# -ge 2 ]] || die_usage "--apk requires a value"
      APK_PATH="$2"
      shift
      ;;
    --skip-native)
      SKIP_NATIVE=1
      ;;
    --skip-gradle)
      SKIP_GRADLE=1
      ;;
    --keep-artifacts)
      KEEP_ARTIFACTS=1
      ;;
    --with-fail-probe)
      WITH_FAIL_PROBE=1
      ;;
    --artifacts-dir)
      [[ $# -ge 2 ]] || die_usage "--artifacts-dir requires a value"
      ARTIFACTS_DIR="$2"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die_usage "unknown option: $1"
      ;;
  esac
  shift
done

[[ "$AVD_NAME" =~ $TEST_AVD_REGEX ]] || die "refusing non-test AVD '$AVD_NAME'; AVD must match $TEST_AVD_REGEX"
[[ "$PORT" =~ ^[0-9]+$ ]] && (( PORT >= 5554 && PORT <= 65534 && PORT % 2 == 0 )) || die "--port must be an even integer in [5554, 65534]: $PORT"

# shellcheck source=scripts/lib/java-env.sh
source "$ROOT/scripts/lib/java-env.sh"

if [[ "$SKIP_NATIVE" -eq 0 ]]; then
  "$ANDROID_DIR/build-native.sh" arm64-v8a
fi

if [[ "$SKIP_GRADLE" -eq 0 ]]; then
  JAVA_HOME="$(resolve_java_home)" \
    || die "working JDK 17+ not found; install openjdk@17 or set JAVA_HOME"
  export JAVA_HOME
  export ANDROID_SDK_ROOT="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-$HOME/Library/Android/sdk}}"
  export ANDROID_HOME="$ANDROID_SDK_ROOT"
  "$GRADLE_DIR/gradlew" -p "$GRADLE_DIR" \
    testGithubDebugUnitTest \
    lintGithubRelease \
    lintPlayRelease \
    assembleGithubDebug \
    --no-daemon
fi

[[ -f "$APK_PATH" ]] || die "APK not found: $APK_PATH"
[[ -f "$LIVE_FLOW" ]] || die "missing live smoke flow: $LIVE_FLOW"
[[ -f "$FIXTURE_FLOW" ]] || die "missing fixture smoke flow: $FIXTURE_FLOW"
[[ -f "$RICH_FIXTURE" ]] || die "missing canonical fixture: $RICH_FIXTURE"
if [[ "$WITH_FAIL_PROBE" -eq 1 ]]; then
  [[ -f "$FAIL_PROBE_FLOW" ]] || die "missing fail-probe flow: $FAIL_PROBE_FLOW"
fi

VERIFY_BIN="${KOE_VERIFY_EMULATOR_BIN:-$ANDROID_DIR/verify-emulator.sh}"
[[ -x "$VERIFY_BIN" ]] || die "verify-emulator.sh is not executable: $VERIFY_BIN"

RUN_ID="$(date -u '+%Y%m%dT%H%M%SZ')-$$"
if [[ -z "$ARTIFACTS_DIR" ]]; then
  ARTIFACTS_DIR="$ROOT/target/verify-artifacts/android-smoke-$RUN_ID"
else
  ARTIFACTS_DIR="$(python3 -c 'import os, sys; print(os.path.abspath(sys.argv[1]))' "$ARTIFACTS_DIR")"
fi

common_args=()
if [[ -n "$REUSE_SERIAL" ]]; then
  common_args+=(--reuse-serial "$REUSE_SERIAL")
else
  common_args+=(--avd "$AVD_NAME" --port "$PORT")
fi
common_args+=(
  --apk "$APK_PATH"
  --app-package "$APP_PACKAGE"
  --app-activity "$APP_ACTIVITY"
  --launch-app
)

keep_args=()
if [[ "$KEEP_ARTIFACTS" -eq 1 ]]; then
  keep_args+=(--keep-artifacts)
fi

"$VERIFY_BIN" "${common_args[@]}" "${keep_args[@]}" \
  --grant-permission android.permission.RECORD_AUDIO \
  --grant-permission android.permission.POST_NOTIFICATIONS \
  --flow "$LIVE_FLOW" \
  --artifacts-dir "$ARTIFACTS_DIR/live"

"$VERIFY_BIN" "${common_args[@]}" "${keep_args[@]}" \
  --fixture "$RICH_FIXTURE" \
  --flow "$FIXTURE_FLOW" \
  --artifacts-dir "$ARTIFACTS_DIR/fixture"

if [[ "$WITH_FAIL_PROBE" -eq 1 ]]; then
  "$VERIFY_BIN" "${common_args[@]}" \
    --flow "$FAIL_PROBE_FLOW" \
    --expect-failure \
    --artifacts-dir "$ARTIFACTS_DIR/fail-probe"
fi

if [[ "$KEEP_ARTIFACTS" -eq 1 || "$WITH_FAIL_PROBE" -eq 1 ]]; then
  printf 'android smoke: PASS (avd=%s, artifacts=%s)\n' "$AVD_NAME" "$ARTIFACTS_DIR"
else
  printf 'android smoke: PASS (avd=%s)\n' "$AVD_NAME"
fi
