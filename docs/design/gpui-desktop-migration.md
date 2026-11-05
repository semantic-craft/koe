# Koe 桌面 Rust 与 GPUI 迁移

本设计只定义桌面迁移。手机实现、已有安装、个人资料和凭据保持原有所有权。R1 提供显式打开 `.koepack` 的只读核心，不能据此宣称桌面替换完成。

## 当前边界与功能保全

Flutter 的 `RecorderController` 将资料、设备、转写、会议与个人记录接在一起。可交换边界是 `MaterialPack`，并不是整个应用目录。`lib/state/material_pack.dart:61` 输出 manifest，`:534` 写 framing，`:614` 的现有导入器会解出音频。Rust 不调用这个导入器，只读显式传入的包。

| 现有能力与代码入口 | 存储或平台边界 | 迁移要求与当前状态 |
| --- | --- | --- |
| 资料、原件、回收站，`lib/state/recording_library.dart`、`lib/state/recorder/library.dart` | 应用资料目录、原音频身份与路径 | R1 只读交换包；旧库扫描、补缺与冲突处理未迁移 |
| 正文、校订、时码、发言人、译文、书签，`lib/state/recording.dart`、`lib/state/recording_bookmarks.dart` | JSON 持久化、原声定位 | R1 保全全部 manifest，提供正文和有效发言人投影；编辑、播放与回写未迁移 |
| 结构纪要、历史、出处、术语采纳，`lib/state/meeting_minutes.dart`、`recording_analysis.dart` | 来源快照、版本历史、任务状态 | R1 保留结构与凭证，检查封套、版本和引用；生成、编辑、恢复未迁移 |
| BLE、Wi-Fi、取回、实体键、暂停续录，`lib/ble`、`lib/wifi`、`lib/state/recorder/device*.dart` | D3200、配对、加密、后台生命周期 | 不因桌面阅读切片移除，后续单独迁移与硬件验收 |
| 麦克风、系统声音、全天监听、本机识别、实时字幕与纪要，`lib/platform`、`lib/state/recorder/live*.dart` | macOS 音频与授权、模型、窗口 | R1 未接入；后续需保留暂停恢复与真实会议验收 |
| 云端转写、任务恢复、问答、同传，`lib/ai`、`lib/state/recorder/transcription_jobs.dart`、`interpreting.dart` | 服务凭据、网络、付费任务与音频路由 | R1 无网络和凭据 API；后续保持未知请求不自动重发 |
| 今日、项目、待办、地点、日记、主题，`lib/state/context`、`lib/state/recorder/topics.dart` | 多个 JSON 存储、系统日历与位置权限 | 包内已有字段保全；整库功能未迁移 |
| 手机到 Mac 归档、导出、只读 MCP，`lib/archive`、`tools/koe-mcp` | 归档配对、目录、导出快照 | 不接管配对或 MCP；R1 CLI 只读一个指定包 |
| 菜单、快捷键、签名、安装、Keychain，`macos`、`darwin`、`scripts/install-macos.sh` | 应用身份与系统授权 | R1 不构建或替换安装，不触达 Keychain |

ROADMAP 中冻结的 P3、外部交办与双端同步不因迁移自动解冻。已取消的声音克隆不恢复。#548 属于另一会话，既不合并也不接管。

## GPUI Kit 来源与系统版本

