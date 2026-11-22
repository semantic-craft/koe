# Koe verification map

This directory is the maintained source for verifying user-facing and protocol-critical behavior of Koe. Read this index before running any check, then follow the matching feature file as the literal recipe.

## Baseline preconditions

- Run from the repository root with `MACOSX_DEPLOYMENT_TARGET=14.0` on macOS.
- Unset `DASHSCOPE_API_KEY`, `DEEPSEEK_API_KEY`, `ARK_API_KEY`, `DOUBAO_API_KEY`, and `DOUBAO_TTS_API_KEY`.
- Set `TMP_WS="/tmp/koe-verify-$$"` with path length under 94 bytes so `"$TMP_WS/koe.sock"` remains under the 103-byte Unix `sun_path` kernel limit.
- Set `EVIDENCE_DIR` outside `TMP_WS` so workspace teardown leaves proof artifacts intact.
- Build `./target/debug/koe` and `./platforms/macos/.build/debug/Koe` before running feature recipes.
- Run `.agents/skills/verify-koe/scripts/doctor.sh` and require exit code `0`.
- Never pass or omit `--workspace` in a way that opens `~/Library/Containers/com.anker.ankerRecorder/Data/Library/Application Support/KoeWorkspace`.

## Driving conventions

- Start every recipe from the baseline state unless its preconditions specify otherwise.
- Treat every command, flag, JSON-RPC field, and expected output pattern as literal.
- Pass `--workspace "$TMP_WS"` to every stateful `./target/debug/koe` invocation.
- Capture command stdout, stderr, and exit codes into `"$EVIDENCE_DIR"`.
- Remove `"$TMP_WS"` during cleanup and retain `"$EVIDENCE_DIR"`.

## Proof and skip reporting

- Capture both the triggering action and the resulting observable state.
- CLI and MCP proof includes the literal command, stdout JSON, stderr, and exit code.
- Mutation proof requires a second read-only view (`status`, `search`, `doctor`, or a reopened runtime).
- Record the feature ID and entry point alongside every artifact.
- Report unreachable hardware or cloud paths with the attempted command and the unmet precondition.
- Never report a skipped hardware or cloud entry point as verified through an in-memory vector check.

## Feature entry contract

Each feature file starts with an H1 title and one paragraph describing the user-visible behavior. It then uses exactly four H2 sections in this order.

1. `Sub-features` lists short IDs with one line for each behavior.
2. `How to get to it (user POV)` lists every user entry point.
3. `Driving it with <harness>` starts with `Preconditions:` and uses labeled bullets pairing each action with an exact command and observable result.
4. `Gotchas` lists traps that can waste or invalidate a verification run.

Keep internal implementation details out of the map. Name only user paths, stable commands, required state, and observable proof.

## Features

- [CLI and MCP stdio](./cli-and-mcp.md) covers isolated workspace note creation via `mcp-stdio`, readback via `status`, `doctor`, `search`, `ask`, and transcript editing.
- [macOS host self-check](./macos-host-selfcheck.md) covers the native `Koe` binary `--verify-self` and `--smoke-test` end-to-end C ABI v2 checks.
- [Formal models](./formal-models.md) covers exhaustive BFS safety verification, Tarjan SCC liveness verification, historical PR bug mutants, and real-code replays.
- [Protocol and parity](./protocol-and-parity.md) covers in-memory BLE/crypto/Opus protocol vectors, deterministic parity vectors, SoA benchmark, and Rust/Swift/Kotlin host contract checks.
