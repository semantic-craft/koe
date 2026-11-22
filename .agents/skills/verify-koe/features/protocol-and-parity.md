# Protocol and parity

Protocol and parity verification validates Koe's pure-Rust D3200 BLE framing, P-256 ECDH key exchange, AES-256-CTR stream decryption, Ogg Opus and WAV containers, WebSocket framing, libopus decoding, and cross-platform Rust/Swift/Kotlin host command contracts.

## Sub-features

- `proto-verify` executes in-memory cryptographic, BLE framing, WebSocket mask, and 16 kHz libopus checks via `koe verify-protocol`.
- `proto-parity` emits 20 deterministic SplitMix64 parity vectors across seeds `0..19` via `koe --parity`.
- `proto-benchmark` exercises the SoA fast-path decryption and Ogg Opus muxing pipeline via `koe benchmark`.
- `host-contract-parity` verifies wire command tags, required fields, and snapshot DTO alignment across Rust, Swift, and Kotlin via `scripts/test_host_contracts.py`.

## How to get to it (user POV)

- Run `./target/debug/koe verify-protocol` from a terminal.
- Run `./target/debug/koe --parity` from a terminal.
- Run `./target/debug/koe benchmark` from a terminal.
- Run `python3 scripts/test_host_contracts.py` from a terminal.

## Driving it with koe CLI and Python contract suite

Preconditions:

- `./target/debug/koe` is built and `.agents/skills/verify-koe/scripts/doctor.sh` exits `0`.
- Python 3 is installed and available as `python3`.

- **Run in-memory protocol verification.** Execute the built-in vector suite. Run `./target/debug/koe verify-protocol | tee "$EVIDENCE_DIR/verify_protocol.json"`. Exit code `0` prints JSON with `"status":"ok"` and all five checks (`p256_ecdh`, `aes_known_answer`, `ble_frames_20_seeds`, `websocket_mask`, `libopus_16khz`).
- **Generate deterministic parity vectors.** Run the 20-seed parity generator. Run `./target/debug/koe --parity | tee "$EVIDENCE_DIR/parity_vectors.json"`. Exit code `0` prints a 20-element JSON array covering seeds `0` through `19` with `rx_count` equal to `2` on every entry.
- **Run cross-host command and DTO contract checks.** Execute the automated Rust/Swift/Kotlin verifier. Run `python3 scripts/test_host_contracts.py 2>&1 | tee "$EVIDENCE_DIR/host_contracts.txt"`. Exit code `0` prints `OK` with zero contract mismatches.
- **Run protocol benchmark.** Exercise the 90,000-frame decryption and muxing path. Run `./target/debug/koe benchmark --safe | tee "$EVIDENCE_DIR/benchmark.json"`. Exit code `0` prints JSON containing `"decoded_packets":10000` and `"decrypted_bytes":14400000`.

## Gotchas

- `koe verify-protocol` explicitly reports `"hardwareVerified":false` and `"cloudVerified":false`. Do not cite it as physical D3200 BLE hardware or live cloud provider proof.
- `verify-protocol`, `--parity`, and `benchmark` do not open a workspace, so passing `--workspace` is unnecessary for them, whereas `status`, `doctor`, `search`, `ask`, and `mcp-stdio` require `--workspace "$TMP_WS"`.
- `koe benchmark` takes longer in debug builds than release builds. Use release builds (`cargo run --release -p koe-cli -- benchmark`) when collecting performance numbers.
