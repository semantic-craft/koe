<p align="center">
  <img src="assets/artwork/koe-schoolgirl-b-cheerful.png" width="132" alt="Koe">
</p>

<h1 align="center">Koe</h1>

<p align="center">
  <strong>把安克 soundcore Work（D3200）录音豆与日常 Mac 会议，完整带回本机磁盘。</strong><br>
  <sub>Bring your Anker soundcore Work (D3200) collar recorder and daily Mac meetings home to local disk.</sub>
</p>

<p align="center">
  <a href="docs/releases/v2.1.0.md"><img alt="v2.1.0" src="https://img.shields.io/badge/release-v2.1.0-1f6f54?style=flat-square"></a>
  <img alt="Rust 2021" src="https://img.shields.io/badge/Rust-2021-000000?style=flat-square&logo=rust&logoColor=white">
  <img alt="SwiftUI Native" src="https://img.shields.io/badge/SwiftUI-Native-F05138?style=flat-square&logo=swift&logoColor=white">
  <img alt="macOS 14+" src="https://img.shields.io/badge/macOS-14%2B-000000?style=flat-square&logo=apple&logoColor=white">
  <a href="https://github.com/semantic-craft/koe/actions/workflows/ci.yml"><img alt="CI" src="https://img.shields.io/github/actions/workflow/status/semantic-craft/koe/ci.yml?branch=main&style=flat-square&label=CI"></a>
  <a href="assets/licenses/soundcore.txt"><img alt="Upstream license: MIT" src="https://img.shields.io/badge/Upstream_license-MIT-blue?style=flat-square"></a>
</p>

<p align="center"><strong>简体中文</strong> · <a href="README.en.md">English</a></p>

安克 **soundcore Work（D3200）** 是一枚硬币大小、自带硬件加密与实体双击手势的领口录音豆，但原厂流程把录音锁在飞书或厂商云端账号里。**Koe 把 D3200 和你每天的 Mac 会议直接带回本机磁盘。**

Koe 采用纯 Rust 内核（8 个 crate 中有 6 个开启 `#![forbid(unsafe_code)]`）配薄层原生 SwiftUI macOS 宿主，统一接管蓝牙协议、音频落盘校验、引用门禁与单写者存储。即使**完全离线、不填任何云端 API Key**，BLE 加密同步、本机语音识别（`SenseVoice Small`、`Qwen3 ASR 0.6B` 或 macOS 26 `SpeechAnalyzer`）、双路回放、逐句修订与 `<5 ms` 的 BM25 全库检索都能立刻使用。

<div align="center">
<table>
  <tr>
    <td align="center" width="25%" valign="top">
      <img src="assets/product/guide_connect_device.webp" width="120" alt="BLE GATT 直连"><br>
      <sub><strong>1. BLE 直连免配对</strong><br>直连 GATT <code>020cf5da-...</code>，不占系统经典蓝牙，耳机保持立体声 A2DP，免飞书与安克登录。</sub>
    </td>
    <td align="center" width="25%" valign="top">
      <img src="assets/product/guide_wear.webp" width="120" alt="领口佩戴与一键切源"><br>
      <sub><strong>2. 全天佩戴与一键切源</strong><br>支持领口连续听记或单击闪记，今天页音源条支持一键切换为已连闲置录音豆。</sub>
    </td>
    <td align="center" width="25%" valign="top">
      <img src="assets/product/guide_mark.webp" width="120" alt="正面双击与敲击门控"><br>
      <sub><strong>3. 正面双击与敲击降噪</strong><br><code>20 ms</code> 精度记录双击书签或启停听写，自动切除开头 <code>60 ms</code> 与结尾 <code>240 ms</code> 外壳敲击声。</sub>
    </td>
    <td align="center" width="25%" valign="top">
      <img src="assets/product/guide_sync.webp" width="120" alt="落盘校验与删档保护"><br>
      <sub><strong>4. 校验落盘才删豆内文件</strong><br>本机完成 <code>fsync</code> 并签发 64 位 SHA-256 <code>CustodyReceipt</code> 后，内核才放行 <code>0x1A/0x10</code> 删档指令。</sub>
    </td>
  </tr>
</table>
</div>

