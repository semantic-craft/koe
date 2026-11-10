# 第三方内容

本文件保留当前代码的参考来源及前版使用过的依赖记录。实际构建依赖以根 `Cargo.lock` 和 `platforms/` 中的 Swift Package 清单为准；这里列出某项参考，不代表对应产品能力已接入。已有许可正文位于 `assets/licenses/`。

| 项目 | 固定参考版本 | 采纳范围 | 许可 |
| --- | --- | --- | --- |
| [Meetily](https://github.com/Zackriya-Solutions/meetily/tree/a2cb62e827da7ef59f65064c97233efb2313878e) | a2cb62e827da7ef59f65064c97233efb2313878e | standard_meeting.json 的摘要、决策、待办及来源字段设计 | assets/licenses/meetily.txt |
| [Ownscribe](https://github.com/paberr/ownscribe/tree/9d5f82e2b8ec6c093755b43ebe8fead9ec06d7fe) | 9d5f82e2b8ec6c093755b43ebe8fead9ec06d7fe | prompts.py 的通用会议章节、合并去重和保留事实/任务规则 | assets/licenses/ownscribe.txt |
| [Shiyin（拾音）](https://github.com/juinwei7/Shiyin/tree/7ffd7d4b43b3f3cf06012cf3abfbe8e2b0e257f9) | 7ffd7d4b43b3f3cf06012cf3abfbe8e2b0e257f9 | 麦克风/系统音频 Core Audio 采集适配、五种会议纪要模板、待确认问题与修订、AI 猜发言人名字、逐字稿校正建议及转写段落按时间重叠与最近中点分配发言人设计思路（以纯 Rust 重新实现） | assets/licenses/shiyin.txt |
| [TaoSheng（涛声）](https://github.com/0xCoach/TaoSheng/tree/23907c46415828342b51a296332dd97db25243c4) | 23907c46415828342b51a296332dd97db25243c4 | 全天候随身语音记忆管线、21 天日历消歧 + 寻物共乘、AskEngine 多轮工具检索与 `[^n]` 引用自愈、乐观锁确认卡、CAM++ 声纹认人及五栏信息架构设计思路（以纯 Rust + SwiftUI 独立实现） | 架构参考 |
| [MetasequoiaIME (`msime`)](https://github.com/metasequoiaime/msime) | main | 纯 Rust 内核 + 全原生 Apple 平台宿主（SwiftUI + C ABI）四层分离架构 | MIT / Apache-2.0 |

## 本机发言人区分运行时与模型参考（#371）

前版的本机发言人区分与声纹提取使用 `k2-fsa/sherpa-onnx` ONNX 模型生态（Apache License 2.0，Copyright (c) 2022-2024 Xiaomi Corporation；完整许可正文见 `assets/licenses/sherpa_onnx.txt`）。

当前 Rust/macOS 产品管线未接入以下模型的下载与推理。以下保留既有版本及授权来源，不表示当前安装包包含这些能力：

| 组件 / 模型 | 上游来源与版本 | 用途 | 确切下载地址（ModelScope 优先 → HuggingFace 回退） | 文件大小与 SHA-256 | 许可证与署名 |
| --- | --- | --- | --- | --- | --- |
| `sherpa-onnx` | [`v1.13.8`](https://github.com/k2-fsa/sherpa-onnx/tree/v1.13.8) | 离线说话人分段、嵌入提取与聚类运行时（Rust / C API） | GitHub Release: `k2-fsa/sherpa-onnx v1.13.8` | 前版参考，当前未链接 | Apache-2.0（Copyright (c) 2022-2024 Xiaomi Corporation；`assets/licenses/sherpa_onnx.txt`） |
| `sherpa-onnx-pyannote-segmentation-3-0`（`model.onnx`，本地保存为 `segmentation-model.onnx`） | 转自 [`pyannote/segmentation-3.0`](https://huggingface.co/pyannote/segmentation-3.0)（CNRS），ONNX 转档 [`csukuangfj/sherpa-onnx-pyannote-segmentation-3-0`](https://huggingface.co/csukuangfj/sherpa-onnx-pyannote-segmentation-3-0) | 离线说话人语音活动与重叠分段 | 1. ModelScope：`https://modelscope.cn/models/pengzhendong/sherpa-onnx-pyannote-segmentation-3-0/resolve/master/model.onnx`<br>2. HuggingFace：`https://huggingface.co/csukuangfj/sherpa-onnx-pyannote-segmentation-3-0/resolve/main/model.onnx` | 5,992,913 字节<br>`220ad67ca923bef2fa91f2390c786097bf305bceb5e261d4af67b38e938e1079` | MIT License（Copyright (c) 2022 CNRS；`assets/licenses/pyannote_segmentation_3_0.txt`） |
| `3dspeaker_speech_campplus_sv_zh_en_16k-common_advanced.onnx`（3D-Speaker CAM++ 中英双语说话人嵌入模型） | 转自 [`iic/speech_campplus_sv_zh_en_16k-common_advanced`](https://modelscope.cn/models/iic/speech_campplus_sv_zh_en_16k-common_advanced) `v1.0.0`（[modelscope/3D-Speaker](https://github.com/modelscope/3D-Speaker)，Alibaba DAMO Academy），ONNX 转档 [`k2-fsa/sherpa-onnx speaker-recongition-models`](https://github.com/k2-fsa/sherpa-onnx/releases/tag/speaker-recongition-models) | 离线 16 kHz 说话人特征嵌入向量提取 | 1. ModelScope：`https://modelscope.cn/models/lijiu09/speaker-embedding-models/resolve/master/3dspeaker_speech_campplus_sv_zh_en_16k-common_advanced.onnx`<br>2. HuggingFace：`https://huggingface.co/csukuangfj/speaker-embedding-models/resolve/main/3dspeaker_speech_campplus_sv_zh_en_16k-common_advanced.onnx` | 28,281,164 字节<br>`aa3cfc16963a10586a9393f5035d6d6b57e98d358b347f80c2a30bf4f00ceba2` | Apache-2.0（Alibaba DAMO Academy / ModelScope 3D-Speaker Contributors；论文：Hui Wang et al., *CAM++: A Fast and Efficient Network for Speaker Verification Using Context-Aware Masking*；`assets/licenses/3dspeaker_campplus.txt`） |
