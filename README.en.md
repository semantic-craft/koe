<p align="center">
  <img src="assets/artwork/koe-schoolgirl-b-cheerful.png" width="132" alt="Koe">
</p>

<h1 align="center">Koe</h1>

<p align="center">
  <strong>Bring your Anker soundcore Work (D3200) collar recorder and daily Mac meetings home to local disk.</strong><br>
  <sub>把安克 soundcore Work（D3200）录音豆与日常 Mac 会议，完整带回本机磁盘。</sub>
</p>

<p align="center">
  <a href="docs/releases/v2.1.0.md"><img alt="v2.1.0" src="https://img.shields.io/badge/release-v2.1.0-1f6f54?style=flat-square"></a>
  <img alt="Rust 2021" src="https://img.shields.io/badge/Rust-2021-000000?style=flat-square&logo=rust&logoColor=white">
  <img alt="SwiftUI Native" src="https://img.shields.io/badge/SwiftUI-Native-F05138?style=flat-square&logo=swift&logoColor=white">
  <img alt="macOS 14+" src="https://img.shields.io/badge/macOS-14%2B-000000?style=flat-square&logo=apple&logoColor=white">
  <a href="https://github.com/semantic-craft/koe/actions/workflows/ci.yml"><img alt="CI" src="https://img.shields.io/github/actions/workflow/status/semantic-craft/koe/ci.yml?branch=main&style=flat-square&label=CI"></a>
  <a href="assets/licenses/soundcore.txt"><img alt="Upstream license: MIT" src="https://img.shields.io/badge/Upstream_license-MIT-blue?style=flat-square"></a>
</p>

<p align="center"><a href="README.md">简体中文</a> · <strong>English</strong></p>

Anker's **soundcore Work (D3200)** is a coin-sized, hardware-encrypted collar recorder with tactile double-tap gestures, yet out of the box it locks your recordings behind Feishu or vendor cloud accounts. **Koe brings the D3200 and your daily Mac meetings home to local disk.**

A pure-Rust core (`#![forbid(unsafe_code)]` in 6 of 8 crates) owns the BLE protocol, audio custody, citation verification, and single-writer storage, paired with a thin native SwiftUI macOS app. Even **offline with zero cloud API keys**, encrypted BLE sync, local ASR (`SenseVoice Small`, `Qwen3 ASR 0.6B`, or macOS 26 `SpeechAnalyzer`), dual-lane playback, transcript editing, and `<5 ms` BM25 search work right away.

<div align="center">
<table>
  <tr>
    <td align="center" width="25%" valign="top">
      <img src="assets/product/guide_connect_device.webp" width="120" alt="Direct BLE GATT"><br>
      <sub><strong>1. Direct BLE GATT</strong><br>Connects to <code>020cf5da-...</code> with zero classic Bluetooth pairing so headphones stay in stereo A2DP, and zero Anker or Feishu login.</sub>
    </td>
    <td align="center" width="25%" valign="top">
      <img src="assets/product/guide_wear.webp" width="120" alt="Wear and switch"><br>
      <sub><strong>2. Collar wear &amp; instant switch</strong><br>Run all-day collar capture or one-press Quick Note, with one-click source switching on the Today strip.</sub>
    </td>
    <td align="center" width="25%" valign="top">
      <img src="assets/product/guide_mark.webp" width="120" alt="Front double-tap bookmarks"><br>
      <sub><strong>3. Front double-tap bookmarks</strong><br>Logs <code>20 ms</code> precision <code>SliceMark</code> bookmarks during D3200 capture for jump-to-audio playback and export.</sub>
    </td>
    <td align="center" width="25%" valign="top">
      <img src="assets/product/guide_sync.webp" width="120" alt="Verified local custody"><br>
      <sub><strong>4. Custody before delete</strong><br>Requires disk <code>fsync</code> and a 64-hex SHA-256 <code>CustodyReceipt</code> before emitting <code>0x1A/0x10</code> hardware delete.</sub>
    </td>
  </tr>
</table>
</div>

## One day, three workspaces

Koe centers its Today screen on three daily capture workspaces. Starting or stopping a recording session is decoupled from opening a workspace view, and switching sidebar pages never interrupts active audio capture.

