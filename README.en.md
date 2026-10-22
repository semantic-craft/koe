<p align="center">
  <img src="macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_128.png" alt="Koe" width="96" height="96">
</p>

<h1 align="center">Koe</h1>

<p align="center"><strong>Record and transcribe with the Anker soundcore Work recorder without Feishu, and turn each day into a personal record you can hand to AI.</strong></p>

<p align="center">
  <a href="https://flutter.dev"><img alt="Flutter 3.47.7" src="https://img.shields.io/badge/Flutter-3.47.7-02569B?style=flat-square&logo=flutter&logoColor=white"></a>
  <img alt="iOS 15+" src="https://img.shields.io/badge/iOS-15%2B-000000?style=flat-square&logo=apple&logoColor=white">
  <img alt="macOS 12+" src="https://img.shields.io/badge/macOS-12%2B-000000?style=flat-square&logo=apple&logoColor=white">
  <img alt="Android 17 (Pixel 11 Pro)" src="https://img.shields.io/badge/Android-17%20%C2%B7%20Pixel%2011%20Pro-3DDC84?style=flat-square&logo=android&logoColor=white">
  <a href="https://github.com/semantic-craft/koe/actions/workflows/ci.yml"><img alt="CI" src="https://img.shields.io/github/actions/workflow/status/semantic-craft/koe/ci.yml?branch=main&style=flat-square&label=CI"></a>
  <img alt="License pending" src="https://img.shields.io/badge/License-pending-lightgrey?style=flat-square">
</p>

<p align="center">
  <a href="README.md">简体中文</a> · <strong>English</strong>
</p>

---

