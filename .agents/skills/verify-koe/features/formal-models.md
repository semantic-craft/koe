# Formal models

Formal models exhaustively explore Koe's five critical state machines via pure-Rust BFS safety checking and iterative Tarjan SCC liveness checking, prove every named historical PR bug mutant fails with a minimal counterexample trace, and replay concrete sequences against real runtime structs.

## Sub-features

- `fm-checker` self-tests shortest-path BFS counterexample reconstruction, `max_states` blowup rejection, and Tarjan SCC trap-cycle detection.
- `fm-credentials` verifies credential prepare-register-create-commit, orphan reclamation, tombstone non-resurrection, slot isolation, partial cleanup commit, and `ProductStore.requires_reopen()` latch.
- `fm-ble-session` verifies explicit disconnect orphan fencing, stop-confirm and quiet-drain independence, connection-scoped decryption context, durable quit veto, and fair `all_day` recovery.
- `fm-dual-capture` verifies capture epoch isolation on terminal callbacks, pause fence completeness, partial-lane survival, interruption preservation on retry, and commit-before-release `.capture` recovery.
- `fm-cloud-analysis` verifies commit-before-consume idempotency, revision and prefix fencing, crash non-retry, trash mutual exclusion, and stale summary reclamation liveness.
- `fm-catalog-custody` verifies disk custody before `0x1A/0x10` hardware delete, multi-page catalog pre-start isolation, stream queue identity isolation, zero-size head realtime preservation, and non-empty subscribe TX behavior.

## How to get to it (user POV)

- Run `cargo test -p koe-runtime --test formal_models` from a terminal at the repository root.
- Run `cargo test -p koe-runtime --test formal_models -- --nocapture --test-threads=1` to inspect state counts and mutant counterexample traces.
- Run `cargo test -p koe-runtime --no-default-features --test formal_models` to verify mobile/no-offline-speech feature compatibility.

## Driving it with cargo test

Preconditions:

- `.agents/skills/verify-koe/scripts/doctor.sh` exits `0`.
- Ambient cloud API keys are unset.

- **Run full formal model suite with traces.** Execute all 39 tests with deterministic output. Run `cargo test -p koe-runtime --test formal_models -- --nocapture --test-threads=1 2>&1 | tee "$EVIDENCE_DIR/formal_models.txt"`. Exit code `0` reports `39 passed; 0 failed` in under 2 seconds, printing `[MODEL]` state/SCC counts for all 5 models and `[MUTANT]` counterexample traces for all 25 historical PR and invariant mutants.
- **Verify no-default-features compatibility.** Run the same target without `offline-speech`. Run `cargo test -p koe-runtime --no-default-features --test formal_models 2>&1 | tee "$EVIDENCE_DIR/formal_models_no_default.txt"`. Exit code `0` reports `39 passed; 0 failed`.
- **Verify Clippy gate on formal models.** Check workspace lint compliance. Run `cargo clippy -p koe-runtime --all-targets -- -D warnings`. Exit code `0` with zero warnings.

## Gotchas

- `explore_bfs` and `check_liveness` intentionally fail on `StateSpaceExceeded` rather than truncating exploration. Keep bounded budgets finite when extending models so runtime stays under 2 seconds in dev mode.
- The real-code `ProductStore.requires_reopen()` replay temporarily sets mode `0o300` on its own sandbox directory under `std::env::temp_dir()` and restores `0o700` on drop. Running tests as `root` bypasses POSIX directory read permission checks and is not supported for that assertion.
- Always run `--no-default-features` after modifying `crates/koe-runtime/tests/formal_models*`, because `scripts/verify-local.sh` gates both feature profiles in CI.
