<h1 align="center">Koe</h1>

<p align="center"><strong>把安克 soundcore Work（D3200）录音豆与日常会议记录，彻底拿回本地掌控。</strong></p>
<p align="center"><em>纯 Rust 领域与协议内核 + 原生 SwiftUI macOS 宿主，集硬件直连、离线识别、可溯源纪要与 MCP 于一体。</em></p>

<p align="center">
  <img alt="Rust" src="https://img.shields.io/badge/Rust-2021-000000?style=flat-square&logo=rust&logoColor=white">
  <img alt="SwiftUI" src="https://img.shields.io/badge/SwiftUI-5.10%2B-F05138?style=flat-square&logo=swift&logoColor=white">
  <img alt="macOS 14+" src="https://img.shields.io/badge/macOS-14%2B-000000?style=flat-square&logo=apple&logoColor=white">
  <a href="https://github.com/semantic-craft/koe/actions/workflows/ci.yml"><img alt="CI" src="https://img.shields.io/github/actions/workflow/status/semantic-craft/koe/ci.yml?branch=main&style=flat-square&label=CI"></a>
  <img alt="Upstream license: MIT" src="https://img.shields.io/badge/Upstream_license-MIT-blue?style=flat-square">
</p>

<p align="center"><strong>简体中文</strong> · <a href="README.en.md">English</a></p>

安克 soundcore Work（D3200）是一颗做工紧凑、带本地加密和实体手势的录音豆。Koe 让它脱离飞书与云端账号，直接在 macOS 上运行，将硬件取回、音频处理、个人记忆与会议整理收拢进同一套本地优先桌面应用。

**Koe 的工程灵感来自多个优秀的开源项目，并在统一底座上形成了自己的设计取向。** 我们用纯 Rust 内核管理协议、音频资产、离线检索、证据校验与状态持久化，用原生 SwiftUI 呈现「一天一页」的界面。哪怕不配任何云端 API Key，录音、离线转写、播放、修订与本地检索也能照常工作。

## 四种工作区与日常流程

打开 Koe，产品围绕「今天在录什么、过去聊过什么、接下来要做什么」展开，侧栏切换页面不会打断正在进行的采集。

| 工作区模式 | 适用场景 | 实际解决的问题 |
| --- | --- | --- |
| **随心闪记**（默认） | 灵感、临时交代、待看书单 | 按下录音豆或快捷键默认进入闪记，原文进收件箱并保留原始时间戳，AI 分析独立展示，绝不覆盖你说过的原话。 |
| **全天听记** | 连续佩戴一整天 | 自动按 5 分钟封段保存为独立记录，前一段在后台生成纪要和待办时，当前段照常录音不断流；时间线真实保留暂停与未录音空档。 |
| **实时纪要** | 正在进行的会议或访谈 | 宽屏左右对照原文与纪要，窄屏标签切换；首次满 3 句或等满 20 秒触发首版整理，后续按 45 秒防抖滚动更新且不叠加并发请求；停录封口后才一次性生成待确认行动项，避免中途刷出重复待办。 |
| **语音输入** | 任何软件的光标处听写 | 把 D3200 当成高便携领口麦，通过本机 Unix Socket 文字桥接外部输入法，由输入法完成润色与上屏，Koe 与输入法不重复识别同一段声音。 |

除了四种采集入口，日常整理与回溯围绕三项硬规则运行：

- **每一句摘要和待办都必须能点回原话。** 纪要条目、待办事项、个人记忆与问答结果统一绑定 `record_id + segment_id` 复合引用。点一下来源直接跳回对应录音片段并支持音频拖动回放；编辑转写文字时，系统自动锁存 `original_text` 方便一键「恢复识别原文」，同时把旧纪要标为过期提醒重算。
- **没有大模型也能问全库。** 内置基于中文双字切分与英文词项的 BM25 倒排索引，单测验证在 16,000 句、40 万字符语料上检索耗时低于 5 ms。未配置文字模型时，「问 Koe」直接返回带 `[S1]`、`[S2]` 编号的原话摘录；语料中找不到根据的问题在本地直接短路拒答，不浪费 Token 也不硬编答案。
- **删改克制，支持完整进出。** 支持导入 WAV、UTF-8 TXT、Markdown 与自包含元数据及音频的 `.koepack` 资料包，也可导出标准 Markdown。已归档记录锁定防误删与防编辑；软删除进入 30 天回收站并弹出 8 秒即时撤销条；彻底清除采用两阶段提交，必须先进入回收站，且元数据事务落盘后才删除磁盘上的 `.wav` 与 `.opus` 文件。