## 一天一页，四种日常工作区

打开 Koe，首页四宫格围绕「今天正在录什么、过去原话怎么说、接下来要做什么」组织，会话启停与进入页面彻底解耦，切换侧栏不会打断正在进行的录音。

| 工作区 | 适用场景 | 实际工作流 |
| --- | --- | --- |
| **随心闪记**（默认） | 灵感、临时交代、书单备忘 | 按下录音豆或快捷键默认落入闪记收件箱，保留原始时间戳并支持归入项目；AI 提炼与转写原文并排展示，绝不改写你说过的原话。 |
| **全天听记** | 领口全天连续佩戴 | 自动按 5 分钟封段保存，前一段后台生成摘要与待办时当前段继续录音不断流；按墙钟合并同批事件，在单调时间线上如实标出暂停与未录音空档，供日终集中复查。 |
| **实时纪要** | 线上或线下会议、访谈 | 通过 CoreAudio `CATapDescription` 同步录制 **Mac 系统声音与麦克风双路音轨**，戴耳机开会也能录齐双方声音；满 3 句或 20 秒出首版议题，后续按 45 秒防抖滚动刷新且不叠加并发请求，停录封口后单次提取待确认行动项。 |
| **语音输入** | 任意应用光标处听写 | 通过本机 `koe.sock` 将干净语音流与双击边沿桥接给 Responsay 等外部输入法，内置六步联动自检与跨重连代次的光标测试框，Koe 与输入法不重复识别同一段声音。 |

四种采集模式共用同一份本地资料库，并受三条硬规则约束：

- **每一条摘要与待办都能点回原话。** 纪要、待办、个人记忆与问答结果统一绑定 `record_id + segment_id` 复合引用，点击即可跳回对应句段并拖动回放。人工修订转写时自动锁存 `original_text` 供一键恢复原文，同时将旧纪要标为待重算；Rust 引擎层的 `validate_minutes_grounding` 会直接打回缺引用、越界引用或捏造数字与词表纠错的生成结果。
- **无大模型也能在 5 ms 内检索 40 万字语料。** 内置中文双字切分与英文词项 BM25 倒排索引，单测在 16,000 句、40 万字符语料上检索耗时低于 `5 ms`。未配置文字模型时，「问 Koe」离线直接返回带 `[S1]`、`[S2]` 编号的原话摘录；语料中缺乏依据的问题在本地直接短路拒答，不消耗 Token 也不编造结论。
- **可逆的 30 天回收站、归档锁与开放进出。** 支持导入 WAV、UTF-8 TXT、Markdown 与自包含音频及元数据的 `.koepack` 资料包，并支持自定义字段导出标准 Markdown。归档记录锁定防改防删；软删除进入 30 天回收站并提供 8 秒即时撤销条；彻底清除采用两阶段提交，必须在元数据事务落盘后才删除磁盘上的 `.wav` 与 `.opus` 文件。

## 把硬件协议与原生性能做到位

Koe 在纯 Rust 与原生 macOS 适配层处理蓝牙分片、高频采样与系统权限边界，避免跨层胶水拖慢桌面日常运行：

