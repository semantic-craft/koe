# 术语表

Koe 的核心领域与架构术语。权威架构分层见 [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)，与 [docs/adr](docs/adr/) 冲突时以架构规范和 ADR 为准。

## 录音聚合根与统一事实源（`crates/koe-engine`）

- **`RecordingAggregate`（录音聚合根）**：单条录音在内存与持久化中的唯一业务聚合根，内聚音频元数据、`UtteranceSpine`、重点切片、证据绑定纪要、柔彩视觉卡片与根因鱼骨图。
- **`UtteranceSpine`（`S1..Sn` 话语脊柱）**：一条录音的唯一时间轴事实源。每个 `UtteranceNode` 拥有稳定递增编号（`S1`、`S2`…）、起止毫秒区间（`start_ms..end_ms`）、说话人标签、原文与双语译文。界面点句跳播、重点切片命中与纪要防幻觉校验全部直接引用 `S1..Sn`。
- **`SliceMark`（重点切片标记）**：录音过程中双击 D3200 物理按键（或由宿主触发 `mark_slice`）打下的毫秒时间戳，自动绑定前后 `+-10s`（共 20s）音频窗口与落在窗口内的 `S1..Sn` 节点。
- **`MeetingMinutes`（证据绑定纪要）**：由结构化议题、决策、待办（`ActionItem`）、风险与关键洞见组成的会议纪要。每条结论与待办必须携带非空且存在于当前 `UtteranceSpine` 的 `[S1..Sn]` 证据引用，由 `verify_minutes_against_spine` 拦截无依据幻觉。
- **`VisualSummaryCard`（柔彩视觉摘要卡）**：从 `RecordingAggregate` 派生出的最多 6 张高密度摘要卡片，由原生界面的 `AppColors` 呈现。
- **`MinuteFishbone`（根因鱼骨图）**：围绕顶层核心议题或分主题拆解出的鱼头结论与多分支因果骨刺，每个骨刺同样绑定 `[S1..Sn]` 原声证据。

## 客户端与云端传输（`crates/koe-client-*`）

- **`MaterialPack`（`.koepack` 资料包）**：Koe 的跨机迁移与备份归档格式，包含录音元数据、完整 `UtteranceSpine`、校正记录、`SliceMark` 与 `MeetingMinutes`。
- **`XinliFormatSpec`（心力格式库）**：面向不同场景（长周期项目复盘、1-on-1 访谈、读书笔记、每日晨报等）的结构化整理模板。
- **`StreamingAsrPump`（实时流转写泵）**：把 D3200 `1A/08` 实时 Opus 帧经 `koe-opus` 解码为 16kHz PCM16，并通过原生掩码 WebSocket 推入阿里云百炼 `fun-asr-realtime`，把增量与稳态句子写回 `UtteranceSpine`。

## 宿主契约与界面模型（`crates/koe-host-api` & `platforms/`）

- **`ViewRequestGeneration`（视图快照代次）**：`koe-runtime` 每次状态变更时单调递增的无符号 64 位整数（`generation`）。SwiftUI 宿主通过 `koe_host_snapshot_json` 拿到带 `generation` 的不可变视图快照，仅在代次前进时刷新界面，避免跨层状态复制与旧异步回调覆盖新状态。
- **`BeanPipelineDoctorSnapshot`（五阶自检快照）**：位于「设置与自检」面板的端到端诊断视图，逐阶报告 BLE GATT 连接、D3200 实时流开启、`libopus` 解码、云端 DashScope WebSocket 与本地落盘索引的真实健康度。
- **`InfoTip`（问号说明气泡）**：`platforms/apple-shared` 的原生弹出说明组件。遵循「零啰嗦」界面原则，设置页与工作区不展示大段解释性副标题，所有详细说明统一收纳进标题右侧的紧凑「?」按钮气泡中。
