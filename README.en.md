<h1 align="center">Koe</h1>

<p align="center"><strong>Take back local control of your Anker soundcore Work (D3200) recorder and daily meeting notes.</strong></p>
<p align="center"><em>A pure-Rust domain and protocol core paired with a native SwiftUI macOS app for direct hardware pull, offline ASR, cited notes, and MCP.</em></p>

<p align="center">
  <img alt="Rust" src="https://img.shields.io/badge/Rust-2021-000000?style=flat-square&logo=rust&logoColor=white">
  <img alt="SwiftUI" src="https://img.shields.io/badge/SwiftUI-5.10%2B-F05138?style=flat-square&logo=swift&logoColor=white">
  <img alt="macOS 14+" src="https://img.shields.io/badge/macOS-14%2B-000000?style=flat-square&logo=apple&logoColor=white">
  <a href="https://github.com/semantic-craft/koe/actions/workflows/ci.yml"><img alt="CI" src="https://img.shields.io/github/actions/workflow/status/semantic-craft/koe/ci.yml?branch=main&style=flat-square&label=CI"></a>
  <img alt="Upstream license: MIT" src="https://img.shields.io/badge/Upstream_license-MIT-blue?style=flat-square">
</p>

<p align="center"><a href="README.md">简体中文</a> · <strong>English</strong></p>

Anker soundcore Work (D3200) packs hardware encryption, physical gesture flags, and long battery life into a tiny wearable pill, yet vendor software locks it inside Feishu and a cloud black box. Meanwhile, open-source projects have solved pieces of this problem in isolation: reverse engineering the D3200 protocol, keeping wearable pulls crash-safe, structuring all-day voice memories, grounding meeting minutes, and splitting a pure-Rust core from a native Apple UI.

**Koe brings those proven pieces together into one disciplined local-first core.** Rust owns the BLE protocol, audio assets, BM25 retrieval, citation checks, and workspace persistence, while SwiftUI renders a fast "one day, one page" macOS app. Even with zero cloud API keys configured, recording, offline transcription, playback, editing, and local search work out of the box.

## Four workspace modes for daily work

Koe organizes daily capture around what you are recording today, what was said earlier, and what needs action next. Switching sidebar views never interrupts an active capture session.

| Workspace mode | Best for | What it does in practice |
| --- | --- | --- |
| **Quick Note** (default) | Fleeting ideas, quick reminders, reading lists | A D3200 button press or shortcut opens Quick Note by default. Spoken notes enter your inbox with original timestamps, and AI summaries appear beside the transcript without overwriting your words. |
| **All-Day Listening** | Continuous background wear | Splits audio into 5-minute records automatically. While earlier segments summarize in the background, capture continues without dropping audio, and the day timeline preserves pauses and unrecorded gaps honestly. |
| **Live Minutes** | Active meetings and interviews | Shows transcript and minutes side by side on wide windows or in tabs on narrow ones. Initial minutes trigger after 3 finalized segments or 20 seconds, then refresh with a 45-second debounce without overlapping in-flight jobs. Action items generate only after recording stops, preventing duplicate to-dos mid-call. |
| **Voice Input** | Dictating at the cursor in any app | Turns the D3200 into a collar microphone wired over a local Unix socket to an external input method. The external IME handles text polish and cursor insertion, so audio is never transcribed twice. |

Three guarantees govern daily review across all four modes:

- **Every summary bullet and task links back to spoken words.** Minutes, tasks, memories, and Q&A answers bind to composite `record_id + segment_id` citations. Clicking a source jumps straight to the utterance and seeks audio playback. Editing a transcript latches `original_text` for one-click restoration and flags existing minutes as stale.
- **Ask your entire library without an LLM.** Koe builds a CJK bi-gram and Latin BM25 inverted index that searches 16,000 sentences (over 400,000 characters) in under 5 ms in unit benchmarks. When no text model is configured, Ask Koe returns cited `[S1]` and `[S2]` source lines directly. Ungrounded questions short-circuit locally instead of guessing.
- **Safe import, export, and reversible deletion.** Import WAV, UTF-8 TXT, Markdown, or self-contained `.koepack` archives, and export clean Markdown. Archive lock prevents edits or deletion. Soft-deleted items stay in Trash for 30 days with an 8-second undo bar, and permanent purge runs in two phases: only trashed items can be purged, and `.wav` and `.opus` files leave disk only after metadata commits.