- **纯 Rust D3200 密码学与 `166 * N` 分片精准续传。** `koe-engine` 在零 `unsafe` 环境下完成临时 NIST P-256 ECDH 密钥协商（`0x2E/0x01`）、RFC 5869 HKDF-SHA256 会话派生、`soundcored3200` 文件密钥校验与基于预计算 T-table 的零分配 AES-256-CTR 流式解密。离线拉取严格对齐 166 字节分片（4 字节序号、1 字节标志、160 字节 `20 ms` Opus 帧与 1 字节分隔），断线重连按 `已收分片数 * 166` 精准续传并配 5 秒无响应看门狗。源码静态编译的 `libopus 1.5.2` 同步解出 `16 kHz` 单声道 PCM16 供识别与 `48 kHz` 音轨供回放，同时封装标准 RFC 7845 Ogg Opus 归档（`koe-cli benchmark` 实测解密、解码并封装 `10,000` 包耗时 `75.07 ms`）。
- **分域 `@Observable` 切片与 `1,314x` 离屏布局门控（`v2.1.0`）。** 二进制采样接口 `koe_host_session_ingest_pcm` 直接传递 `const int16_t *` 指针并按 `250 ms` 批次合并投影，将双路 `48 kHz` 采集 20 拍的全量快照广播从 `323` 次压至 `23` 次，采集 CPU 中位数降低 `81.15%`（`696.66 ms` 降至 `131.30 ms`）。Swift 侧将 `HostSessionStore` 拆分为 21 个 `Equatable` 领域切片，由 `scripts/verify-ui-principles.py` 静态拦截非叶子视图越权读取 4 Hz 状态，用 50 ms 防抖的 CoreAudio HAL 属性监听替代主线程每秒轮询，并在主窗口关闭或最小化时冻结离屏 `NSHostingView.layout()`，使关窗后台播放 40 拍耗时从 `307.60 ms` 降至 `0.23 ms`（提速 `1,314.5x`，离屏重排从 `40` 次降至 `0` 次）。
- **无感 `-100 dBFS` Barker-13 系统音频权限探针。** macOS 未提供 CoreAudio 系统音频 tap 的公开授权回调，`AudioDeviceStart` 被拒时仅静默返回全零缓冲。Koe 在授权探测期向默认输出端注入人耳不可闻的 `-100 dBFS` Barker-13 序列并配合系统权限弹窗检测，仅在弹窗关闭且仍无非零回环时判定被拒；双路采集中任一路失败都会保留另一路已录音频。
- **抗崩溃 `.capture` 落盘、`RequestKey` 防重扣费与两阶段 Keychain。** 麦克风录音直接写入 `<id>.capture`，每收到音频块即回写偏移量 0 处的 44 字节 WAV 头并执行 `sync_data()`，意外退出后重启自动校验并硬链恢复为正式 `.wav`。云端请求发送前先持久化 `RequestKey(record_id, attempt, input_revision)`，中断重启后统一标为 `Interrupted` 等待手动重试，绝不后台静默重发扣费。`meeting_audio_policy` 默认锁定 `LocalOnly`；签名版写入 macOS Keychain 前先在磁盘登记两阶段 `pending_credentials` 引用，启动时按精确 UUID 回收提交前崩溃孤儿项，且绝不读取 `.env` 或 `.envrc`。

> **硬件通道说明。** [PROTOCOL.md](PROTOCOL.md) 同时记录了逆向观测到的 Wi-Fi SoftAP 快传、经典蓝牙 SPP、固件 OTA、设备对时与绑定命令。这些通道在 Koe 当前版本**刻意未接入**，设备通信全部通过 BLE GATT 完成，固件升级仍由厂商应用负责。

## CLI 与 MCP

Koe 运行时在容器目录内开放属主私有的 Unix Socket（`.koe` 目录权限 `0700`，`koe.sock` 权限 `0600`，经 `getpeereid` 校验同用户 UID）。CLI 与外部 AI Agent 在应用打开时直连同一活体 `KoeRuntime`，应用关闭后自动回退文件锁直开工作区，全程保持单写者一致性：

```bash
cargo run --package koe-cli -- status
cargo run --package koe-cli -- search "产品决定"
cargo run --package koe-cli -- ask "接下来要做什么"
cargo run --package koe-cli -- mcp-stdio
cargo run --package koe-cli -- companion-listen
```

- **16 项 MCP stdio 工具。** 按需投影并提供全文检索、今日简报、记录列表与详情、带来源问答、待办与记忆审核及完成、新建笔记、分段批注、转写修订、说话人改名合并、归档与回收站恢复、D3200 状态控制与代次轮询。**按设计不向 Agent 暴露彻底清除接口**，防止不可逆删库。
- **本机输入法文字与音频桥。** 通过 [本地文字桥协议](docs/local-text-bridge.md) 输出 `transcript_final` 定稿事件、`control_edge` 物理双击边沿与 `external_pcm_v1` 独占租约音频流，供 Responsay 等外部输入法直接消费干净的 `16 kHz` `PCM16` 语音。

## 构建与安装

构建需 macOS 14+（系统音频双路采集需 macOS 14.2+，Apple 本机识别需 macOS 26+）、Xcode Command Line Tools（Swift 5.10+）、Rust 1.85+ 与 CMake。`libopus 1.5.2` 从仓库锁定的源码静态编译，无需预先安装外部音频库。

