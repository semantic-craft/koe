# 第三方内容

结构化纪要的章节选择和整理规则改编自以下 MIT 项目；没有引入其应用、后端或本地模型运行时。分发包包含完整许可正文，并登记到 Flutter LicenseRegistry。

| 项目 | 固定参考版本 | 采纳范围 | 许可 |
| --- | --- | --- | --- |
| [Meetily](https://github.com/Zackriya-Solutions/meetily/tree/a2cb62e827da7ef59f65064c97233efb2313878e) | a2cb62e827da7ef59f65064c97233efb2313878e | standard_meeting.json 的摘要、决策、待办及来源字段设计 | assets/licenses/meetily.txt |
| [Ownscribe](https://github.com/paberr/ownscribe/tree/9d5f82e2b8ec6c093755b43ebe8fead9ec06d7fe) | 9d5f82e2b8ec6c093755b43ebe8fead9ec06d7fe | prompts.py 的通用会议章节、合并去重和保留事实/任务规则 | assets/licenses/ownscribe.txt |
| [Shiyin（拾音）](https://github.com/juinwei7/Shiyin/tree/7ffd7d4b43b3f3cf06012cf3abfbe8e2b0e257f9) | 7ffd7d4b43b3f3cf06012cf3abfbe8e2b0e257f9 | `Sources/Shiyin/Transcribe/Diarizer.swift:26-47,140-165`、`Sources/Shiyin/Capture/AudioSources.swift` 的麦克风/系统音频 Core Audio 采集适配（Swift 改写），`Sources/Shiyin/Notes/Templates.swift`、`Sources/Shiyin/Notes/NotesPrompt.swift`、`Sources/Shiyin/Notes/SpeakerNaming.swift`、`Sources/Shiyin/Notes/TranscriptCorrection.swift`、`Sources/Shiyin/Notes/Backends/OpenAICompatibleAPI.swift` 的五种会议纪要模板、待确认问题与修订、AI 猜发言人名字、逐字稿校正建议及 OpenAI 兼容 / Ollama 端点与 JSON 提取思路，以及转写段落按时间重叠与最近中点分配发言人、首次出现顺序编号及群内凝聚度并错人风险阈值设计思路（以 Dart 重新实现） | assets/licenses/shiyin.txt |

思维导图固定依赖 GraphView 1.5.1（MIT），使用其 BuchheimWalkerAlgorithm 进行树形布局。界面交互、来源关联与离屏 PNG 导出由本项目实现；不需要在线渲染服务。依赖许可随 Flutter 包分发。

## 本机发言人区分运行时与模型（#371）

本机发言人区分固定依赖 [`sherpa_onnx` 1.13.8](https://pub.dev/packages/sherpa_onnx/versions/1.13.8)（上游仓库 [k2-fsa/sherpa-onnx v1.13.8](https://github.com/k2-fsa/sherpa-onnx/tree/v1.13.8)，Apache License 2.0，Copyright (c) 2022-2024 Xiaomi Corporation；上游仓库无独立 `NOTICE` 文件，完整许可正文见 `assets/licenses/sherpa_onnx.txt`）。

模型在首次使用时仅在 Wi-Fi 下按需下载（优先 ModelScope，失败时回退 HuggingFace），不在仓库或安装包内随包体积分发：

| 组件 / 模型 | 上游来源与版本 | 用途 | 确切下载地址（ModelScope 优先 → HuggingFace 回退） | 文件大小与 SHA-256 | 许可证与署名 |
| --- | --- | --- | --- | --- | --- |
| `sherpa_onnx` | [`v1.13.8`](https://github.com/k2-fsa/sherpa-onnx/tree/v1.13.8) | 三端离线说话人分段、嵌入提取与聚类运行时（Dart FFI） | pub.dev: `sherpa_onnx: 1.13.8` | 随各平台原生插件构建 | Apache-2.0（Copyright (c) 2022-2024 Xiaomi Corporation；`assets/licenses/sherpa_onnx.txt`） |
| `sherpa-onnx-pyannote-segmentation-3-0`（`model.onnx`，本地保存为 `segmentation-model.onnx`） | 转自 [`pyannote/segmentation-3.0`](https://huggingface.co/pyannote/segmentation-3.0)（CNRS），ONNX 转档 [`csukuangfj/sherpa-onnx-pyannote-segmentation-3-0`](https://huggingface.co/csukuangfj/sherpa-onnx-pyannote-segmentation-3-0) | 离线说话人语音活动与重叠分段 | 1. ModelScope：`https://modelscope.cn/models/pengzhendong/sherpa-onnx-pyannote-segmentation-3-0/resolve/master/model.onnx`<br>2. HuggingFace：`https://huggingface.co/csukuangfj/sherpa-onnx-pyannote-segmentation-3-0/resolve/main/model.onnx` | 5,992,913 字节<br>`220ad67ca923bef2fa91f2390c786097bf305bceb5e261d4af67b38e938e1079` | MIT License（Copyright (c) 2022 CNRS；`assets/licenses/pyannote_segmentation_3_0.txt`） |
| `3dspeaker_speech_campplus_sv_zh_en_16k-common_advanced.onnx`（3D-Speaker CAM++ 中英双语说话人嵌入模型） | 转自 [`iic/speech_campplus_sv_zh_en_16k-common_advanced`](https://modelscope.cn/models/iic/speech_campplus_sv_zh_en_16k-common_advanced) `v1.0.0`（[modelscope/3D-Speaker](https://github.com/modelscope/3D-Speaker)，Alibaba DAMO Academy），ONNX 转档 [`k2-fsa/sherpa-onnx speaker-recongition-models`](https://github.com/k2-fsa/sherpa-onnx/releases/tag/speaker-recongition-models) | 离线 16 kHz 说话人特征嵌入向量提取 | 1. ModelScope：`https://modelscope.cn/models/lijiu09/speaker-embedding-models/resolve/master/3dspeaker_speech_campplus_sv_zh_en_16k-common_advanced.onnx`<br>2. HuggingFace：`https://huggingface.co/csukuangfj/speaker-embedding-models/resolve/main/3dspeaker_speech_campplus_sv_zh_en_16k-common_advanced.onnx` | 28,281,164 字节<br>`aa3cfc16963a10586a9393f5035d6d6b57e98d358b347f80c2a30bf4f00ceba2` | Apache-2.0（Alibaba DAMO Academy / ModelScope 3D-Speaker Contributors；论文：Hui Wang et al., *CAM++: A Fast and Efficient Network for Speaker Verification Using Context-Aware Masking*；`assets/licenses/3dspeaker_campplus.txt`） |

## Rust 桌面预览

独立的 `desktop/app` 固定使用 [GPUI Kit 0.9.0](https://crates.io/crates/gpui-kit/0.9.0)，通过该库重导出的 GPUI 构建阅读窗口。GPUI Kit 的许可证为 [Apache-2.0](https://github.com/longbridge/gpui-kit/blob/main/LICENSE-APACHE)。此预览尚未发布；正式分发前须对 `desktop/app/Cargo.lock` 中实际目标平台使用的传递依赖逐项核对并随包提供适用许可与通知。