## 充分发挥 Anker soundcore Work（D3200）硬件能力

在 Koe 里，D3200 不只充当普通麦克风。我们在纯 Rust 内核里完整实现了它的私有 BLE 协议与音频管线，把硬件本身的加密、断点续传和手势能力都带进桌面日常：

1. **免系统配对、免飞书与免厂商云鉴权。** Mac 通过 CoreBluetooth 扫描 D3200 服务 UUID `020cf5da-0000-1000-8000-00805f9b34fb` 直连控制与通知通道，不走系统经典蓝牙绑定，也不经过 Anker 云端鉴权服务器；发送队列内置 300 ms 节流与分包切片，保证长包下发稳定。
2. **全套 NIST P-256 ECDH 与 AES-256-CTR 硬件加密解密。** 在 `#![forbid(unsafe_code)]` 的纯 Rust 引擎内完成临时 P-256 密钥协商、RFC 5869 HKDF-SHA256 会话密钥派生、`soundcored3200` 文件密钥前缀验证，以及基于预计算 T-table 的 AES-256-CTR 零分配流式解密。
3. **双路编码同步输出与 166 字节分片精准续传。** 针对上游协议在断线重连时的偏移错位问题，Koe 按实际 166 字节分片记录实现 `已收分片数 * 166` 精准断点续传。每片固定包含 4 字节序号、1 字节标志、160 字节 20 ms Opus 帧与 1 字节分隔，配合 5 秒无响应看门狗自动重拉。底层静态链接源码编译的 `libopus 1.5.2`，同时解码出 16 kHz 单声道 PCM16 供实时转写使用，以及 48 kHz 音轨供回放预览，并将原始 Opus 帧封装为标准 RFC 7845 Ogg Opus 归档。
4. **先本地落盘核对 SHA-256，才允许删除硬件录音。** 借鉴穿戴设备托管机制，Koe 对每个拉取的文件签发包含字节数与 64 位 SHA-256 的 `CustodyReceipt`。除非本地 `.opus` 文件已经完成 `fsync` 落盘且校验通过，内核硬拒绝发出 `0x1A/0x10` 删除命令，从根本上杜绝传输中断导致的录音永久丢失。
5. **正面双击打点与「防敲击咚咚声」物理门控。** 实时解析分片标志位 `flags & 0x01`，以 20 ms 精度把录音豆正面的双击动作记录为时间书签，或触发领口伴侣控制边沿。针对轻敲外壳不可避免产生的低频敲击声，Koe 在开始双击后跳过前 3 个分片即 60 ms，在结束双击时扣留并丢弃最后 12 个分片即 240 ms，再把干净的 `16 kHz` `PCM16` 流通过本地桥递给外部输入法。临时待命产生的豆内缓存文件在空闲时自动回收，用完也可通过 `releaseControl` 彻底交出蓝牙控制权，方便手机随时接管。

> **硬件通道现状说明。** [PROTOCOL.md](PROTOCOL.md) 中也记录了逆向所得的 Wi-Fi SoftAP 快传、经典蓝牙 SPP、固件 OTA、时间同步与设备绑定命令，但这些通道目前**尚未接入** Koe，当前全部通过 BLE GATT 完成传输且不负责固件升级。长文件云端拉取、领口待命功耗与蓝牙耳机热插拔共存正在对应真机工单中持续验收。

## 设计理念与开源致谢

在设计 Koe 时，我们围绕四条原则组织整个应用：