```bash
# 编译 C ABI 静态库与原生 macOS 宿主
cargo build --package koe-host-api
swift build --package-path platforms/macos

# 打包并以 Developer ID 签名安装至 /Applications/Koe.app，自动执行 --verify-self 与 --smoke-test
./scripts/install-macos.sh

# 本地开发门禁：快速增量校验与全量测试套件
./scripts/verify-local.sh --quick
./scripts/check
```

## 四层架构与文档

Koe 严格按四层单向依赖组织代码，C ABI 固定为 `KOE_HOST_API_VERSION = 2` 并通过 `catch_unwind` 隔离跨语言异常；门禁脚本强制限制 `platforms/` 下每个 `.swift` 文件及 `crates/koe-host-api/src/lib.rs` 不超过 500 行。

| 层级 | 目录 | 职责边界 |
| --- | --- | --- |
| 第一层 Engine | [koe-engine](crates/koe-engine/)、[koe-opus](crates/koe-opus/) | 无 I/O 协议与领域状态机：D3200 加解密与分片对齐、采集排序、纪要证据门禁、待办/记忆审核、BM25 与静态 `libopus` 封装 |
| 第二层 Client | [koe-client-base](crates/koe-client-base/)、[koe-client-providers](crates/koe-client-providers/)、[koe-client-services](crates/koe-client-services/) | 防符号链接原子写与文件锁、真实 HTTPS/WebSocket 流式请求与本机离线模型线程、单写者 `ProductStore` 与音频资产保管 |
| 第三层 Runtime & Host API | [koe-runtime](crates/koe-runtime/)、[koe-host-api](crates/koe-host-api/) | 会话编排、`RequestKey` 持久化事务、二进制采样快路径、不可变 `generation` 快照与 `.koe/koe.sock` 本地桥 |
| 第四层 Native Hosts & CLI | [apple-shared](platforms/apple-shared/)、[macos](platforms/macos/)、[koe-cli](crates/koe-cli/) | SwiftUI 分域切片视图、CoreBluetooth、CoreAudio 双路采集与 HAL 监听、Keychain 适配及 CLI/MCP 入口 |

延伸阅读：[架构与状态所有权](docs/ARCHITECTURE.md) · [D3200 协议逆向笔记](PROTOCOL.md) · [四模式工作区定义](docs/mode-workspaces.md) · [本地文字桥协议](docs/local-text-bridge.md) · [v2.1.0 发行说明](docs/releases/v2.1.0.md) · [路线图](ROADMAP.md) · [贡献指南](CONTRIBUTING.md) · [安全策略](SECURITY.md) · [第三方组件与署名](THIRD_PARTY_NOTICES.md)。

## 开源致谢

Koe 在独立实现的 Rust 与 SwiftUI 代码底座上吸收了多个开源项目的架构与工程思路，并在仓库中完整保留上游署名与许可记录：