## Getting full value from Anker soundcore Work (D3200)

Instead of treating wearable hardware as a generic microphone, Koe implements the D3200 BLE protocol and audio pipeline directly in Rust:

1. **No classic Bluetooth pairing, Feishu, or Anker cloud auth.** CoreBluetooth connects directly to service UUID `020cf5da-0000-1000-8000-00805f9b34fb` without OS classic pairing or Anker license servers. An outbound queue enforces 300 ms command pacing and packet chunking.
2. **In-process NIST P-256 ECDH and AES-256-CTR decryption.** Inside a `#![forbid(unsafe_code)]` Rust engine, Koe runs ephemeral P-256 key exchange (`0x2E/0x01`), RFC 5869 HKDF-SHA256 session key derivation, `soundcored3200` file-key verification, and T-table AES-256-CTR stream decryption with zero heap allocations per frame.
3. **166-byte slice-aligned resume and dual-rate static Opus decoding.** Koe aligns offline pulls to exact 166-byte records (4-byte sequence, 1-byte flags, 160-byte 20 ms Opus frame, and 1-byte padding), resuming after disconnects at `received_slice_count * 166` with a 5-second inactivity watchdog. Static source-built `libopus 1.5.2` decodes 16 kHz mono PCM16 for live ASR alongside 48 kHz mono audio for playback, while muxing raw frames into standard RFC 7845 Ogg Opus files.
4. **Disk `fsync` and SHA-256 custody before hardware deletion.** Modeled after wearable WAL custody, `CustodyReceipt` records exact byte count and 64-hex SHA-256 after `fsync`. Koe refuses to emit the `0x1A/0x10` delete command unless verified disk custody exists.
5. **Front double-tap bookmarks and acoustic thump gating.** Parsing `flags & 0x01` captures double-tap bookmarks at 20 ms resolution and emits `ControlEdge` triggers in collar standby mode. To stop finger taps on the plastic housing from polluting dictation, Koe skips the first 3 slices (60 ms) after a start tap and holds back and discards the last 12 slices (240 ms) before a stop tap. Standby scratch files auto-reclaim when idle, and `releaseControl` cleanly hands Bluetooth back so your phone can reconnect anytime.

> **Hardware channel status.** [PROTOCOL.md](PROTOCOL.md) documents Wi-Fi SoftAP fast transfer, Classic Bluetooth SPP, firmware OTA, device time sync, and binding commands observed during reverse engineering, and those paths are **not wired** in Koe today. All transfers run over BLE GATT, and firmware updates stay in the vendor app. Long offline cloud pulls, standby battery endurance, and Bluetooth headset coexistence have active real-device checks.

## Standing on open-source shoulders: what Koe kept, improved, and cut

Every core subsystem in Koe builds on prior open-source ideas with explicit credit, targeted fixes, and deliberate scope cuts:

| Reference project | Core strength adopted | How Koe adapted and improved it | Intentionally excluded or not yet wired |
| --- | --- | --- | --- |
| **[msime](https://github.com/metasequoiaime/msime)** | Pure-Rust core + thin native Apple UI four-layer split | Versioned C ABI v2 with `catch_unwind`, immutable `generation` snapshots, and an owner-private Unix socket bridge so GUI, CLI, and MCP share one live runtime | iOS and Android hosts remain future milestones |
| **[tacshi/Soundcore](https://github.com/tacshi/Soundcore)** | Reverse-engineered D3200 BLE protocol notes and Dart implementation | Ported to memory-safe Rust state machines, fixed `166 * N` resume alignment, and added double-tap flag parsing and custody locks | Wi-Fi SoftAP and Classic SPP remain unwired |
| **[BasedHardware/omi](https://github.com/BasedHardware/omi)** | Disconnect WAL custody and review confirmation cards | Made disk custody receipts a hard prerequisite for device file deletion, and wired `Proposed / Accepted / Dismissed` cards to a single-writer ledger and 16 MCP tools | No cloud app store, social feeds, or multi-user cloud accounts |
| **[screenpipe](https://github.com/screenpipe/screenpipe)** | Timeline aggregation and global live subtitle bar | `LiveCaptionBar` reads directly from Rust `SpeechSession` snapshots for both D3200 and Mac mic input | **Explicitly removed** 24/7 screen recording, desktop OCR, and vision models to stay audio-only |
| **[TaoSheng](https://github.com/0xCoach/TaoSheng)** | All-day memory segments, multi-mode workspaces, citation self-healing, and optimistic locking | Implemented four workspace modes, 5-minute segments, `RequestKey` stale-overwrite protection, and `relabel_citations` | Uses fixed 5-minute slices today. VAD silence splitting, CAM++ speaker ID, and 21-day calendar disambiguation are not wired |
| **[Shiyin](https://github.com/juinwei7/Shiyin)** | CoreAudio mic + system audio capture and structured templates | Added an inaudible `-100 dBFS` Barker-13 canary probe plus OS permission-window inspection to detect macOS system-audio grants reliably, coordinated by a Rust dual-lane timeline | Earlier pyannote offline diarization is absent from the Rust build. Real-device system-audio permission and listening checks remain open |
| **[Meetily](https://github.com/Zackriya-Solutions/meetily) & [Ownscribe](https://github.com/paberr/ownscribe)** | Structured topic/decision/action JSON schema and strict anti-fabrication rules | Added deterministic `validate_minutes_grounding` checks in Rust that reject missing citations, invalid segment IDs, or ungrounded glossary `heard` corrections | Keeps one unified schema plus custom sections instead of bundling dozens of niche templates |
| **[transcribe.cpp](https://github.com/anomalyco/transcribe.cpp) & [Hex](https://github.com/anomalyco/hex)** | Embedded CPU offline ASR runtime and pinned model manifest | Runs SenseVoice Small (~253 MB) and Qwen3 ASR 0.6B (~850 MB) in-process with streaming SHA-256 checks, atomic install, and RAII cleanup on abort | CPU backend only today. GPU/ANE acceleration and larger Whisper models are not bundled |
| **[vecta](https://github.com/nitishagar/vecta) & Cicada** | Symlink traversal guards and bounded live-minutes pacing | Added `reject_symlink_path` checks before reads and writes, plus 3-segment/20s initial and 45s debounced live-minutes scheduling | Moved text polishing out of Koe to external IMEs so Koe's stored transcript stays verbatim |

## Practical reliability and privacy boundaries

What keeps a daily voice tool trustworthy is how it behaves when hardware disconnects, permissions fail, or the app crashes mid-request:

- **Crash-safe `.capture` recording.** Mac microphone streams append incrementally to `<id>.capture`, updating the 44-byte WAV header at offset 0 and calling `sync_data()` per chunk. After an unexpected termination, startup validates the wave file, hard-links it to `.wav`, syncs the directory, and removes `.capture` only after metadata commits.
- **Inaudible canary probe for macOS system audio.** macOS provides no public callback for CoreAudio tap consent, and `AudioDeviceStart` succeeds silently with zeroed buffers when denied. Koe plays an inaudible `-100 dBFS` Barker-13 tone through default output while inspecting visible system auth dialogs, marking access denied only when no non-zero loopback arrives after prompts close.
- **Zero silent cloud re-billing.** Every remote task saves `RequestKey(record_id, attempt, input_revision)` before starting. After any restart, incomplete jobs move to `Interrupted` so the user decides when to retry.
- **Local-only audio default and two-phase Keychain commits.** `meeting_audio_policy` defaults to `LocalOnly`, and Koe never falls back to cloud engines silently. Signed macOS Keychain saves register `pending_credentials` on disk before creating items, clean up orphans on next boot by exact reference, and write a tombstone on clear so old keys never resurrect. Development builds keep session-isolated credentials and never read `.env` or `.envrc`.
- **Workspace-wide safety guards.** The Cargo workspace sets `unsafe_code = "deny"`, with `#![forbid(unsafe_code)]` enforced in 6 of 8 crates and `unsafe` isolated strictly to `koe-opus` and `koe-host-api`. Static `libopus` builds forbid system library discovery, and `scripts/verify-ui-principles.py` caps every Swift source file at 500 lines.

## CLI and MCP

While Koe is running, it exposes an owner-private Unix socket inside its container with `0700` directory permissions, `0600` socket permissions, and `getpeereid` same-UID peer verification. CLI commands and AI agents attach to the live `KoeRuntime` session over that bridge, or fall back to direct workspace locking when Koe is closed:

```bash
cargo run --package koe-cli -- status
cargo run --package koe-cli -- search "product decisions"
cargo run --package koe-cli -- ask "what should happen next"
cargo run --package koe-cli -- mcp-stdio
cargo run --package koe-cli -- companion-listen
```

- **16 MCP stdio tools.** Exposes full-text search, today brief, record listing and details, grounded Q&A, task/memory review and completion, note creation, segment annotation, transcript editing, speaker management, archive/trash operations, D3200 status/control, and generation polling. Permanent purge is deliberately excluded from agent tools.
- **External IME text and audio bridge.** The [local text bridge](docs/local-text-bridge.md) streams `transcript_final`, physical `control_edge` gestures, and exclusive `external_pcm_v1` leases so external voice input methods can consume clean D3200 audio directly.

## Build and run

Requires macOS 14+, Xcode Command Line Tools (Swift 5.10+), Rust (1.85+), and CMake. Opus compiles statically from pinned sources with no external `libopus` needed.

```bash
# Build the C ABI library and native macOS host
cargo build --package koe-host-api
swift build --package-path platforms/macos

# Package and Developer ID sign /Applications/Koe.app, then run --verify-self and --smoke-test
./scripts/install-macos.sh

# Local checks: fast gate vs full workspace suite
./scripts/verify-local.sh --quick
./scripts/check
```

## Current scope and honest verification status

Koe keeps implemented, CI-tested, and real-hardware-pending items clearly separated:

| Status | Coverage |
| --- | --- |
| **Implemented and passing CI / local gates** | 8-crate Rust core, D3200 BLE handshake/slice-resume/custody logic, 4-mode SwiftUI workspaces, offline GGUF and Apple SpeechAnalyzer (macOS 26+) integration, CoreAudio dual-lane timeline and canary probe code, BM25 retrieval and minutes grounding gate, 16 MCP tools, and local Unix bridge. |
| **Code merged, pending real-device or account verification** | Long D3200 offline pulls with paid cloud ASR ([#588](https://github.com/semantic-craft/koe/issues/588)), collar standby endurance and A2DP headset hot-plugging ([#641](https://github.com/semantic-craft/koe/issues/641)), real macOS system-audio permission dialogs and output switching, routine signed-app Keychain inheritance on upgrade, and end-to-end physical hardware + IME daily acceptance ([#668](https://github.com/semantic-craft/koe/issues/668)). |
| **Explicitly out of current scope** | iOS and Android hosts, Wi-Fi SoftAP transfer and firmware OTA, VAD silence segmentation, local speaker diarization, 24/7 screen capture, multi-device sync, and external calendar writeback. |

## Architecture and documentation

| Layer | Paths | Responsibility |
| --- | --- | --- |
| Domain and protocol | [koe-engine](crates/koe-engine/), [koe-opus](crates/koe-opus/) | I/O-free state machines, citation checks, BM25, D3200 protocol and crypto, static libopus wrapper |
| Client services | [koe-client-base](crates/koe-client-base/), [providers](crates/koe-client-providers/), [services](crates/koe-client-services/) | Symlink-safe atomic writes and locks, HTTPS/WebSocket and offline ASR threads, audio assets, single-writer store |
| Runtime and API | [koe-runtime](crates/koe-runtime/), [koe-host-api](crates/koe-host-api/) | Command orchestration, bounded async queues, transactions, C ABI v2 snapshots, and `.koe/koe.sock` bridge |
| Native host and CLI | [apple-shared](platforms/apple-shared/), [macos](platforms/macos/), [koe-cli](crates/koe-cli/) | SwiftUI workspaces, CoreBluetooth, CoreAudio, Keychain adapter, and CLI/MCP entrypoints |

Further reading: [Architecture](docs/ARCHITECTURE.md) · [D3200 Protocol Notes](PROTOCOL.md) · [Mode Workspaces](docs/mode-workspaces.md) · [Local Text Bridge](docs/local-text-bridge.md) · [Roadmap](ROADMAP.md) · [Contributing](CONTRIBUTING.md) · [Security](SECURITY.md) · [Third-Party Notices](THIRD_PARTY_NOTICES.md).

## License

The D3200 protocol notes and ported implementation build on [tacshi/Soundcore](https://github.com/tacshi/Soundcore) under the MIT License, Copyright (c) 2026 Rocky Shi ([full license](assets/licenses/soundcore.txt)). See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for all upstream references and license texts.

This repository remains private and is not publicly released. The MIT field in Cargo metadata does not replace third-party component licenses. Signed macOS bundles ship third-party notices and license texts under `Koe.app/Contents/Resources/Licenses/`.
