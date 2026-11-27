---
name: verify-koe
description: "Verify Koe end to end across its Rust CLI and 17-tool MCP stdio surface, macOS native host self-check binary (--verify-self and --smoke-test), BLE/crypto protocol parity vectors, and exhaustive formal state-space models. Reach for this skill before claiming Koe CLI, MCP, host ABI, persistence, BLE protocol, or state-machine changes work."
---

# Verify Koe

Run Koe verification in an isolated disposable workspace with ambient cloud API keys unset. Never touch `~/Library/Containers/com.anker.ankerRecorder` or an already running `/Applications/Koe.app` instance.

## Launch

Koe verification drives short-lived binaries (`target/debug/koe`, `platforms/macos/.build/debug/Koe`, and `cargo test`) rather than a long-lived dev server. Build the binaries once from the repository root, unset ambient cloud keys, and allocate a short disposable workspace path (`< 94` characters so `"$TMP_WS/koe.sock"` stays under the 103-byte Unix `sun_path` kernel limit).

```bash
export MACOSX_DEPLOYMENT_TARGET=14.0
unset DASHSCOPE_API_KEY DEEPSEEK_API_KEY ARK_API_KEY DOUBAO_API_KEY DOUBAO_TTS_API_KEY
export TMP_WS="/tmp/koe-verify-$$"
export EVIDENCE_DIR="${EVIDENCE_DIR:-/tmp/koe-verify-evidence-$$}"
mkdir -p "$TMP_WS" "$EVIDENCE_DIR"

cargo build -p koe-cli
cargo build -p koe-host-api
swift build --package-path platforms/macos
```

Launch is ready when `./target/debug/koe --version` prints the JSON version object and `./platforms/macos/.build/debug/Koe` exists as an executable Mach-O binary on macOS.

## Doctor

Run the read-only preflight helper before driving any feature and whenever a run behaves unexpectedly.

```bash
.agents/skills/verify-koe/scripts/doctor.sh
```

Doctor checks five preconditions without mutating workspace data.

- `./target/debug/koe` exists and returns exit code `0` on `--version`.
- `./platforms/macos/.build/debug/Koe` exists and is executable on Darwin.
- `TMP_WS` is set, shorter than 94 bytes, and outside `~/Library/Containers/com.anker.ankerRecorder`.
- `DASHSCOPE_API_KEY`, `DEEPSEEK_API_KEY`, `ARK_API_KEY`, `DOUBAO_API_KEY`, and `DOUBAO_TTS_API_KEY` are all unset.
- `crates/koe-runtime/tests/formal_models.rs` is present for exhaustive model verification.

## Drive

Read [features/README.md](./features/README.md) first, then follow the matching feature recipe verbatim.

- [CLI and MCP stdio](./features/cli-and-mcp.md) drives `./target/debug/koe --workspace "$TMP_WS"` across `mcp-stdio`, `status`, `doctor`, `search`, `ask`, and transcript edits.
- [macOS host self-check](./features/macos-host-selfcheck.md) drives `./platforms/macos/.build/debug/Koe --verify-self` and `--smoke-test` over the static `libkoe_host_api.a` C ABI v2 bridge.
- [Formal models](./features/formal-models.md) runs exhaustive BFS and Tarjan SCC liveness models, historical PR bug mutants, and real-code trace replays in `crates/koe-runtime/tests/formal_models.rs`.
- [Protocol and parity](./features/protocol-and-parity.md) drives `./target/debug/koe verify-protocol`, `./target/debug/koe --parity`, `./target/debug/koe benchmark`, and `python3 scripts/test_host_contracts.py`.

## Evidence

Save every verification receipt into `"$EVIDENCE_DIR"` outside `"$TMP_WS"` so teardown never deletes proof artifacts.

- Exercise the real user-facing binary path, not internal setters or test-only hooks.
- Capture both the driving action and the resulting state, including stdout, stderr, exit code, and feature ID.
- Confirm every workspace mutation from a second read-only view (`status`, `search`, `doctor`, or a reopened runtime).
- Treat `verify-protocol` as an in-memory vector check (`hardwareVerified: false`, `cloudVerified: false`), never as hardware or cloud acceptance.
- Record skipped hardware or cloud paths explicitly with the unmet precondition instead of substituting a different check.

## Cleanup

Tear down only the disposable workspace created for this run and any child PIDs spawned by this run. Never kill processes by name (`killall` or `pkill`), and never remove `"$EVIDENCE_DIR"`.

```bash
rm -rf "$TMP_WS"
test ! -e "$TMP_WS"
ls -la "$EVIDENCE_DIR"
```

Cleanup succeeds only when `"$TMP_WS"` no longer exists on disk and every captured artifact in `"$EVIDENCE_DIR"` remains intact.

## Helpers

The skill ships one executable read-only helper script.

- `.agents/skills/verify-koe/scripts/doctor.sh` validates binary availability, `TMP_WS` socket-path length and container isolation, unset cloud API keys, and formal-model target presence. Invoke it directly as `.agents/skills/verify-koe/scripts/doctor.sh` after exporting `TMP_WS`.
