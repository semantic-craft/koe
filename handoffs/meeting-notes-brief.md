# 会议纪要功能：对照拾音（Shiyin）的缺口与分期方案

> 状态：方案稿，只规划、不含代码。写于 2026-10-22，代表开发部（图灵）。
> 需求来源：用户经亚里士多德转述——「他提到的所有功能都要集成到我们这个项目里面……Mac 端也得做到，iOS 端、安卓端都得具备，至少具备他说的这些功能。」
> 参照对象：[@jaywcjlove 的帖子](https://x.com/jaywcjlove/status/2113063815495782528)介绍的 [juinwei7/Shiyin](https://github.com/juinwei7/Shiyin)（拾音）。本文读的是 commit `7ffd7d4b43b3f3cf06012cf3abfbe8e2b0e257f9`（2026-10-21）。下面的「文件:行」，拾音一侧都相对于 `Sources/Shiyin/`（README 和 docs 除外），Koe 一侧都相对于仓库根目录，以 main `58425a4` 为准。
> 用户已定的范围：Mac、iOS、Android 三端都至少具备下面列出的拾音功能。

## 1. 结论先说

- 拾音是**仅 macOS 26 + Apple Silicon** 的 Swift 原生应用，用 MIT 许可证。录音、转写、发言人区分都在本机做；**但大模型整理会把转写文字、用户笔记、词汇表和会议信息发给用户选的服务**，默认是 Claude Code CLI（等于发给 Anthropic）。帖子里说的「全程不上传录音」，准确的意思是**不上传音频，文字照样上传**（README.md:160、`Services/JobRunner.swift:46`）。
- Koe 已有的会议相关能力（结构化纪要带出处回听、发言人改名与分布、书签、问答、模板）三端基本一样，因为都是同一套 Dart 代码。缺口集中在四件事：**①Mac 没有本机录音和系统声音采集；②本地转写只在 iOS 26+ 有（Apple 设备端），Mac 和 Android 只能用云端，而云端转写要上传音频；③发言人区分全靠云端（千问 / 豆包），本机没有；④纪要周边功能（词汇表、草稿纪要、待确认问题、声纹、多种整理后端、PDF/Word/字幕导出）都还没有。**
- 推荐路线：**三端统一用 [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx)（Apache-2.0，有官方 Flutter 包 `sherpa_onnx`）做本地发言人区分，也用它做 Android 的本地转写**；Apple 两端继续用现成的 Apple 设备端识别，再把 iOS 的桥接挪到 `darwin/`，这样 macOS 26 也能用。Mac 的系统声音用 Core Audio tap，可以照 MIT 许可证借用拾音的 `SystemAudioSource`。大模型整理默认**只发文字**，另加「完全离线」开关。
- **平台硬限制（要用户拍板）**：iOS 和 Android 都没有通用办法录下其他应用的通话声音，所以「系统声音」和「线上会议检测」这两项在手机上没法做到跟 Mac 一样（见 §5.4、§7 第 1 条）。

## 2. 拾音的全部功能（带出处）

说明：「出处」里的 README 行号指 `README.md`（繁体中文版）；代码路径相对于 `Sources/Shiyin/`。

### 2.1 录音与采集

| # | 功能 | 实现与出处 |
| --- | --- | --- |
| S1 | 三种录音源：只录麦克风、麦克风＋电脑声音（线上会议）、只录电脑声音；双源时分两个声道写文件 | README:27；`Capture/Recorder.swift:35`（`mic / system / both`），`:198-202`；麦克风用 AVAudioEngine，见 `Capture/AudioSources.swift:59`；电脑声音用 Core Audio process tap（`CATapDescription` + `AudioHardwareCreateProcessTap`，会排除拾音自己），见 `Capture/AudioSources.swift:107-126` |
| S2 | 录音中显示各路音量；提醒「麦克风没声音 / 太小声 / 背景太吵」 | README:28-29；`Capture/Recorder.swift:50-52`、`:366-400` |
| S3 | 暂停；关掉主窗口照常录音，菜单栏可以暂停和停止 | README:28、31；`Capture/Recorder.swift:148` |
| S4 | 全局快捷键：⌃⌥⌘R 开始/停止，⌃⌥⌘B 标记重点 | README:31、34；`Services/GlobalHotKey.swift:4-8` |
| S5 | 录音中插拔耳机、换输出设备，自动接回继续录 | README:32；`Capture/AudioSources.swift:14-16`、`Capture/Recorder.swift:467` |
| S6 | 检测到 Zoom、Teams、Meet 等开始用麦克风时提醒开录，会议结束时提醒停止（只提醒，不会自动录） | README:33；`Services/MeetingDetector.swift:5-22` |
| S7 | 磁盘空间不够时提醒；写入失败时自动停止，已录的部分保留 | README:35 |
| S8 | 应用崩溃或突然断电后，下次打开自动恢复录音 | README:36；`Store/AppModel.swift:625`（`recoverRecordings`）、`Capture/WAVRepair.swift:10-11` |
| S9 | 边录边记：「我的笔记」每换一行自动记录音时间；「标记重点」 | README:19；`Store/AppModel.swift:1191`（`addBookmark`）；笔记连同时间一起送进提示词，见 `Notes/NotesPrompt.swift:89`、`:169-173` |
| S10 | 录音中或导入时可以选「大约几个人」，发言人分得更准 | README:30；`Transcribe/Diarizer.swift:70`（`minSpeakers`）；docs/design.md:883-888 |

### 2.2 导入

| # | 功能 | 出处 |
| --- | --- | --- |
| S11 | 导入音视频（m4a、mp3、wav、aac、flac、caf、aiff、mp4、mov）、逐字稿（srt、vtt、txt）、Markdown 笔记、整场会议包（.shiyin）；支持拖入、⌘O、拖到 Dock、「打开方式」 | README:37；`Services/Importer.swift:30-34` |

### 2.3 转写

| # | 功能 | 出处 |
| --- | --- | --- |
| S12 | **实时逐字稿**：录音中用 macOS 自带的 SpeechAnalyzer/SpeechTranscriber，在本机识别；暂定结果约 0 秒出，定稿约 2 秒；不使用词汇表 | README:18-19、232；`Capture/LiveTranscriber.swift:5`、`:74-80` |
| S13 | **本机正式转写**：whisper.cpp + Breeze ASR 25（q8 GGML）；日文改用 Whisper large-v3-turbo；也可以选 macOS 自带识别；模型还没下载好时先用自带识别，之后一键重转；长录音在最安静处切段 | README:38；`Transcribe/WhisperEngine.swift:74-83`；`Transcribe/TranscriptionPipeline.swift:7`（`breeze / system`）；模型下载地址见 `Services/ModelStore.swift:42`、`:50`、`:58`；`Transcribe/SystemTranscriber.swift:5-20` |
| S14 | 词汇表当作 whisper 的提示词；从参会人、发言人、改过的字和标题里建议新词 | README:38、42；`Transcribe/WhisperEngine.swift:43-48`；`Model/Records.swift:157` |
| S15 | 会议语言可选中、英、日（转写、纪要、导出标题都跟着变）；开录后听约 10 秒自动判断语言（whisper base） | README:39-40；`Transcribe/LanguageDetector.swift:8`、`:24` |
| S16 | 逐字稿校正：由大模型找出可能听错的字，用户点「接受」才改，可以还原 | README:41；`Notes/TranscriptCorrection.swift:3-13` |
| S17 | 双声道回音去重：麦克风段落和电脑声音段落时间重叠、文字相似时，删掉麦克风那段 | `Transcribe/TranscriptionPipeline.swift:9-11`、`:234-270`；docs/design.md:442 |

### 2.4 发言人

| # | 功能 | 出处 |
| --- | --- | --- |
| S18 | **本机发言人区分**：FluidAudio 的离线区分器（pyannote 分段 + 嵌入 + VBx 聚类，跑在 ANE 上）；模型首次使用时下载 | README:43；`Transcribe/Diarizer.swift:1-4`、`:59-80`；docs/design.md:30、176 |
| S19 | 每段标发言人、每人一种颜色；可以改名、只看某一位 | README:43 |
| S20 | 声纹：命名后记住声音，以后的会议自动带入名字（标「自动」）；声纹只存在本机、不放进导出包，可以查看、删除、关闭 | README:44、161；`Store/Voiceprints.swift:27-29`（余弦门槛 0.65） |
| S21 | 大模型从对话内容猜发言人名字，列成建议，用户点「套用」才改；改名后纪要里的名字一起换 | README:45；`Notes/SpeakerNaming.swift:3`；`Store/AppModel.swift:1068` |
| S22 | 按「大约几个人」重新区分发言人，文字不变，手动改过的归属保留 | README:46-47；docs/design.md:893-910 |
| S23 | 合并发言人、逐句或连续一段改归属、复原 | README:47；`Store/SpeakerEdits.swift:20-117` |
| S24 | 可能把不同的人并成一位时，逐字稿上方提示重新区分 | README:48；`Transcribe/Diarizer.swift:38-42` |

### 2.5 大模型纪要

| # | 功能 | 出处 |
| --- | --- | --- |
| S25 | 模板：一般会议、一对一、访谈、课堂/演讲、脑力激荡，也可以自定义 | README:50；`Notes/Templates.swift:48-76` |
| S26 | 整理后端：Claude Code CLI、Codex CLI、Anthropic / OpenAI / Gemini API、OpenAI 兼容 API（Groq、OpenRouter、本机 Ollama、LM Studio），或「不整理」；**默认是 Claude CLI** | README:51；`Notes/LLMClient.swift:3-4`；`Services/JobRunner.swift:46`；`Notes/Backends/OpenAICompatibleAPI.swift:9-12`；`Notes/Backends/CLIBackends.swift:1-15` |
| S27 | 纪要分摘要、决议、待办（负责人/期限）、未决问题、议题、自定义段落，**每一条都带 mm:ss 时间点，点一下跳回录音** | README:21；`Model/MeetingNotes.swift:3-5`；`Notes/NotesPrompt.swift:32`、`:182-184`（逐字稿以 `[时间] 发言人：内容` 的格式送出） |
| S28 | 停止后先用实时逐字稿出一份「草稿」，正式转写完成后自动换成正式版 | README:20、52；`Store/AppModel.swift:606` |
| S29 | 不确定的人名和专有名词列进「待确认」（最多 8 题），用户回答后大模型据此修订纪要 | README:21；`Notes/NotesPrompt.swift:31`、`:35`、`:189-192` |
| S30 | 纪要可以直接编辑，每次修改都留版本，可以复原 | README:53；`Store/AppDatabase.swift:77`（`notes_versions`） |
| S31 | 提问：对单场会议提问，回答带时间点；也可以问所有会议、当前文件夹或最近 30 天（先抽关键词，再全文检索，只发相关片段） | README:64；`Notes/AskPrompt.swift:3`；`Store/Asking.swift:27-33`、`:122-159` |

### 2.6 导出、管理和其他

| # | 功能 | 出处 |
| --- | --- | --- |
| S32 | 导出：纪要 → Markdown/PDF/Word，或复制成富文本、Markdown、纯文本；逐字稿 → txt/md/srt/vtt/docx（时间点和发言人可选）；录音 → m4a/wav；整场 → .shiyin 包；可以用 AirDrop、邮件、信息分享 | README:54-63；`IO/Exporters.swift:48-63`；`IO/Package.swift:3`；`Views/ExportSheet.swift:124-148` |
| S33 | 文件夹、全文搜索（FTS5 trigram）、垃圾桶（30 天内可还原） | README:65；`Store/AppDatabase.swift:111-112`、`:134`、`:248-346` |
| S34 | 倍速播放（0.75×～2×）、用词替换（逐字稿和纪要一起改，可以顺手加进词汇表）、转写完自动压缩成 m4a、完成或失败时发通知 | README:66；`Services/Player.swift:13`；`Store/AppModel.swift:1200`；`Services/JobRunner.swift:12`、`:55`；`Services/Notifier.swift:4` |
| S35 | 设置页：整理工具、模板、词汇表、录音（来源/麦克风/语言/引擎/快捷键/会议检测）、发言人（声纹）、模型与存储（下载/暂停/删除）、高级 | README:167-177 |
| S36 | 隐私边界：录音、转写、发言人区分不联网；整理、校稿、提问、猜名会把**逐字稿文字、笔记、词汇表、会议基本信息**发给所选服务，跨会议提问只发命中的片段；音频不发；API key 存在 Keychain；选「不整理」或本机 Ollama/LM Studio 时完全离线 | README:9、154-165；`Services/Keychain.swift:6`；音频没有发出去的证据：`Notes/` 目录里没有任何上传音频的代码（`rg -i 'audio\|m4a\|wav' Notes/` 只命中 Gemini 列模型时排除的关键字，`Notes/Backends/GeminiAPI.swift:51`）。其他出网：模型下载（HuggingFace）和应用内更新（`Services/Updater.swift:112-146`） |

不纳入对比的：应用内更新、自签名/DMG 打包、「回报问题」（`Services/ProblemReport.swift`）、官网。这些是拾音自己的分发机制，Koe 走自己的安装脚本。

### 2.7 拾音和它所用组件的许可证

| 组件 | 用途 | 许可证 | 出处 / 核对方式 |
| --- | --- | --- | --- |
| 拾音本体 | 全部代码和 docs | **MIT**，Copyright (c) 2026 juinwei7 | 仓库 `LICENSE`；README:258-260 |
| whisper.cpp（b5454 XCFramework） | 正式转写 | MIT | `Package.swift`；[ggml-org/whisper.cpp](https://github.com/ggml-org/whisper.cpp) |
| Breeze ASR 25（GGML 转档） | 中文/中英混合模型，约 2B 参数，Whisper-large-v2 微调，偏台湾华语 | Apache-2.0 | README:245；[HF 模型卡](https://huggingface.co/MediaTek-Research/Breeze-ASR-25) |
| Whisper large-v3-turbo / base（GGML） | 日文转写、语言判断 | MIT | README:246；[ggerganov/whisper.cpp 模型库](https://huggingface.co/ggerganov/whisper.cpp)（HF API 的 license 字段是 mit） |
| FluidAudio 0.17.7 | 发言人区分 SDK | Apache-2.0 | `Package.resolved`；`Resources/ThirdPartyLicenses.txt:6`、`:51` |
| FluidAudio 的区分模型（Community-1 Core ML 转档） | 分段 / 嵌入 / PLDA | **CC-BY-4.0**（署名）；旧版在线区分器用的 pyannote segmentation-3.0 是 MIT，wespeaker 是 CC-BY-4.0 | [FluidInference/speaker-diarization-coreml](https://huggingface.co/FluidInference/speaker-diarization-coreml)；[pyannote/speaker-diarization-community-1](https://huggingface.co/pyannote/speaker-diarization-community-1)（HF API 的 license 字段是 cc-by-4.0）。拾音的 `ThirdPartyLicenses.txt` 只列了 SDK 许可证，没列模型的 CC-BY 署名（检索 `CC-BY` 无结果） |
| GRDB.swift | SQLite | MIT | `Package.resolved` |

**能不能借代码**：拾音是 MIT，**可以复制或改写它的代码和提示词**。义务是保留版权声明和 MIT 许可全文：按 Koe 现有做法写进 `THIRD_PARTY_NOTICES.md`，被复制的文件头注明来源 commit。真正能直接搬的不多，因为拾音是 Swift/SwiftUI、macOS 26、GRDB，Koe 是 Flutter 加少量 Swift/Kotlin 原生代码。可直接借的见 §5.6。Koe 自己仍然是「License pending」、只供私人使用（README「许可」一节），加入 MIT 或 Apache-2.0 依赖不影响这个状态；以后若要公开分发，要连同 CC-BY 模型的署名一并处理。

## 3. Koe 现状（三端）

Koe 是**一个 Flutter 仓库同时出三端**（`ios/`、`macos/`、`android/`，业务逻辑在 `lib/` 里共用）。没有单独的移动端仓库：`gh repo list semantic-craft --limit 300` 只找到 `semantic-craft/koe` 一个跟 koe 相关的仓库。

| 方面 | Mac | iOS | Android |
| --- | --- | --- | --- |
| 定位（ROADMAP） | 「辅助阅读与归档端」，不阻塞手机 | 主力平台 | 只适配 Pixel 11 Pro / Android 17，代码已合并，待真机验收（#345）；解冻范围**不包括**「本机识别/翻译的 Android 替代」 |
| 本机录音 | **没有**：`phoneRecordingEnabled = runsOnPhone`（`lib/state/recorder_controller.dart:285`、`lib/platform/device_kind.dart:9-15`）；`macos/Runner/Release.entitlements` 只有蓝牙和网络权限，没有 `audio-input`。只能远程控制录音豆录音 | 手机麦克风录音：锁屏继续、来电暂停、进程被杀后找回；也能控制录音豆 | 同 iOS（#340），前台服务加通知 |
| 本地转写 | **没有**：`AppleSpeechService._supportedPlatform` 只认 iOS（`lib/ai/apple_speech.dart:88-89`），桥接代码只在 `ios/Runner/AppleSpeechBridge.swift` | Apple 设备端（iOS 26+，`SpeechTranscriber`，`ios/Runner/AppleSpeechBridge.swift:97-106`、`:177-187`）：实时和文件转写都在本机，还能实时翻译 | **没有** |
| 云端转写 | 千问、豆包（`lib/ai/speech_provider.dart:3-16`）。**会上传音频**：千问走 OSS 临时上传（`lib/ai/oss_upload_request.dart:8`），豆包上传文件 | 同左 | 同左 |
| 发言人区分 | 只有云端：千问 `diarization_enabled`（`lib/ai/qwen_stt.dart:547-585`），豆包 `enable_speaker_info`（`lib/ai/doubao_stt.dart:502`）。Apple 设备端没有区分 | 同左 | 同左 |
| 纪要 | 千问 `compatible-mode` 对话接口，**只发文字**（`lib/state/recording_analysis.dart:253-299`，默认模型 `qwen3.8-flash`，`:355`）；结构化纪要分议题/决策/待办/未决问题，每条带 `[S#]` 出处（`lib/state/meeting_minutes.dart:20-37`、`:53-61`），点出处回听原句（`lib/ui/widgets/cited_text.dart:8`，#129）；可以编辑（`lib/ui/widgets/minutes_panel.dart:253`）；有思维导图（#28）；提示词模板库（`lib/state/recording_analysis.dart:78-101`，#76） | 同左 | 同左 |

## 4. 缺口表

标记：**有** = 已有；**部分** = 部分有；**无** = 没有。证据列出 Koe 一侧的文件或工单 / PR。「无」表示在 main 上检索没找到实现，也没有工单，不代表做不到。

| # | 拾音功能 | Mac | iOS | Android | Koe 侧证据 / 说明 |
| --- | --- | --- | --- | --- | --- |
| S1 | 麦克风 / 系统声音 / 双源 | 部分 | 部分 | 部分 | 三端都能控制录音豆录音；手机能用麦克风录（`recorder_controller.dart:285`）；Mac 没有麦克风录音；三端都**没有系统声音**采集 |
| S2 | 音量显示与收音提醒 | 无 | 无 | 无 | `lib/` 里检索不到 |
| S3 | 暂停、后台继续录 | 部分 | 有 | 有 | Mac 只能远程暂停/停止录音豆；手机见 README「录音与转写」、#340 |
| S4 | 全局快捷键开录 / 标记重点 | 无 | 部分 | 部分 | iOS 操作按钮、快捷指令开录（#37）；Android 长按图标开录（#344）；录音豆双击打标记（`lib/protocol/slice_marks.dart`）三端通用；Mac 没有键盘快捷键 |
| S5 | 换音频设备自动接回 | 无 | 无 | 无 | 未找到实现，未验证 |
| S6 | 线上会议检测提醒 | 无 | 无 | 无 | 未找到实现 |
| S7 | 磁盘不足提醒、写入失败时保留已录部分 | 无 | 无 | 无 | 未找到实现，未验证 |
| S8 | 崩溃后恢复录音 | 无 | 有 | 有 | Mac 没有本机录音；手机见 README「进程被杀后下次启动找回」；Android 待 #345 |
| S9 | 边录边记带时间、标记重点 | 部分 | 部分 | 部分 | 录音豆双击标记；录完后可加片段书签和批注（`lib/state/recording_bookmarks.dart:15`，#144）；**录音中没有带时间戳的文字笔记** |
| S10 | 预估人数 | 无 | 无 | 无 | — |
| S11 | 导入音视频、字幕、Markdown、会议包 | 部分 | 部分 | 部分 | 导入音频（#125、Android #341）、导入妙记文字（#127）、`.koepack`（#145）；不能导入 srt/vtt/Markdown，视频未验证 |
| S12 | 本机实时逐字稿 | 部分 | 有 | 部分 | iOS 26+ 用 Apple 设备端在本机识别；Mac 和 Android 只能对录音豆实时流或手机麦克风做**云端**流式识别（`lib/state/recorder/live_transcription.dart`、`lib/ai/cloud_stt_stream.dart`） |
| S13 | 本机正式转写 | 无 | 部分 | 无 | iOS 26+ 只有 Apple 设备端（`apple_speech.dart:88-89`），没有 whisper、没有分段策略；iOS < 26 只能用云端 |
| S14 | 词汇表与建议 | 无 | 无 | 无 | 检索 vocab/hotword/glossary/热词 无结果 |
| S15 | 会议语言、自动判断语言 | 部分 | 部分 | 部分 | Apple 引擎要先选源语言（`speech_provider.dart` 里的 `requiresSourceLanguage`）；云端千问能自动判断；没有本机判断语言 |
| S16 | AI 校正建议 | 部分 | 部分 | 部分 | 只有手动校订且保留出处（#128）；没有 AI 建议 |
| S17 | 双声道回音去重 | 无 | 无 | 无 | 没有双声道录音，自然也没有 |
| S18 | **本机**发言人区分 | 部分 | 部分 | 部分 | 只有云端（千问/豆包），要上传音频；本机没有 |
| S19 | 改名、颜色、只看某人 | 部分 | 部分 | 部分 | 改名（`lib/state/recorder/transcripts.dart:482`，#128）；发言人分布与片段定位（`lib/ui/screens/speaker_distribution_screen.dart`，#143）；「只看某人」未验证 |
| S20 | 声纹跨会议自动认人 | 无 | 无 | 无 | — |
| S21 | AI 猜发言人名字 | 无 | 无 | 无 | — |
| S22 | 按人数重新区分，保留手改 | 无 | 无 | 无 | — |
| S23 | 合并 / 逐句改归属 / 复原 | 部分 | 部分 | 部分 | 逐句改归属有（`lib/state/transcript_store.dart:23`、`:145-155` 的 `segmentSpeakersByKey`）；合并、复原没有 |
| S24 | 可能并错人时提示 | 无 | 无 | 无 | — |
| S25 | 会议类模板 | 部分 | 部分 | 部分 | 模板库可以自建（#76）；内置的是默认摘要、结构化纪要、读书笔记、思考笔记，没有一对一/访谈/课堂/脑暴 |
| S26 | 多种整理后端、本机模型、不整理 | 部分 | 部分 | 部分 | 只有千问（`recording_analysis.dart:253`）；自动整理可以开关（#133、#109）；没有 OpenAI 兼容接口，也不能接本机 Ollama/LM Studio |
| S27 | 纪要每条带时间、点击回听 | 有 | 有 | 有 | `[S#]` 出处点开回听原句（#129）；对用户不显示 mm:ss，但功能对等 |
| S28 | 实时稿草稿 → 正式版替换 | 无 | 无 | 无 | 录音结束时保存实时文字；转写后自动整理（#133），但不用实时稿先出草稿纪要 |
| S29 | 待确认问题、回答后修订 | 无 | 无 | 无 | — |
| S30 | 编辑纪要、版本历史 | 部分 | 部分 | 部分 | 能编辑（`minutes_panel.dart:253`）；版本与复原未验证 |
| S31 | 单场 / 跨会议提问，回答带时间 | 部分 | 有 | 有 | 「问 Koe」跨记录连续问答，回答带 `[S#]` 出处可回听（`lib/state/recorder/ask.dart:7`，#141）；Mac 宽屏布局下的入口未逐项验证；单场用「自定义分析」（#24）顶替 |
| S32 | md/pdf/docx、srt/vtt、音频、会议包、系统分享 | 部分 | 部分 | 部分 | Markdown 阅读稿、`.koepack`（`lib/ui/widgets/material_export_sheet.dart:42`、`:253`）、原件分享；没有 PDF、Word、srt、vtt |
| S33 | 文件夹、全文搜索、垃圾桶 | 部分 | 部分 | 部分 | 项目和主题大致相当于文件夹（#135、#50）；只能搜标题（`lib/ui/library_filter.dart:1`）；回收站有（#132） |
| S34 | 倍速、用词替换、压缩、通知 | 部分 | 部分 | 部分 | 倍速有（`lib/ui/widgets/playback_bar.dart:9`）；用词全局替换、完成通知没有 |
| S35 | 设置与模型管理 | 部分 | 部分 | 部分 | 有语音服务设置；没有本地模型下载管理（目前不需要） |
| S36 | 录音不上传（本地优先） | 无 | 部分 | 无 | iOS 选 Apple 设备端时音频不出手机；Mac 和 Android 只有云端引擎，转写一定要上传音频；没有「仅本地」总开关 |

**各端缺几项（共 36 项）**

| 端 | 已有 | 部分有 | 没有 |
| --- | --- | --- | --- |
| Mac | 1 | 18 | 17 |
| iOS | 5 | 18 | 13 |
| Android | 4 | 17 | 15 |

## 5. 分期方案

原则：沿用 Koe 现有结构（`RecorderController` 的 part 文件、`SttProvider` 引擎枚举、`RecordingAnalysis` 和模板库、`[S#]` 出处），**不另起一套会议应用**。「会议」是录音的一种使用方式，不是新的数据模型。每期拆成若干工单，按 AGENTS.md 的规则「一个工单一个 PR」推进；需要真机的步骤另开「需要真机」工单，不闸住合并。

### 5.1 第 1 期：「录音不上传」的底座 + Mac 本机录音

- **目标**：三端都有「仅本地」开关，打开后任何音频都不出设备；Mac 能用麦克风录音，macOS 26 上能用 Apple 设备端做实时和文件转写。
- **范围**
  1. 设置里新增「录音只留本机」（暂名）：打开后，引擎列表只留 `onDevice` 类引擎，云端引擎显示「已关闭：会上传音频」；对已有录音手动点云端转写时要二次确认。
  2. 把 `ios/Runner/AppleSpeechBridge.swift` 挪到 `darwin/`，iOS 和 macOS 共用；`_supportedPlatform` 改成 iOS 26+ 或 macOS 26+（运行时判断版本，**不提高** macOS 12 的最低要求）。
  3. Mac 加 `com.apple.security.device.audio-input` 权限，`phoneRecordingEnabled` 在 Mac 上打开，复用手机录音这条路径。
- **验收（agent 能跑的）**：`scripts/check`；新增回退测试——(a)「仅本地」打开时，用假 HTTP 客户端跑一次完整的录音 → 转写 → 整理，断言**没有任何请求体含音频字节**，也没有请求发到 OSS 或豆包上传端点（对应 CONTRIBUTING 第 5 条「检查序列化后的真实字节」）；(b) macOS 目标平台下 Apple 引擎出现在引擎列表里，可用性按版本判断。
- **用户真机验收**：Mac（macOS 26）断网后用麦克风录 5 分钟，实时文字出现，结束后本机转写完成；Mac 小于 26 时 Apple 引擎标「不可用」并说明原因。

### 5.2 第 2 期：本机发言人区分（三端）+ 发言人编辑补齐

- **目标**：不上传音频也能分出发言人；补齐 S10、S22、S23、S24。
- **范围**：接入 `sherpa_onnx`（Dart FFI，三端同一套代码），用 pyannote segmentation-3.0 加一个说话人嵌入模型（3D-Speaker 或 NeMo，sherpa-onnx 官方都有转好的 ONNX）做离线区分；转写段落按时间重叠分给发言人（思路参考拾音 `Transcribe/Diarizer.swift:140-165` 的 `assignNumbering`）；可选「大约几个人」；重新区分时保留手动改过的归属；合并发言人和复原。模型首次使用时下载（见 §7 第 7 条）。
- **验收**：`scripts/check`；回退测试——段落分配、合并、复原、重新区分时保留手改，用固定的 turn 序列做纯 Dart 测试；另写评测脚本（**不进** `check`），在 AMI ES2004a 片段（CC BY 4.0，拾音也用它做截图）上算 DER，数字写进 PR。门槛建议沿用拾音 T-A3：2～4 人录音，标错发言人的时长不超过 15%（docs/design.md:1097）。Android 用 `scripts/android-check` 在 Pixel 上跑一个区分场景。
- **用户真机验收**：iPhone、Pixel、Mac 各录一段 3 人以上、10 分钟以上的真实会议，断网完成区分；改名、合并、重新区分都正常。

### 5.3 第 3 期：Android 本地转写 + 本地引擎补齐

- **目标**：Android 不靠云端也能实时和事后转写；iOS/macOS 26 以下也有本地选项。
- **范围**：新增 `SttProvider.local`（暂名，`onDevice = true`），用 sherpa-onnx：实时用流式 zipformer 中英双语模型，事后用非流式模型。候选：SenseVoice、Paraformer、Whisper 系列，按 §5.5 的许可证和实测选。加 silero VAD 切段；模型下载管理放进设置。sherpa 的 transducer 模型支持 hotwords，可以接上第 4 期的词汇表。
- **验收**：`scripts/check`；回退测试——引擎可用性判断、「仅本地」下的引擎排序；`scripts/android-check` 加本地转写场景（Pixel 离线跑通）；`scripts/perf-check` 记 1 小时音频的转写耗时和峰值内存。
- **用户真机验收**：Pixel 开飞行模式录 10 分钟中英混合会议，实时字幕出现，结束后完成本地转写。

### 5.4 第 4 期：Mac 系统声音 + 会议录音体验

- **目标**：在 Mac 上开线上会议时能把对方的声音录进来；三端录音页补齐会议常用功能。
- **范围**
  1. Mac 系统声音：Core Audio process tap，可以照 MIT 许可证借用拾音 `Capture/AudioSources.swift:107-187` 的 `SystemAudioSource`。需要 macOS 14.2+（[Apple 文档：Capturing system audio with Core Audio taps](https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps)），版本不够时退到只录麦克风。Koe 的 Mac 版开了 App Sandbox，**沙盒里 process tap 能不能用还没验证**，先做一个技术验证工单。分两个声道写文件，回音去重的思路参考 `TranscriptionPipeline.swift:234-270`。
  2. 录音页：音量和收音提醒（S2）、录音中带时间戳的文字笔记（S9）、大约几个人（S10）；Mac 全局快捷键（S4）；Mac 会议检测提醒（S6，参考 `Services/MeetingDetector.swift`）。
  3. 手机端：**系统声音做不了通用方案**。Android 的 AudioPlaybackCapture 只能抓 `USAGE_MEDIA/GAME/UNKNOWN` 用途的声音，通话类声音抓不到（[Android 文档](https://developer.android.com/media/platform/av-capture)）；iOS 没有公开 API 能录其他应用的通话声音（ReplayKit 广播扩展能否拿到会议应用的声音未验证）。手机上开会改用麦克风外放加录音豆收音，这一点在 §7 请用户确认。
- **验收**：`scripts/check`；回退测试——双声道写入和恢复、回音去重的文字相似度判断（纯 Dart）、收音提醒的阈值状态机；Mac 系统声音只能真机验收。
- **用户真机验收**：Mac 上开 Zoom 或腾讯会议，用「麦克风 + 系统声音」录 10 分钟，对方的声音进了逐字稿，自己的回音没有重复出现。

### 5.5 第 5 期：纪要质量（词汇表、草稿、待确认、模板、后端）

- **范围**：词汇表（S14），作为 Apple 引擎的上下文提示、sherpa 的 hotwords 和整理提示词的一部分，再加上词汇建议；停止录音后用实时稿先出草稿纪要（S28）；待确认问题和回答后修订（S29）；纪要版本历史（S30）；内置一对一、访谈、课堂、脑暴模板（S25）；AI 校正建议（S16）；AI 猜发言人名字（S21）；整理后端加「OpenAI 兼容接口」（可以填 Mac 或局域网上的 Ollama/LM Studio）和「不整理」（S26）。提示词结构可以参考拾音 `Notes/NotesPrompt.swift`（MIT，复制要署名），但 Koe 继续用 `[S#]` 出处，不改成 mm:ss，保持跟 #129 一致。
- **验收**：`scripts/check`；回退测试——草稿被正式版替换且不覆盖用户的编辑、待确认回答后 `[S#]` 出处保持合法（复用 `validateMinutes`）、版本复原、兼容接口的请求体只含文字（检查真实字节）。按 CONTRIBUTING 第 5 条，至少用授权测试音频真跑一次千问。
- **用户真机验收**：用一场真实会议走一遍：草稿 → 正式版 → 回答待确认 → 改一处 → 复原。

### 5.6 第 6 期：导出与管理、声纹

- **范围**：导出 PDF、Word、srt、vtt，复制富文本（S32）；全文搜索（S33）；用词全局替换并顺手加进词汇表（S34）；完成/失败通知（S34）；导入 srt/vtt/Markdown（S11）；声纹（S20）用第 2 期的说话人嵌入，**只存本机**，不进 `.koepack`、不进 Mac 归档，可以删除、可以关闭。
- **验收**：`scripts/check`；回退测试——srt/vtt 时间格式往返、导出包里不含声纹、全文搜索命中校订后的文字（对照 #235 的教训）。
- **用户真机验收**：三端各导出一次 PDF 和 srt，用别的应用打开确认；同一人在两场会议里被自动认出来。

### 5.7 借代码还是借思路

| 拾音部分 | 做法 | 说明 |
| --- | --- | --- |
| `SystemAudioSource`（Core Audio tap，`Capture/AudioSources.swift:107-187`） | **可以复制后改写**（MIT） | 放进 `macos/Runner`，文件头写来源 commit，`THIRD_PARTY_NOTICES.md` 补 MIT 全文 |
| 长录音在最安静处切段（`Transcribe/WhisperEngine.swift:74-90`） | 可以复制，也可以只借思路 | 要改写成 Dart；算法很短，建议自己写并注明参考 |
| 回音去重（`Transcribe/TranscriptionPipeline.swift:234-270`） | 同上 | — |
| 发言人编号分配、合并风险分数（`Transcribe/Diarizer.swift:38-165`） | 借思路 | 依赖 FluidAudio 的数据结构，Koe 用 sherpa-onnx，要重写 |
| 纪要、校正、猜名、待确认的提示词（`Notes/*.swift`） | 可以改写后用（MIT） | 原文是繁体中文和台湾用语，要改写成简体；Koe 的 `[S#]` 格式和 JSON 校验不能动 |
| 声纹阈值（余弦 0.65、同人最低 0.81、不同人最高 0.42，`Store/Voiceprints.swift:27-29`） | 借思路 | 换了嵌入模型后要重新标定 |
| SwiftUI 界面、GRDB 结构、CLI 后端 | 不借 | 技术栈不同；CLI 后端（调用 claude/codex）在手机上用不了 |
| FluidAudio | **不作为首选** | Apple 两端才能用（iOS 17 / macOS 14 起），Android 还得另找方案；模型是 CC-BY-4.0，要署名。如果 sherpa-onnx 在 Apple 端的准确度达不到第 2 期门槛，再把它作为 Apple 端的可选升级 |

### 5.8 移动端本地转写和发言人区分：候选、取舍、推荐

**本地转写**

| 候选 | 平台 | 优点 | 缺点 | 许可证 |
| --- | --- | --- | --- | --- |
| Apple SpeechAnalyzer / SpeechTranscriber（设备端） | iOS 26+、macOS 26+ | Koe 在 iOS 上已经接好；不用下载模型、速度快；支持实时 | 有系统版本门槛；拾音实测中文会议的字错误率约 25%（README:233）；不能用词汇表（README:232） | 系统框架 |
| [whisper.cpp](https://github.com/ggml-org/whisper.cpp) | 三端（README 里有 iOS / Android 示例，Apple 上编码器能走 Core ML/ANE） | 准确度高，能用 prompt 带词汇；拾音在 Mac 上用 | 不是真正的流式，手机上大模型太慢太大（Breeze 约 2B 参数，q8 约 1.6 GB），手机只能用 small 或 base 级别；Koe 要自己写 FFI | MIT（模型 MIT；Breeze 是 Apache-2.0） |
| [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx)（官方 Flutter 包 [`sherpa_onnx`](https://pub.dev/packages/sherpa_onnx)） | Android、iOS、macOS（arm64） | **流式加非流式、VAD、发言人区分、说话人识别都在一个包里**，有 Dart API；有中英双语的流式 zipformer；可以跑 Whisper、SenseVoice、Paraformer | 包体积和模型体积要实测；非流式中文模型的许可证要逐个核对 | 代码 Apache-2.0；模型各自不同（见下） |
| Android `SpeechRecognizer.createOnDeviceSpeechRecognizer` | Android 12+（Pixel） | 系统自带 | 官方文档写明这个 API「不适合连续识别」（[文档](https://developer.android.com/reference/android/speech/SpeechRecognizer)），没有可靠的段落时间戳，不适合一小时的会议 | 系统 API |

**推荐**：Apple 两端默认用 Apple 设备端（第 1 期，几乎零新依赖）；Android 加上 Apple 低版本用 sherpa-onnx（第 3 期）。whisper.cpp 先不引入，等用户觉得 Apple/sherpa 的准确度不够、并且接受下载大模型时，再作为 Mac 上的「高精度」选项（对应拾音的 Breeze 路线）。

**发言人区分**

| 候选 | 平台 | 取舍 | 许可证 |
| --- | --- | --- | --- |
| sherpa-onnx speaker diarization（pyannote segmentation-3.0 + 3D-Speaker/NeMo 嵌入 + 聚类，[文档](https://k2-fsa.github.io/sherpa/onnx/speaker-diarization/index.html)） | 三端，Dart API | **一套代码覆盖三端**，和本地转写共用一个依赖；准确度要在 AMI 上实测 | sherpa Apache-2.0；segmentation-3.0 MIT（[HF](https://huggingface.co/pyannote/segmentation-3.0)）；嵌入模型的许可证待逐个核对 |
| FluidAudio（Core ML，pyannote Community-1 + VBx） | 仅 iOS 17+ / macOS 14+ | 拾音实测效果不错，跑在 ANE 上；但 Android 用不了，等于要维护两套 | SDK Apache-2.0，模型 CC-BY-4.0 |
| pyannote（Python）原版或自己导出 | — | 手机上跑不了 Python；自己导出 ONNX 的工作量大，等于重做 sherpa 已经做好的事 | 模型 MIT / CC-BY-4.0 |
| 继续用云端（千问/豆包） | 三端 | 已有；但违反「录音不上传」 | — |

**推荐**：sherpa-onnx。拾音放弃它的理由是「要另外接 C++ 和 ONNX Runtime」（docs/design.md:1054），对纯 Swift 应用成立；Koe 用 Flutter，有官方 Dart 包，这条理由不成立。

**非流式中文模型的许可证提醒**：SenseVoiceSmall 用的是 FunASR 自定义的 [MODEL_LICENSE](https://github.com/modelscope/FunASR/blob/main/MODEL_LICENSE)（HF 上标为 `other`），条款没读完，选用前必须核对；Whisper 系列是 MIT，比较稳。

### 5.9 怎么保持「录音不上传」

| 环节 | 默认（建议） | 开关 |
| --- | --- | --- |
| 实时转写和事后转写 | 「录音只留本机」**打开**：只用本机引擎（Apple 设备端 / sherpa） | 关掉后才能选千问、豆包（会上传音频，界面上写明） |
| 发言人区分 | 本机（sherpa） | 跟随上面的开关；用云端引擎时用云端自带的区分 |
| 纪要、问答、校正、猜名 | **只发文字**到千问：逐字稿、笔记、词汇表、标题；跨记录问答只发命中的片段（Koe 现在就是这样，`recording_analysis.dart:253-299`） | 「整理时发送文字给大模型」可以关；后端可以换成 OpenAI 兼容接口指向本机或局域网模型；「完全离线」= 不整理，或者只用本机后端 |
| 声纹 | 只存本机 | 可以关、可以删；不进导出包、不进 Mac 归档 |
| Mac 归档 | 维持现状（局域网加密直连到自己的 Mac，#148） | 不算「上传」，但要在设置说明里写清楚 |

测试上，按 CONTRIBUTING 第 5 条，「仅本地」模式要有一个检查**序列化后真实字节**的测试，确认没有任何出网请求带音频。

## 6. 依赖和许可证义务汇总（Koe 引入时）

| 依赖 | 许可证 | 义务 |
| --- | --- | --- |
| 拾音代码 / 提示词（若复制） | MIT | `THIRD_PARTY_NOTICES.md` 写版权和许可全文；文件头注明来源 commit |
| sherpa-onnx / `sherpa_onnx` | Apache-2.0 | 保留 LICENSE，若上游有 NOTICE 也一并保留；改过的文件要注明 |
| pyannote segmentation-3.0 | MIT | 署名 |
| 嵌入模型（3D-Speaker / NeMo） | 待核对 | 选定后补进本表 |
| 非流式中文模型（SenseVoice / Paraformer） | FunASR MODEL_LICENSE（待核对） | 读完条款再决定 |
| Whisper 模型（若用） | MIT | 署名 |
| FluidAudio 及其模型（若作为 Apple 端升级） | Apache-2.0 / CC-BY-4.0 | 署名和保留 NOTICE |

## 7. 待用户决定的问题

1. **手机端的系统声音**：iOS 和 Android 都没有通用办法录其他应用的通话声音（§5.4 第 3 条）。能否接受「手机开会用麦克风或录音豆收音，只有 Mac 支持系统声音」？
2. **「录音只留本机」的默认值**：只对会议场景默认打开，还是全局默认打开？全局打开的话，会改变现在「配了千问就默认用千问」的行为（`lib/ai/speech_provider.dart` 里的 `initialSpeechProvider`）。
3. **纪要用哪个大模型**：继续默认用千问云端（只发文字），还是默认本机模型？要不要支持 OpenAI 兼容接口和本机 Ollama？
4. **路线图变化**：Mac 从「辅助阅读与归档端」变成完整的会议纪要端，Android 增加本机识别。这和 ROADMAP、#110、#331 的现有决定冲突，需要用户确认后改 ROADMAP。
5. **最低系统版本**：Mac 系统声音要 macOS 14.2+，Apple 本地转写要 macOS / iOS 26+。按版本降级（推荐），还是提高最低版本？
6. **语言范围**：只做中文和英文，还是像拾音一样也做日文？中文以简体和大陆口音为主吗（Breeze 偏台湾华语）？
7. **模型下载**：本地模型首次使用要下载几十到几百 MB。从 HuggingFace 下还是 ModelScope 镜像？只在 Wi-Fi 下载？
8. **声纹**：同意只存本机、不进导出包和 Mac 归档吗？
9. **手机上的会议检测**：手机上做不了「检测会议应用开始用麦克风」。要不要改成按日历事件提醒（Koe 已经接了日历导出）？
10. **PDF / Word 导出**是否必要，还是有 Markdown 和字幕文件就够？
11. **工单**：本文只是方案，没开工单。用户同意后，按 §5 每期拆成 GitHub Issues。

## 8. 未验证的事项

- 拾音的功能清单来自 README 和代码阅读，**没有构建、没有运行**（要 macOS 26 和 Apple Silicon）；准确度数字都引自它的 README。
- Koe 三端的「已有 / 部分有」来自读 main 的代码和 README，**没有在真机上逐项点过**。Mac 宽屏布局下的「问 Koe」入口、「只看某位发言人」、纪要版本复原、导入视频，都未验证。
- 下面几项都没有做技术验证：Mac App Sandbox 里能不能用 Core Audio process tap；`sherpa_onnx` 在 iOS 和 macOS 上的包体积和构建兼容性（Flutter 3.47.7、iOS 15 最低版本）；sherpa 发言人区分在中文会议上的 DER；iOS ReplayKit 能不能录到会议应用的声音。
- 嵌入模型（3D-Speaker / NeMo）和 SenseVoice / Paraformer 的许可证条款，没有逐个读完。