| 项目 | 启发来源 | Koe 中的落地实现 |
| --- | --- | --- |
| **[msime](https://github.com/metasequoiaime/msime)** | 纯 Rust 内核配全原生 Apple 宿主的四层分离 | 以 C ABI v2、不可变 `generation` 快照与属主私有 `koe.sock` 让桌面端、CLI 与 MCP 共用同一运行时 |
| **[tacshi/Soundcore](https://github.com/tacshi/Soundcore)** | 安克 D3200 BLE 协议逆向文档与 Dart 实现 | 移植为零 `unsafe` 纯 Rust 状态机，按实测 166 字节记录对齐 `166 * N` 断点续传并解析双击与遥测标志 |
| **[BasedHardware/omi](https://github.com/BasedHardware/omi)** | 穿戴设备断线 WAL 托管与审核确认卡 | 将 `CustodyReceipt` 设为 `0x1A/0x10` 硬件删档硬前置锁，把三态审核接入单写者存储与 16 项 MCP 工具 |
| **[screenpipe](https://github.com/screenpipe/screenpipe)** | 时间轴上下文聚合与全局实时字幕条 | 由 Rust `SpeechSession` 快照直接驱动 `LiveCaptionBar`，统一录音豆与 Mac 麦克风实时字幕 |
| **[TaoSheng（涛声）](https://github.com/0xCoach/TaoSheng)** | 全天分段记忆、多模式工作区、引用重标与乐观锁 | 落地四模式工作区、5 分钟无阻塞分段、`RequestKey` 防过期覆盖与 `relabel_citations` 引用重排 |
| **[Shiyin（拾音）](https://github.com/juinwei7/Shiyin)** | CoreAudio 麦克风与系统音频采集及结构化纪要 | 结合 `-100 dBFS` Barker-13 探针与系统弹窗检测判定授权，由 Rust 统一对齐双路稀疏时间轴与暂停代次 |
| **[Meetily](https://github.com/Zackriya-Solutions/meetily) & [Ownscribe](https://github.com/paberr/ownscribe)** | 议题/决策/行动项结构化约束与反编造规则 | 在引擎层执行确定性 `validate_minutes_grounding` 校验，拦截缺引用、越界分段号与无依据的数字或词表修订 |
| **[transcribe.cpp](https://github.com/anomalyco/transcribe.cpp) & [Hex](https://github.com/anomalyco/hex)** | 静态嵌入式 CPU 离线识别与锁定模型清单 | 进程内运行 SenseVoice Small（约 253 MB）与 Qwen3 ASR 0.6B（约 850 MB），流式校验 SHA-256 后原子落盘 |
| **[vecta](https://github.com/nitishagar/vecta) & Cicada** | 符号链接越界防护与实时滚动纪要节奏 | 读写前执行 `reject_symlink_path` 校验，落地 3 句/20 秒首发、45 秒防抖纪要调度与本机输入法桥接 |

## v2.1.0 验证现状与边界

我们严格区分「已完成门禁与实包验证」「合入主线待物理硬件核对」与「下一阶段规划」三类状态：

| 状态 | 覆盖范围 |
| --- | --- |
| **已交付并完成验证（`v2.1.0` 构建 `10`）** | Rust 8-crate 内核、通过 Apple Notary 公证的 Developer ID `arm64` 安装包、正式四大 SwiftUI 工作区、CoreAudio `CATapDescription` 双路采集、离线 GGUF 与 macOS 26 `SpeechAnalyzer` 本机识别、分域 `@Observable` 切片与二进制 PCM FFI、BM25 检索与纪要证据门禁、16 项 MCP 工具，以及 `/Applications/Koe.app` 本机覆盖升级保留工作区与 Keychain 凭据验证。 |
| **已合入主线，追踪物理硬件核对（`ready-for-human`）** | 今天页音源状态条与一键切换录音豆实机核对（[#722](https://github.com/semantic-craft/koe/issues/722)）、关窗离屏态实体 D3200 按键唤醒与外接耳机热插拔核对（[#725](https://github.com/semantic-craft/koe/issues/725)），以及 Responsay 侧物理快捷键联调核对（[Responsay #822](https://github.com/semantic-craft/responsay-macos/issues/822)）。 |
| **下一阶段规划（`2.1.0` 未接入）** | iOS 与 Android 移动宿主及双端同步（[#124](https://github.com/semantic-craft/koe/issues/124)、[#149](https://github.com/semantic-craft/koe/issues/149) 至 [#151](https://github.com/semantic-craft/koe/issues/151)）、外部 AI 委派协作（[#152](https://github.com/semantic-craft/koe/issues/152) 至 [#155](https://github.com/semantic-craft/koe/issues/155)）、Wi-Fi SoftAP 快传、固件 OTA、基于静音的 VAD 动态切段与本机离线声纹聚类。 |

## 许可证

D3200 协议逆向文档与 Rust 移植实现源自 [tacshi/Soundcore](https://github.com/tacshi/Soundcore)（MIT License，Copyright (c) 2026 Rocky Shi），完整许可正文见 [soundcore.txt](assets/licenses/soundcore.txt)；其余参考项目、模型与依赖许可说明见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

本仓库目前保持私有，暂不公开发布。Cargo 元数据中的 MIT 字段不替代第三方组件的独立许可证；签名版安装包会在 `Koe.app/Contents/Resources/Licenses/` 目录随包附带完整署名与许可正文。
