# 术语表

Koe 的核心领域与架构术语。权威架构分层见 [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)，与 [docs/adr](docs/adr/) 冲突时以架构规范和 ADR 为准。

## 录音聚合根与统一事实源（`crates/koe-engine`）

- **`RecordingAggregate`（录音聚合根）**：单条录音在内存与持久化中的唯一业务聚合根，内聚录制时间、时长、书签、`UtteranceSpine` 与证据绑定纪要。音频资产独立保管。
- **`UtteranceSpine`（`S1..Sn` 话语脊柱）**：一条录音的唯一时间轴事实源。每个 `UtteranceSegment` 拥有稳定递增编号（`S1`、`S2`…）、起止毫秒区间（`start_ms..end_ms`）、说话人标签、当前文字和校订时保留的原始文字。界面点句跳播、重点切片命中与纪要防幻觉校验全部直接引用 `S1..Sn`。
- **`SliceMark`（重点切片标记）**：把 D3200 帧中的实体双击标志及相对帧序号换算成毫秒书签。保存时按可用音频时长钳位、排序并去重。
- **`MeetingMinutes`（证据绑定纪要）**：由结构化议题、决策、待办（`ActionItem`）、风险与关键洞见组成的会议纪要。每条结论与待办必须携带非空且存在于当前 `UtteranceSpine` 的 `[S1..Sn]` 证据引用，由 `validate_minutes_grounding` 拦截无依据幻觉。
- **`MinuteFishbone`（根因鱼骨图）**：围绕顶层核心议题或分主题拆解出的鱼头结论与多分支因果骨刺，每个骨刺同样绑定 `[S1..Sn]` 原声证据。

## 客户端与云端传输（`crates/koe-client-*`）

- **`MaterialPack`（`.koepack` 资料包）**：资料包的只读解码结果。当前导入使用无音频包的标题、当前纪要和来源文字。见 [资料包格式](docs/material-pack.md)。
- **`XinliFormatSpec`（心力格式库）**：面向不同场景（长周期项目复盘、1-on-1 访谈、读书笔记、每日晨报等）的结构化整理模板。
- **`LiveTranscription`（实时转写流）**：把 D3200 `1A/08` 实时 Opus 帧经 `koe-opus` 解码为 16kHz PCM16 后送入 `koe-client-providers` 的云端 WebSocket 或本机识别通道，由 `KoeRuntime` 把增量与稳态句子写回 `ProductWorkspace`。

## 宿主契约与界面模型（`crates/koe-host-api` & `platforms/`）

- **`generation`（视图快照代次）**：Rust 维护的快照无符号 64 位代次。SwiftUI 与 Compose 通过 `koe_host_session_snapshot_json`（Android 经 JNI）读取，按代次刷新各自的界面切片。
- **Doctor（自检）**：查看设备、工作区、语音与模型状态。诊断包附带飞行记录，可用 `koe doctor --bundle` 导出，或以 `koe doctor --replay` 回放。
- **`InfoTip`（问号说明气泡）**：`KoeMacUI` 的原生弹出说明组件。遵循「零啰嗦」界面原则，设置页与工作区不展示大段解释性副标题，所有详细说明统一收纳进标题右侧的紧凑「?」按钮气泡中。

- **`RuntimeEnv` / `FlightRecorder`（运行环境 / 飞行记录）**：Runtime 的可注入时钟、时区与随机源，以及有界输入事件记录。脱敏导出后可在隔离工作区确定性回放。见 [架构规范](docs/ARCHITECTURE.md#飞行记录与确定性回放)。