| Workspace | Built for | How it runs |
| --- | --- | --- |
| **Quick Note** (default) | Fleeting thoughts, quick handoffs, reading lists | A D3200 button press or shortcut drops spoken notes into the inbox with original timestamps and project tags. AI notes sit beside your transcript without overwriting your words. |
| **All-Day Listening** | Continuous collar wear across the day | Splits capture into 5-minute records automatically without dropping audio while prior segments summarize in the background. Merges wall-clock events, records pauses and unrecorded gaps honestly on a monotonic timeline, and groups end-of-day review. |
| **Live Minutes** | Remote calls, in-person meetings, interviews | Captures **Mac dual-lane system audio and microphone** on a shared timeline via CoreAudio `CATapDescription` so headphone calls record both sides. Generates initial topics after 3 utterances or 20 seconds, refreshes on a 45-second debounce without overlapping jobs, tracks 3 coverage metrics, and extracts action items in one pass after stop. |

All three workspaces share one local library governed by three guarantees:

- **Every bullet links back to spoken audio.** Minutes, tasks, memories, and Q&A answers bind to composite `record_id + segment_id` references for click-to-seek playback. Editing a transcript latches `original_text` for one-click restoration and marks prior minutes stale, while `validate_minutes_grounding` rejects ungrounded numbers, out-of-range segment IDs, or fabricated glossary edits.
- **Sub-5 ms search across 400k characters without an LLM.** A CJK bi-gram and Latin BM25 inverted index searches 16,000 utterances in under `5 ms` in unit benchmarks. When no text model is configured, Ask Koe returns cited `[S1]` and `[S2]` source excerpts offline and refuses ungrounded questions locally instead of guessing.
- **Reversible 30-day Trash, archive lock, and portable `.koepack`, Markdown, and WAV I/O.** Import WAV, UTF-8 TXT, Markdown, or self-contained `.koepack` archives, and export customizable Markdown. Archive lock blocks edits and deletion. Soft-deleted records stay in Trash for 30 days with an 8-second undo bar, and two-phase permanent purge removes `.wav` and `.opus` files from disk only after metadata commits.

## Hardware protocol and native performance

Koe handles encrypted BLE framing, high-rate audio buffers, and macOS permission quirks directly in Rust and thin CoreAudio adapters:

- **Pure-Rust D3200 crypto and `166 * N` slice resume.** Inside `#![forbid(unsafe_code)]`, `koe-engine` runs ephemeral NIST P-256 ECDH (`0x2E/0x01`), RFC 5869 HKDF-SHA256 key derivation, `soundcored3200` file-key checks, and zero-allocation T-table AES-256-CTR stream decryption. Offline pulls align to exact 166-byte slices (4-byte sequence, 1-byte flags, 160-byte `20 ms` Opus frame, 1-byte delimiter) to resume after disconnects at `received_slice_count * 166` under a 5-second watchdog. Source-built static `libopus 1.5.2` decodes `16 kHz` mono PCM16 for ASR alongside `48 kHz` audio for playback while muxing standard RFC 7845 Ogg Opus archives (`10,000` packets decrypted, decoded, and muxed in `75.07 ms` in `koe-cli benchmark`).
- **Scoped `@Observable` slices and `1,314x` offscreen gate (`v2.1.0`).** Passing raw `int16_t` pointers via `koe_host_session_ingest_pcm` removes per-chunk JSON serialization, batching 20-tick dual-lane snapshot projections from `323` down to `23` and cutting `48 kHz` dual-lane capture CPU by `81.15%` (`696.66 ms` to `131.30 ms`). `HostSessionStore` splits state into 21 `Equatable` domain slices guarded by a static 4 Hz leaf-bar lint gate in `scripts/verify-ui-principles.py`, replaces 1 Hz main-thread audio polling with a 50 ms debounced CoreAudio HAL property listener, and gates offscreen `NSHostingView.layout()` passes when windows close or miniaturize (`307.60 ms` to `0.23 ms` closed-window playback wall time across 40 ticks, `1,314.5x` faster).
- **Inaudible `-100 dBFS` Barker-13 system-audio canary.** macOS provides no public callback for CoreAudio output tap consent, and `AudioDeviceStart` returns zeroed buffers silently when denied. During permission checks, Koe injects an inaudible `-100 dBFS` Barker-13 probe into the default output while inspecting visible system auth dialogs, marking access denied only after dialogs close with zero loopback correlation, and retaining the surviving lane if one audio stream fails.
- **Crash-safe `.capture`, `RequestKey` billing guard, and two-phase Keychain.** Live microphone streams write incrementally to `<id>.capture`, updating the 44-byte WAV header at offset 0 and calling `sync_data()` per chunk so startup recovers interrupted recordings via verified `.wav` hard links. Cloud jobs persist `RequestKey(record_id, attempt, input_revision)` before dispatch and move to `Interrupted` across restarts with zero silent cloud re-billing. `meeting_audio_policy` defaults to `LocalOnly`, and signed Keychain writes record two-phase pending UUID references on disk first to reclaim pre-commit crash orphans by exact UUID without touching `.env` or `.envrc`.