- **纯音频与低打扰。** 专注语音采集、转写、回顾与行动，保持日常桌面运行轻量安静。
- **本机单写者真相源。** 音频资产、逐字稿与审核结果以本地磁盘文件为唯一真相源；修订转写时保留 `original_text`，AI 纪要与问答只做引用叠加，不改写你说过的原话。
- **把硬件细节带进桌面日常。** 从加密链路、分片续传到物理双击与敲击降噪，让录音豆的每一项硬件能力都有直接的软件配合。
- **克制、可接线的工具边界。** 通过私有 Unix Socket 与 MCP 对接外部输入法与 AI Agent，让润色上屏、跨库检索和工具协作各司其职。

Koe 的架构与诸多细节都受益于开源社区的多个项目。我们在代码中保留完整署名，并把各家所长结合进同一套 Rust 与 SwiftUI 实现：

| 参考项目 | 启发 Koe 的灵感 | 在 Koe 中的工程落地与延伸 |
| --- | --- | --- |
| **[msime](https://github.com/metasequoiaime/msime)** | 纯 Rust 内核 + 全原生 Apple 宿主的四层分离架构 | 通过版本化 C ABI v2 与 `catch_unwind` 隔离 panic，SwiftUI 只渲染带单调 `generation` 的不可变快照，并补出私有 Unix Socket 桥让 App、CLI 与 MCP 共享同一活体状态 |
| **[tacshi/Soundcore](https://github.com/tacshi/Soundcore)** | 安克 D3200 BLE 协议逆向文档与 Dart 实现 | 完整移植为内存安全的纯 Rust 状态机，按实测 166 字节分片对齐 `166 * N` 断点续传，并解析双击标志与状态遥测 |
| **[BasedHardware/omi](https://github.com/BasedHardware/omi)** | 穿戴设备断线托管 WAL 与待办/记忆确认卡 | 把托管凭证做成硬性删档前置锁，将 `Proposed / Accepted / Dismissed` 三态审核接入本地单写者账本与 16 项 MCP 工具 |
| **[screenpipe](https://github.com/screenpipe/screenpipe)** | 按时间轴聚合上下文与全局实时字幕条 | 让 `LiveCaptionBar` 直接由 Rust `SpeechSession` 状态快照驱动，麦克风与录音豆采集同源刷新 |
| **[TaoSheng（涛声）](https://github.com/0xCoach/TaoSheng)** | 全天分段记忆、多模式工作区、问答引用自愈与并发乐观锁 | 落地四模式工作区、5 分钟分段流水线、`RequestKey` 防过期覆盖与 `relabel_citations` 引用重标 |
| **[Shiyin（拾音）](https://github.com/juinwei7/Shiyin)** | CoreAudio 麦克风与系统音频采集、结构化纪要模板 | 配合 `-100 dBFS` Barker-13 无感探测信号与弹窗检测判定 macOS 系统音频授权，并由 Rust 统一管理双路稀疏时间轴与暂停代次 |
| **[Meetily](https://github.com/Zackriya-Solutions/meetily) & [Ownscribe](https://github.com/paberr/ownscribe)** | 议题/决策/行动项 JSON 结构与严格事实约束 | 在 Rust 引擎层加装 `validate_minutes_grounding` 确定性门禁，缺原文引用、引用越界或找不到原始听写词的纠错条目直接打回 |
| **[transcribe.cpp](https://github.com/anomalyco/transcribe.cpp) & [Hex](https://github.com/anomalyco/hex)** | 静态嵌入式离线 ASR 与模型校验清单 | 在 Rust 进程内托管 SenseVoice Small（约 253 MB）与 Qwen3 ASR 0.6B（约 850 MB），流式校验 SHA-256 后原子发布，中断时由 RAII 自动清理残片 |
| **[vecta](https://github.com/nitishagar/vecta) & Cicada** | 文件路径安全校验与实时滚动纪要节奏 | 移植 `reject_symlink_path` 防符号链接越界读写，落地 3 句/20 秒首发、45 秒防抖的增量纪要调度与双栏视图，并通过本地文字桥对接外部输入法 |

## 工程上的可靠性与隐私边界

真正决定一款录音工具能不能长期放心用，往往不是新功能有多少，而是出意外时它怎么收拾残局：

- **录音写盘崩溃找回。** Mac 麦克风录音直接向 `<id>.capture` 增量落盘，每收到音频块就回写偏移量 0 处的 44 字节 WAV 头并调用 `sync_data()`。即使应用意外强退，下次启动自动校验波形并硬链恢复为正式 `.wav`，元数据提交成功前不删除暂存文件。
- **macOS 系统音频权限的物理级探针。** Apple 没有提供查询 CoreAudio 系统音频 tap 授权的公开回调，调用 `AudioDeviceStart` 被拒时往往只返回数字静音。Koe 在授权检测期间向默认输出端注入一段人耳不可察觉的 `-100 dBFS` Barker-13 探测序列，同时扫描屏幕是否有系统权限弹窗，只有弹窗消失后仍收不到非零探测回环才判定被拒。
- **绝不静默重复扣费。** 每次云端任务先登记 `RequestKey(record_id, attempt, input_revision)` 再发请求。一旦中途断网或重启，未完成任务统一转入 `Interrupted` 状态，等待用户检查配置后手动重试，不会在后台默默替你重发付费请求。
- **音频默认不离本机与两阶段凭据提交。** `meeting_audio_policy` 默认锁定 `LocalOnly`，本机识别引擎不可用时绝不擅自切换云端。签名版 API Key 存入 macOS Keychain 时采用先登记 `pending_credentials` 到磁盘、再写 Keychain、最后退休旧引用的两阶段提交；半路崩溃留下的孤儿项会在下次启动按精确引用回收，清除凭据后写入墓碑防止旧版密钥复活。开发构建与签名版凭据彻底隔离，绝不偷读个人 `.env` 或 `.envrc`。
- **内存安全与严格的模块边界。** Cargo 工作区开启 `unsafe_code = "deny"`，8 个 Rust crate 中有 6 个在根部加上 `#![forbid(unsafe_code)]`，仅 `koe-opus` 与 `koe-host-api` 两个 FFI 边界模块允许封装外部接口。静态构建 `libopus` 并禁用系统库探测；Swift 源码受门禁脚本卡死单文件不超过 500 行，禁止业务规则或状态字段渗透到界面层。

## CLI 与 MCP

Koe 启动后会在沙盒容器内开放属主私有的 Unix Socket，其中 `.koe` 目录权限为 `0700`、套接字权限为 `0600`，并通过 `getpeereid` 核对同用户 UID。命令行与外部 AI Agent 在 Koe 运行时实时接入同一套 `KoeRuntime` 会话，关闭后回退文件锁直开工作区，全程保持单写者一致性：

```bash
cargo run --package koe-cli -- status
cargo run --package koe-cli -- search "产品决定"
cargo run --package koe-cli -- ask "接下来要做什么"
cargo run --package koe-cli -- mcp-stdio
cargo run --package koe-cli -- companion-listen
```

- **MCP stdio 服务（16 项工具）。** 开放全文检索、今日简报、记录列表与详情、带来源问答、待办/记忆审核与完成、新建笔记、原文分段批注、转写修订与说话人管理、归档与回收站恢复、D3200 设备状态与控制及代次轮询。**刻意不向 Agent 暴露彻底清除接口**，避免不可逆删库。
- **外部输入法文字与音频桥。** 通过 [本地文字桥协议](docs/local-text-bridge.md) 订阅 `transcript_final` 定稿事件、`control_edge` 物理双击边沿与 `external_pcm_v1` 独占租约流，供第三方语音输入法直接消费 D3200 的干净录音。

## 构建与运行

环境要求为 macOS 14+、Xcode Command Line Tools（Swift 5.10+）、Rust 工具链（1.85+）与 CMake。Opus 从锁定的依赖源码静态编译，无需在本机预先安装 `libopus`。

```bash
# 编译 C ABI 产物与原生 macOS 宿主
cargo build --package koe-host-api
swift build --package-path platforms/macos

# 打包并使用 Developer ID 签名安装到 /Applications/Koe.app，自动运行自检与冒烟测试
./scripts/install-macos.sh

# 本地开发校验：快速检查与全量测试门禁
./scripts/verify-local.sh --quick
./scripts/check
```

## 当前边界与诚实清单

我们把做完的、测试通过的、以及尚未在真机或未来版本落地的部分分开交代：

| 状态 | 范围与说明 |
| --- | --- |
| **已实现并通过 CI / 本地门禁** | Rust 8-crate 内核、D3200 BLE 连接/握手/分片续传/托管逻辑、四模式 SwiftUI 工作区、离线 GGUF 与 Apple SpeechAnalyzer（macOS 26+）接入、CoreAudio 双路时间轴与探针代码、BM25 检索与纪要引用门禁、16 项 MCP 工具与本地桥接。 |
| **已实现代码，待真机/实名账号继续验收** | D3200 完整长录音离线拉取叠加付费云转写（[#588](https://github.com/semantic-craft/koe/issues/588)）、领口待命功耗与蓝牙耳机热插拔共存（[#641](https://github.com/semantic-craft/koe/issues/641)）、macOS 系统音频双路真实权限弹窗与输出设备切换听感、常规覆盖升级的 Keychain 静默继承、物理设备与输入法完整日常连跑（[#668](https://github.com/semantic-craft/koe/issues/668)）。 |
| **后续规划（当前未接入）** | iOS / Android 移动宿主、Wi-Fi SoftAP 快传与固件 OTA、基于静音检测的 VAD 动态切段、本机离线声纹聚类、屏幕画面采集、多设备数据同步与外部日历回写。 |

## 架构与文档

| 层级 | 目录 | 职责 |
| --- | --- | --- |
| 领域与协议 | [koe-engine](crates/koe-engine/)、[koe-opus](crates/koe-opus/) | 纯无 I/O 状态机、证据校验、BM25、D3200 协议与密码学、静态 libopus 封装 |
| 客户端服务 | [koe-client-base](crates/koe-client-base/)、[providers](crates/koe-client-providers/)、[services](crates/koe-client-services/) | 防符号链接原子写与文件锁、真实 HTTPS/WebSocket 与离线模型线程、音频资产与单写者存储 |
| 运行时与接口 | [koe-runtime](crates/koe-runtime/)、[koe-host-api](crates/koe-host-api/) | 命令协调、异步队列、持久化事务、C ABI v2 快照与 `.koe/koe.sock` 本地桥 |
| 原生宿主与工具 | [apple-shared](platforms/apple-shared/)、[macos](platforms/macos/)、[koe-cli](crates/koe-cli/) | SwiftUI 页面、CoreBluetooth、CoreAudio、Keychain 适配与 CLI/MCP 入口 |

更多设计文档：[架构与状态所有权](docs/ARCHITECTURE.md) · [D3200 协议逆向笔记](PROTOCOL.md) · [四模式工作区定义](docs/mode-workspaces.md) · [本地文字桥协议](docs/local-text-bridge.md) · [路线图](ROADMAP.md) · [贡献指南](CONTRIBUTING.md) · [安全报告](SECURITY.md) · [第三方组件与署名](THIRD_PARTY_NOTICES.md)。

## 许可证

D3200 协议逆向文档与移植实现继承自 [tacshi/Soundcore](https://github.com/tacshi/Soundcore)（MIT License，Copyright (c) 2026 Rocky Shi），完整许可见 [soundcore.txt](assets/licenses/soundcore.txt)，其余第三方借鉴范围与许可正文见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

仓库目前保持私有，暂不公开发布。Cargo 元数据中的 MIT 字段不替代第三方组件的独立许可；macOS 安装包会在 `Koe.app/Contents/Resources/Licenses/` 内附带完整说明与许可正文。