2026-11-05 核对 [官方安装文档](https://gpui-kit.com/docs/installation/) 和其链接的 [longbridge/gpui-kit Apache-2.0 许可证](https://github.com/longbridge/gpui-kit/blob/main/LICENSE-APACHE)。官方依赖名为 `gpui-kit`，当前文档示例为 `0.9.0`，由它引入配套 GPUI snapshot，通过 `gpui_kit::*` 使用。不能以近名组件库替代所指定的 Kit。软件及代码示例采用 Apache-2.0，文档说明另采用 CC BY 4.0。R1 core 不依赖界面框架，后续 UI 应单独锁定实际验证的 Kit 版本。

当前官方文档要求 macOS 15+、Rust 1.92+；仓库 `macos/Podfile:1` 和 Xcode deployment target 仍是 macOS 12.0。兼容性尚未解决。不得将旧系统支持静默降低或把尚未构建的兼容方案算成完成。后续需要确定旧系统是否继续使用 Flutter 桌面以及切换规则。

## R1 领域模型与接口

调用方使用 `koe_core::read_pack(reader)`，成功才得到 `ReadingPack`。CLI 使用 `koe-pack inspect PATH`，成功输出一个 JSON 对象，失败向 stderr 写原因并以非零退出。读取不查找应用目录、不读取 Keychain、不写输入、不解出音频。

两种模型经过比较。完整 Rust 类型镜像能提供更多编译期约束，但必须同步所有可选字段，否则 serde 默认丢弃未知字段。R1 采用完整 manifest 加阅读投影，保留未知兼容字段，减少迁移时缩减资料的机会。`title`、`text`、`segments`、`minutes` 是阅读入口；`manifest` 保留原始 JSON 值，包括原文、来源、翻译、地点、主题、书签和纪要历史。并不承诺原始 JSON 的空白、对象键顺序或重复键的字节级往返。

`text` 仅在 `manual` 为缺失或 null 时回退到 `text`。空字符串校订保留。这是与 `PackTranscript.decode` 在 `lib/state/material_pack.dart:351` 丢弃空校订的有意差异，由此次阶段要求决定。片段先应用按序号校订的归属，按有效发言人 ID 与上一片段比较重算 `speakerChanged`，再应用姓名。同名但不同 ID 仍算切换；空归属取消发言人并重置上一发言人，空归属片段自身不标记切换。结束时间可为 null，不能伪造。

解析先检查 `KOEPACK1`、有界长度行、最多 32 MiB manifest、UTF-8 JSON、整数版本 1/2 和必填类型。v1 出现 `minutes` 键即拒绝。附带音频必须有正整数长度、合法扩展名，以及和资料身份一致的 SHA-256。音频以 64 KiB 缓冲逐块校验，截断、摘要不符和多余字节均失败。

纪要保留 `current/history` 原有结构及其中 `text` 字符串。校验当前版与最多 10 版历史的必填类型、日期、来源摘要、schema 1/2、议题/因果图/行动/术语、来源编号、识别变体与采纳凭证。UTF-16 文本长度按 Dart 口径计算。

这是阅读校验，不是 Flutter 导入器的完整替代。当前不实现 `meeting_minutes.dart:874` 对工资、百分比与计算基数的业务语义判断，也不执行去重、补缺、跨文件持久化或历史合并。来源哈希保全而不根据未知算法重算。非阅读字段保全但不全部解释。日期接受生产写入的 ISO 本地日期时间与 RFC3339；不兼容 Dart 解析器容忍的溢出日期。内层纪要接受生产序列化的 JSON，不清洗模型 Markdown 围栏。这些边界必须在后续导入切片重新处理。

## 分片与回滚

1. R1 为独立 `desktop/core` 与独立 `Cargo.lock`，提供资料包阅读 CLI、失败测试、生产写入器互操作测试和本设计。只提交产物供协调验收，不在执行阶段 commit/push。
2. R2 由协调聊天单独派发。优先核查并复用 Cindy 在 `.cindy-worktrees/peaceful-hamilton` 的 GPUI 入口、旧库读取候选及播放界面，关联已有 #549/#550，不重复建工单。该发现由协调聊天提供；本阶段未读取、复制或验收 Cindy 业务代码。后续将 R1 core 接入 Kit 窗口，使用合成或用户指定副本证明阅读交互。
3. 后续由协调者排定编辑与资料导入、音频与设备、服务与系统集成。每片都有明确输入、可见结果和故障恢复验收；未迁移能力继续由原应用承担。只有完整功能保全与真实安装验收后才能决定替换。

R1 不修改既有持久存储或已安装应用，回滚只需停止使用新 CLI。后续写入与安装阶段必须先定义版本识别、可恢复副本与回退规则，不能让只读阅读通过代替数据迁移证明。

## R3 统一 Cargo Workspace 与桌面读写、录音、纪要、MCP 集成

`desktop/Cargo.toml` 统一合并 `desktop/core`（`koe-core` 库与 `koe-pack` CLI）和 `desktop/app`（`koe-desktop` GPUI Kit 桌面应用），消除多个 worktree 各自维护独立 `Cargo.toml` 的分裂状态：

- **旧库无损读写（`desktop/core/src/library.rs`）**：兼容 `recording_library.json`（v1）、`transcripts.json`（v4）与 `analysis.json`；保存校订正文（`save_manual_transcript`）、注册新录音（`register_recording`）及写入结构化纪要（`generate_minutes`）均通过同目录临时文件原子替换（write-and-rename），并保留 JSON 中未投影的未来字段与其它条目。
- **桌面麦克风录音与原声播放（`desktop/core/src/recorder.rs`、`desktop/app/src/main.rs`）**：使用 `cpal` 录制 16-bit PCM WAV 并计算流式 SHA-256 `contentHash` 落盘注册；使用 `rodio` 播放本机音频并实时刷新状态。
- **结构化纪要生成（`desktop/core/src/organize.rs`）**：按 `schemaVersion: 2` 生成带 `S1..Sn` 来源引用、议题因果分支（`fishbone`）、决定、行动项与待核对项的结构化纪要，写盘前经 `minutes::validate` 校验。
- **会话级授权 MCP 共享（`desktop/core/src/mcp.rs`）**：默认不共享任何录音；用户按条授权后向会话目录原子写出 15 秒租约的 `live.json`（含递增 `generation` 与 `expected_revision` 校验）及无音频 `.koepack` 快照，支持 `koe-pack mcp --live-directory PATH` 与 `tools/koe-mcp/server.py --directory PATH` 通过 MCP `2025-11-25` stdio JSON-RPC 读取。

## 可重复检查

从 worktree 根目录运行：

```sh
scripts/check-desktop
flutter test --no-pub desktop/core/tests/production_pack_test.dart --reporter expanded
scripts/verify-desktop-flow
```

首次 Flutter 测试先运行 `flutter pub get`。互操作测试调用生产 `writeMaterialPack` 生成 v1/v2、有无附带音频的四种隔离样本，然后执行真实 Rust CLI。测试比较完整 manifest、阅读投影、输入字节和目录成员，并验证损坏纪要被拒绝。生成的样本随测试结束清理，不访问资料库。

固定协调门禁 `.scratch/pstack-auto/gpui-migration/gate_core.py` 保持原样。执行证据留在同目录 `r1-receipt.md`。进度页与提交交付由后续协调阶段统一更新，本阶段不与 #548 竞争其 progress 文件。
