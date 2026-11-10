<h1 align="center">Koe</h1>

<p align="center"><strong>A Rust recording and personal-memory core with a native macOS interface.</strong></p>

<p align="center">
  <img alt="Rust" src="https://img.shields.io/badge/Rust-2021-000000?style=flat-square&logo=rust&logoColor=white">
  <img alt="SwiftUI" src="https://img.shields.io/badge/SwiftUI-5.10%2B-F05138?style=flat-square&logo=swift&logoColor=white">
  <img alt="macOS 14+" src="https://img.shields.io/badge/macOS-14%2B-000000?style=flat-square&logo=apple&logoColor=white">
  <a href="https://github.com/semantic-craft/koe/actions/workflows/ci.yml"><img alt="CI" src="https://img.shields.io/github/actions/workflow/status/semantic-craft/koe/ci.yml?branch=main&style=flat-square&label=CI"></a>
  <img alt="License pending" src="https://img.shields.io/badge/License-pending-lightgrey?style=flat-square">
</p>

<p align="center"><a href="README.md">简体中文</a> · <strong>English</strong></p>

Koe connects directly to an Anker soundcore Work (D3200) recorder without Feishu. It keeps recordings and transcripts on your Mac, then organizes discussions into minutes, tasks, and memories. You can also import files or create text notes.

The product starts on macOS. **Today reviews the day, recording details preserve the original material, and Ask Koe searches across records.** Rust owns the data and processing state; SwiftUI presents it and handles native system interactions.

## Workflow

1. **Capture a record.** Record with a selected Mac microphone, retrieve a D3200 recording, import WAV, UTF-8 TXT, Markdown, or a `.koepack` containing text, or write a note. A new workspace starts empty.
2. **Transcribe and organize.** Alibaba DashScope handles speech recognition and Qwen generates structured minutes. Live device audio and saved audio enter the same Rust recording pipeline. Completed transcription proceeds to minutes generation.
3. **Review tasks and memories.** Generated candidates wait for review. Accept, dismiss, edit, or restore them; task completion and memory decisions persist locally.
4. **Follow the source.** Minutes, tasks, memories, and answers retain recording and utterance references. Open a source and return to the conversation. Audio records support playback and seeking; records export to Markdown.

Today gathers the day's records, pending decisions, and next actions. All Records holds the complete library. Each record owns its transcript, minutes, highlights, and processing state. Questions can target one record or the whole library.

Without cloud configuration, text notes, browsing, review, playback, and local retrieval remain available. Ask Koe labels retrieved original passages accordingly. Speech recognition and generated minutes require a configured provider.