> [!IMPORTANT]
> Koe is built on the original D3200 app and protocol reverse-engineering in [tacshi/Soundcore](https://github.com/tacshi/Soundcore). The upstream project has no license yet, so this repository will not be published until the original author grants permission. See [Acknowledgements](#acknowledgements) and [License](#license).

## Why Koe

The Anker soundcore Work (model D3200) is a small clip-on voice recorder. Officially it lives inside Feishu (Lark): recordings must be uploaded to Feishu Minutes to be transcribed, and the results stay in Feishu.

Koe lets the recorder work on its own. Your iPhone or Mac connects to it over Bluetooth, pulls the original recordings, and transcribes and organizes them with the model you choose (Apple on-device, Alibaba Qwen, or ByteDance Doubao). The original audio stays on your device, and every sentence links back to the moment it was spoken.

On top of that, Koe is growing into a phone-first personal record: recordings, places, to-dos and a diary gathered by day, followed up by project, and finally exported as files for an external AI.

## Features

### Recording and transcription

- Scan, pair and bind the recorder over Bluetooth; see recorder and charging-case battery; start, pause and stop recording remotely
- Live transcription while you record, with optional live translation (Apple on-device)
- Pull recordings from the recorder (Bluetooth, or Wi‑Fi direct batch export); recordings that grew after a resumed session are fetched again automatically
- Record with the phone microphone too (iPhone or Pixel); keeps recording when locked, pauses on incoming calls and recovers after the app is killed
- File transcription: chunked uploads for long Qwen recordings, Doubao turbo; submitted jobs keep being polled after a restart
- Start the recorder from the iPhone Action button or a Shortcut; on Android, long-press the Koe icon and pick Start recording

### Playback and correction

- Tap any sentence in the transcript to hear the original audio, including from the lock screen
- Corrected text and speaker labels keep their link to the audio
- Clip notes and bookmarks; a continuous listening queue
- Speaker distribution: see how long each person spoke on a timeline and jump to the sentence
- Sentence-aligned translation: tap a translated line to hear the source sentence
- Summaries, custom analysis, structured minutes (topics / decisions / to-dos) and mind maps, each pointing back to its source in the transcript

### Today · Projects · To-dos

- A "Today" timeline of the day's recordings and notes, with correctable topic assignment
- Projects followed across days; per-topic notes and topic summaries
- To-dos generated from commitments in conversations, exportable to iPhone Reminders and Calendar (on Android, to the system calendar)
- Approximate place recorded automatically for recordings, or added by hand
- New recordings are processed automatically (transcribe → summarize → extract to-dos) and resume after interruption

### Diary · Ask Koe · Morning brief

- A diary and weekly summary where every entry cites its sources
- "Ask Koe": ask follow-up questions about your own records on the phone, by typing or push-to-talk, with optional read-aloud answers
- Morning brief: key points from yesterday, generated on demand

### Export to AI

- Export Markdown by day, project or topic for the AI you already use
- Material packs (`.koepack`): export and re-import on another device or after a reinstall, restoring corrections, timestamps, speakers, bookmarks, places and topics, with the original audio included only if you choose
- Automatic archive of phone originals to your own Mac (encrypted LAN connection, confirmed only after verification)

## Screenshots

> Screenshots pending: they will be retaken with demo data before any public release, never with real recordings or places.

| Today | Recording detail | Ask Koe |
| --- | --- | --- |
| _pending_ | _pending_ | _pending_ |

## Supported hardware

| Device | Model | Status |
| --- | --- | --- |
| Anker soundcore Work (AI voice recorder) | D3200 | Supported: Bluetooth connection and control, live audio, offline file pull, Wi‑Fi SoftAP batch export |

Other soundcore recorders are untested. Protocol details are in [PROTOCOL.md](PROTOCOL.md).

| Platform | Status |
| --- | --- |
| iOS 15+ | Primary platform. Apple on-device transcription and translation need iOS 26+ |
| macOS 12+ | Companion for reading and archiving originals |
| Android 17 | Pixel 11 Pro only. Code merged, device acceptance pending (#345). No Apple on-device transcription or translation, Reminders or Mac archiving |

## Quick start

### Prerequisites

- macOS with Xcode (including the iOS platform) and CocoaPods
- Android: the Android SDK (compileSdk 37) and JDK 21
- Flutter 3.47.7 (same as CI)
- A soundcore Work D3200 recorder (without one you can still record on the phone, import audio and use everything else)
- Optional: an API key for [Alibaba Qwen (DashScope)](https://dashscope.aliyun.com/) or [Doubao Speech](https://www.volcengine.com/product/voice-tech)

### Install dependencies and run

```bash
git clone https://github.com/semantic-craft/koe.git
cd koe
flutter pub get
```

```bash
flutter run -d macos
```

```bash
flutter run -d ios
```

```bash
flutter run -d pixel
```

On a physical iPhone, choose your own development team for `ios/Runner.xcworkspace` in Xcode. `scripts/install-ios.sh`, `scripts/install-macos.sh` and `scripts/build-dmg.sh` are the maintainer's install and packaging scripts; check the target device and signing identity before running them.

If you switch from an old SPM build and see `local binary target opus ... does not contain a binary artifact`, run `flutter clean` and then `flutter pub get`.

### Install on a Mac

```bash
./scripts/install-macos.sh
```

Builds a Release app and installs it to `/Applications/Koe.app` (needs a Developer ID signing identity). `./scripts/build-dmg.sh` packages `dist/koe-<version>-macos.dmg`.

### iPhone Action button

After installing Koe and connecting the recorder at least once:

1. On the iPhone, open Settings → Action Button → Shortcut.
2. Choose **Koe → 开始录音** (the action is titled 「用 Koe 开始录音」, "Start recording with Koe").
3. Press and hold the Action button: Koe opens, reconnects the recorder if needed, and starts recording.

### Configure Qwen / Doubao API keys

1. In Koe, open Settings → 语音服务 (Speech service).
2. Choose a provider:
   - **Qwen**: enter the API key; the Workspace ID is optional. Summaries, minutes, Ask Koe and the other organizing features also use Qwen.
   - **Doubao**: enter the API key only (turbo file transcription and streaming recognition).
   - **Apple on-device**: no key needed; available on iOS 26+, with all processing on the device.
3. The provider is enabled once saved. Endpoints and models are chosen by the app.

Keys are stored in the system Keychain (on Android, in Keystore-encrypted storage), never in the settings file. Development and debug builds use an isolated in-memory store and never read or write keys in your personal Keychain.

### Tests

```bash
flutter analyze
```

```bash
flutter test
```

With a Pixel connected, `scripts/android-check` builds and installs a debug build and runs the unattended scenarios in [integration_test/android](integration_test/android/) on the phone. Unlock the phone first and leave it alone: the script keeps the screen on and runs the scenarios that lock the screen last; while the phone is locked, scenarios that need Koe on screen are skipped. It exits 77 (skipped) when the device is offline or a scenario was skipped.

## Architecture

Koe is a Flutter app. A Provider-managed `RecorderController` coordinates state and is split into one part file per feature; the personal record (timeline, to-dos, projects, diary, Q&A) is a separate set of JSON stores.

```
D3200 recorder ──BLE/Wi‑Fi──▶ ble/ wifi/ protocol/ crypto/
                                   │  pulled Opus audio
                                   ▼
                               audio/ ──▶ ai/ (Apple / Qwen / Doubao transcription)
                                   │
                                   ▼
               state/ (library, transcription jobs, personal record) ──▶ ui/
                                   │
                                   ▼
                  Markdown / material-pack export · Mac archive (archive/)
```

| Folder | Contents |
| --- | --- |
| [lib/ble](lib/ble/) | Advertisement parsing, GATT service, offline file pull, live audio stream |
| [lib/protocol](lib/protocol/) | Frame format, command codes, data models |
| [lib/crypto](lib/crypto/) | Device ECDH / AES session crypto |
| [lib/wifi](lib/wifi/) | SoftAP connection and batch export |
| [lib/audio](lib/audio/) | Ogg/Opus muxing, Opus→PCM decoding, audio conversion |
| [lib/ai](lib/ai/) | Transcription providers: Apple on-device, Qwen, Doubao |
| [lib/state](lib/state/) | Controller and persistence; [recorder/](lib/state/recorder/) is split by feature, [context/](lib/state/context/) is the personal record |
| [lib/archive](lib/archive/) | Phone-to-Mac archive of originals |
| [lib/platform](lib/platform/) | Keychain and Keystore, location, Reminders and calendar, Shortcuts, the Android foreground service and other platform bridges |
| [lib/ui](lib/ui/) | Screens and widgets |
| [darwin](darwin/), [ios](ios/), [macos](macos/) | Native Apple code |
| [android](android/) | Native Android code: foreground service and notification, launcher shortcut |
| [test](test/), [integration_test](integration_test/) | Unit, widget and performance tests |

Terms are in [GLOSSARY](GLOSSARY.md), design decisions in [docs/adr](docs/adr/), UI rules in [docs/design/ui-guidelines.md](docs/design/ui-guidelines.md). Project docs are written in Chinese.

## Roadmap

What is being built now, what comes next and what is on hold: [ROADMAP.md](ROADMAP.md). Release notes: [CHANGELOG.md](CHANGELOG.md).

## Contributing

Issues and PRs are welcome. Please read [CONTRIBUTING.md](CONTRIBUTING.md) first: changes land only through branches and PRs, and every PR states three acceptance items (regression test, real-world use, what was not covered). Report security issues privately as described in [SECURITY.md](SECURITY.md), and **never paste an API key into an issue**.

## Acknowledgements

**Koe started from [tacshi/Soundcore](https://github.com/tacshi/Soundcore) by [tacshi](https://github.com/tacshi) (Rocky Shi).** That project first built an app that uses the D3200 without Feishu and reverse-engineered the recorder's Bluetooth and Wi‑Fi protocol: service and characteristic UUIDs, frame format and command codes, the ECDH handshake and AES decryption, offline file pull and SoftAP batch export. [PROTOCOL.md](PROTOCOL.md) is the record of that work. Without it there would be no Koe.

A substantial part of Koe's Bluetooth, protocol, crypto, audio and Wi‑Fi modules still derives from the upstream code.

The structured-minutes rules are adapted from Meetily and Ownscribe (MIT); see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## License

**License pending: the upstream project has no license yet; this repository will not be published until the original author grants permission.**

Until then, all rights in the upstream code remain with its author. This repository is for private use only; please do not redistribute it.
