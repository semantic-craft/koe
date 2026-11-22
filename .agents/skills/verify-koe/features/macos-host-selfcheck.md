# macOS host self-check

macOS host self-check exercises the compiled SwiftUI macOS executable linked against `libkoe_host_api.a` to prove C ABI v2 snapshot projection, note editing, speaker merging, scoped source navigation, archive/trash/purge retention, and reopen persistence.

## Sub-features

- `host-verify-self` runs the full in-process Swift-to-Rust C ABI v2 workflow check and exits `0` on `koe-verify-self: PASS`.
- `host-smoke-test` creates a note, accepts a memory, sets a project, disables BLE auto-connect, shuts down the runtime, reopens from disk, and exits `0` on `koe-smoke-test: PASS`.
- `host-swift-tests` runs the SwiftPM test suites for both `platforms/apple-shared` and `platforms/macos`.

## How to get to it (user POV)

- Run `./platforms/macos/.build/debug/Koe --verify-self` from a terminal on macOS.
- Run `./platforms/macos/.build/debug/Koe --smoke-test` from a terminal on macOS.
- Run `swift test --package-path platforms/apple-shared` and `swift test --package-path platforms/macos` from a terminal on macOS.

## Driving it with Koe macOS binary

Preconditions:

- Running on macOS (`Darwin`) with `MACOSX_DEPLOYMENT_TARGET=14.0`.
- `cargo build -p koe-host-api` and `swift build --package-path platforms/macos` have succeeded.
- `.agents/skills/verify-koe/scripts/doctor.sh` exits `0`.

- **Run native self-check.** Launch the macOS binary in headless self-check mode. Run `./platforms/macos/.build/debug/Koe --verify-self 2>&1 | tee "$EVIDENCE_DIR/macos_verify_self.txt"`. Exit code `0` prints `koe-verify-self: PASS (version=2, records=1, scoped_sources=1)`.
- **Run persistence smoke test.** Launch the macOS binary in persistence smoke-test mode. Run `./platforms/macos/.build/debug/Koe --smoke-test 2>&1 | tee "$EVIDENCE_DIR/macos_smoke_test.txt"`. Exit code `0` prints `koe-smoke-test: PASS (version=2, persisted_record=1, accepted_memory=1)`.
- **Run Apple host unit tests.** Execute the SwiftPM suites. Run `swift test --package-path platforms/apple-shared` and `swift test --package-path platforms/macos`. Both exit `0` with zero failing tests.

## Gotchas

- `platforms/macos/Package.swift` statically links `target/debug/libkoe_host_api.a` in debug builds and `target/release/libkoe_host_api.a` in release builds. Always rebuild `koe-host-api` before rebuilding `platforms/macos` after Rust changes.
- Both `--verify-self` and `--smoke-test` allocate and remove their own temporary workspace directories under `FileManager.default.temporaryDirectory`, so they do not read `TMP_WS` or touch production App Sandbox data.
- Never launch `/Applications/Koe.app` during automated verification when checking a worktree build. Drive `./platforms/macos/.build/debug/Koe` directly from the worktree.