Mac microphone recording supports pause and resume. Pausing drains accepted audio before confirmation; resuming continues the same recording without adding the pause interval. Audio stays local by default. Real permission, device switching, playback, and signed-app restart checks remain in [#616](https://github.com/semantic-craft/koe/issues/616) and [#620](https://github.com/semantic-craft/koe/issues/620). System audio capture and crash recovery are not connected yet.

## Data and service boundaries

- The signed app uses the macOS sandbox. Its default workspace is `~/Library/Containers/com.anker.ankerRecorder/Data/Library/Application Support/KoeWorkspace`. `product-workspace.json` stores records, review decisions, and conversation history; `audio/` stores audio separately.
- Signed installations store API keys in macOS Keychain. Rust persists models and endpoints without secrets in the workspace. Clearing credentials prevents legacy values from returning. Empty endpoint fields reset to provider defaults; embedded accounts, passwords, queries, and fragments are rejected.
- Development builds, explicit workspaces, and any `KOE_CREDENTIAL_SOURCE` override use session-only isolated credentials. The default development workspace is `KoeWorkspaceDevelopment`. No personal `.env` or `.envrc` is read. Real signed upgrade verification remains pending in [#603](https://github.com/semantic-craft/koe/issues/603).
- Meeting audio stays on this device by default, including older workspaces without an explicit policy. This blocks live, downloaded, and imported meeting audio from cloud transcription. On-device speech recognition is not connected yet and is reported as unavailable. Disabling the setting permits cloud transcription; cancelled work needs an explicit retry. Text summaries and questions can still use cloud services. Previously uploaded audio cannot be recalled. Signed-app and device acceptance remains in [#608](https://github.com/semantic-craft/koe/issues/608).
- Request state is saved before cloud work begins. Completion requires saving the returned result. Restarted applications mark unfinished work as interrupted; they do not automatically resend paid requests. Configure the provider again and explicitly retry.
- A workspace has one writer. Only one GUI, CLI, or MCP process can open it at a time. Closing the window keeps the app running; quit Koe with `⌘Q` before using the CLI.

## Build and run

Requirements: macOS 14+, Xcode Command Line Tools with Swift 5.10+, a Rust toolchain, and CMake. Opus is statically built from the pinned dependency source; no system `libopus` installation is required. Rust, C, and Swift use the same macOS 14 deployment target.

```bash
cargo build --package koe-host-api
swift build --package-path platforms/macos
```

To install a signed local application:

```bash
./scripts/install-macos.sh
```

The installer uses the configured Developer ID identity, installs `/Applications/Koe.app`, and runs `--verify-self` and `--smoke-test`. Those checks exercise the product workflow in isolated workspaces. Physical-device and long-running cloud use have separate acceptance checks.

```bash
./scripts/verify-local.sh --quick
./scripts/check
```

The quick gate checks script, UI, progress, and Rust compile/lint contracts. The full gate adds Rust and macOS Swift tests. See [CONTRIBUTING.md](CONTRIBUTING.md).

## CLI and MCP

The CLI uses the same `KoeRuntime` and workspace as the native application. After quitting the GUI:

```bash
cargo run --package koe-cli -- status
cargo run --package koe-cli -- search "product decisions"
cargo run --package koe-cli -- ask "what should happen next"
cargo run --package koe-cli -- mcp-stdio
```

Use `--workspace <directory>` for another library and `--record <ID>` to scope `search` or `ask`. MCP stdio exposes `search`, `get_record`, and `ask`; `ask` also saves conversation history. A separate CLI/MCP process uses isolated credentials and does not read the GUI's system credentials and currently uses local source retrieval. Stop the MCP process before reopening that workspace in the GUI.

## Architecture

| Layer | Paths | Responsibility |
| --- | --- | --- |
| Domain and protocol | [koe-engine](crates/koe-engine/), [koe-opus](crates/koe-opus/) | `ProductWorkspace`, per-record aggregates, review and source rules, retrieval, D3200 protocol, and an isolated libopus wrapper |
| Client services | [base](crates/koe-client-base/), [core](crates/koe-client-core/), [providers](crates/koe-client-providers/), [services](crates/koe-client-services/) | File locking, atomic persistence, data formats, network transport, audio import, and workspace storage |
| Runtime and API | [koe-runtime](crates/koe-runtime/), [koe-host-api](crates/koe-host-api/) | Device and asynchronous task coordination, persistence, version 2 snapshots and commands |
| Native host and CLI | [apple-shared](platforms/apple-shared/), [macos](platforms/macos/), [koe-cli](crates/koe-cli/) | SwiftUI, windows, CoreBluetooth, file selection, playback, and the shared-runtime command line |

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) and [ROADMAP.md](ROADMAP.md). iOS/Android hosts, screen and system audio capture, continuous microphone listening, translation, Google synchronization, automatic backup, and ACP are outside the current connected macOS product workflow.

## Acknowledgements

The D3200 protocol builds on [tacshi/Soundcore](https://github.com/tacshi/Soundcore); see [PROTOCOL.md](PROTOCOL.md). Architecture and product references include [metasequoiaime/msime](https://github.com/metasequoiaime/msime) for native-host boundaries, [BasedHardware/omi](https://github.com/BasedHardware/omi) for personal-memory workflows, and [screenpipe/screenpipe](https://github.com/screenpipe/screenpipe) for organizing records over time. Reference versions are documented in [reference-code.md](docs/agents/reference-code.md).

Structured-minutes prompts also draw from Meetily and Ownscribe. See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). Report security issues privately as described in [SECURITY.md](SECURITY.md).

## License

The repository retains its **license-pending, no-public-distribution policy until upstream authorization is confirmed**. Rights in upstream code remain with its authors. Until authorization is resolved, use is personal and redistribution is not permitted. Cargo package metadata does not substitute for authorization of upstream code.