> **Hardware channel note.** [PROTOCOL.md](PROTOCOL.md) also documents Wi-Fi SoftAP fast transfer, Classic Bluetooth SPP, firmware OTA, time sync, and device binding commands observed during reverse engineering. Those paths are **intentionally not wired** in Koe today. All device transfers run over BLE GATT, and firmware updates remain in the vendor app.

## CLI and MCP

While Koe is running, it opens an owner-private Unix domain socket inside its container (`.koe` directory mode `0700`, `koe.sock` mode `0600`, verified via `getpeereid` for the same UID). CLI commands and external AI agents attach to the live `KoeRuntime` session over that socket, or fall back to single-writer file locking when the GUI app is closed:

```bash
cargo run --package koe-cli -- status
cargo run --package koe-cli -- search "product decisions"
cargo run --package koe-cli -- ask "what needs follow-up next"
cargo run --package koe-cli -- mcp-stdio
```

- **16 MCP stdio tools.** Serves targeted projections for full-text search, today brief, record list and details, cited Q&A, task and memory review or completion, note creation, segment annotation, transcript editing, speaker rename and merge, archive and Trash recovery, D3200 status and control, and generation polling. **Permanent purge is excluded by design** so agents cannot trigger irreversible deletion.

## Build and install

Requires macOS 14+ (macOS 14.2+ for dual-lane CoreAudio system audio capture; macOS 26+ for Apple `SpeechAnalyzer`), Xcode Command Line Tools (Swift 5.10+), Rust 1.85+, and CMake. Static `libopus 1.5.2` compiles from pinned source with no system `libopus` dependency.

```bash
# Build the Rust C ABI static library and native macOS host
cargo build --package koe-host-api
swift build --package-path platforms/macos

# Package and Developer ID sign /Applications/Koe.app, running --verify-self and --smoke-test
./scripts/install-macos.sh

# Local verification: fast incremental gate vs full workspace suite
./scripts/verify-local.sh --quick
./scripts/check
```

## Four-layer architecture and documentation

Koe enforces a strict four-layer dependency direction across C ABI `KOE_HOST_API_VERSION = 2` with `catch_unwind` FFI isolation. `scripts/verify-ui-principles.py` caps every `.swift` file under `platforms/` and `crates/koe-host-api/src/lib.rs` at 500 lines.

| Layer | Paths | Responsibility |
| --- | --- | --- |
| Layer 1 · Engine | [koe-engine](crates/koe-engine/), [koe-opus](crates/koe-opus/) | I/O-free protocol and domain rules, D3200 crypto and slice alignment, ordered capture events, minutes grounding checks, task and memory review, BM25, and static `libopus` |
| Layer 2 · Client | [koe-client-base](crates/koe-client-base/), [koe-client-providers](crates/koe-client-providers/), [koe-client-services](crates/koe-client-services/) | Symlink-safe atomic writes and file locks, HTTPS and WebSocket providers, local ASR worker threads, single-writer `ProductStore`, and audio custody |
| Layer 3 · Runtime & Host API | [koe-runtime](crates/koe-runtime/), [koe-host-api](crates/koe-host-api/) | Session orchestration, `RequestKey` transactions, binary PCM FFI fast path, immutable `generation` snapshots, and `.koe/koe.sock` local RPC |
| Layer 4 · Native Hosts & CLI | [apple-shared](platforms/apple-shared/), [macos](platforms/macos/), [koe-cli](crates/koe-cli/) | Scoped SwiftUI workspace views, CoreBluetooth, CoreAudio dual-lane tap and HAL monitor, Keychain adapter, and CLI and MCP entrypoints |

Further reading: [Architecture & State Ownership](docs/ARCHITECTURE.md) · [D3200 Protocol Notes](PROTOCOL.md) · [Mode Workspaces](docs/mode-workspaces.md) · [v2.1.0 Release Notes](docs/releases/v2.1.0.md) · [Roadmap](ROADMAP.md) · [Contributing](CONTRIBUTING.md) · [Security Policy](SECURITY.md) · [Third-Party Notices](THIRD_PARTY_NOTICES.md).

## Open-source acknowledgements

Koe combines ideas from open-source voice and wearable projects into an independent Rust and SwiftUI codebase with full upstream attribution:

| Project | Inspiration | Implementation in Koe |
| --- | --- | --- |
| **[msime](https://github.com/metasequoiaime/msime)** | Pure-Rust core + thin native Apple host four-layer split | Exposes versioned C ABI v2 with `catch_unwind`, immutable `generation` snapshots, and an owner-private `koe.sock` RPC socket shared by GUI, CLI, and MCP |
| **[tacshi/Soundcore](https://github.com/tacshi/Soundcore)** | Reverse-engineered D3200 BLE protocol notes and Dart client | Ports the protocol to `#![forbid(unsafe_code)]` Rust state machines with exact `166 * N` byte slice resume, double-tap flag parsing, and telemetry polling |
| **[BasedHardware/omi](https://github.com/BasedHardware/omi)** | Wearable disconnect WAL custody and review confirmation cards | Requires `CustodyReceipt` disk verification before `0x1A/0x10` device deletion, and wires three-state review to 16 MCP tools |
| **[screenpipe](https://github.com/screenpipe/screenpipe)** | Timeline context aggregation and global live caption strip | Drives `LiveCaptionBar` directly from Rust `SpeechSession` snapshots across both D3200 and Mac microphone streams |
| **[TaoSheng](https://github.com/0xCoach/TaoSheng)** | All-day 5-minute memory segments, multi-mode workspaces, citation relabeling, and optimistic locks | Ships three formal workspaces, non-blocking 5-minute segment pipelines, `RequestKey` guards, and `relabel_citations` |
| **[Shiyin](https://github.com/juinwei7/Shiyin)** | CoreAudio mic + system audio capture and structured templates | Pairs `-100 dBFS` Barker-13 canary detection with system dialog inspection on a Rust-managed dual-lane sparse timeline |
| **[Meetily](https://github.com/Zackriya-Solutions/meetily) & [Ownscribe](https://github.com/paberr/ownscribe)** | Structured topic, decision, and action schemas and anti-fabrication rules | Runs deterministic `validate_minutes_grounding` checks in Rust that reject missing citations, invalid segment IDs, or ungrounded glossary edits |
| **[transcribe.cpp](https://github.com/anomalyco/transcribe.cpp) & [Hex](https://github.com/anomalyco/hex)** | Embedded static CPU ASR runtime and pinned model manifests | Hosts SenseVoice Small (~253 MB) and Qwen3 ASR 0.6B (~850 MB) in-process with streaming SHA-256 verification and atomic install |
| **[vecta](https://github.com/nitishagar/vecta) & Cicada** | Symlink path guards and debounced rolling live minutes | Enforces `reject_symlink_path` before disk I/O and schedules 3-utterance or 20s initial plus 45s debounced live minutes |

## Verification status in v2.1.0

Koe separates shipped and verified functionality, merged code awaiting physical hardware checks, and future roadmap items:

| Status | Scope |
| --- | --- |
| **Shipped & verified (`v2.1.0` build `10`)** | 8-crate Rust core, notarized Developer ID `arm64` bundle, SwiftUI workspaces, CoreAudio `CATapDescription` dual-lane capture, offline GGUF plus macOS 26 `SpeechAnalyzer`, scoped `@Observable` slices plus binary PCM FFI, BM25 search plus `validate_minutes_grounding` gate, 16 MCP tools, and verified local `/Applications/Koe.app` upgrade preserving workspace and Keychain items. |
| **Merged, tracked for physical hardware check (`ready-for-human`)** | Today source strip and one-click bean switch physical check ([#722](https://github.com/semantic-craft/koe/issues/722)), and closed-window physical D3200 wakeup and external headset hot-plug check ([#725](https://github.com/semantic-craft/koe/issues/725)). |
| **Next-stage roadmap (not wired in `2.1.0`)** | iOS and Android mobile hosts plus dual-device sync ([#124](https://github.com/semantic-craft/koe/issues/124), [#149](https://github.com/semantic-craft/koe/issues/149) to [#151](https://github.com/semantic-craft/koe/issues/151)), external AI delegation ([#152](https://github.com/semantic-craft/koe/issues/152) to [#155](https://github.com/semantic-craft/koe/issues/155)), Wi-Fi SoftAP fast transfer, firmware OTA, VAD dynamic segmentation, and local speaker diarization. |

## License

The D3200 protocol reverse-engineering notes and Rust port build on [tacshi/Soundcore](https://github.com/tacshi/Soundcore) under the MIT License, Copyright (c) 2026 Rocky Shi ([full license](assets/licenses/soundcore.txt)). See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for all upstream references, model licenses, and notices.

This repository remains private and is not publicly released. The MIT field in Cargo metadata does not override third-party component licenses. Signed macOS bundles include all third-party notices and license texts under `Koe.app/Contents/Resources/Licenses/`.
