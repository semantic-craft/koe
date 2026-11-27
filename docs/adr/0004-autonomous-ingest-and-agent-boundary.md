# 无人值守采集、四系统边界与外部代理契约

## 问题

`Koe` 已在纯 Rust 内核与 macOS 原生宿主中实现 D3200（soundcore Work）BLE 加密拉取、音频落盘与 `CustodyReceipt` 签发、本机与云端转写、基于 `validate_minutes_grounding` 的反幻觉纪要、带 `SourceRef` 的 `SourcedItem` 候选待办，以及经 `koe.sock` 暴露的 16 项 MCP 工具。要将这套底座用于「随身佩戴 D3200 回到 Mac 旁自动回传、批量转写与出纪要、再交由外部代理分流建单或派发任务」的无人值守链路，现有实现仍存在五类明确缺口。

1. **中途 BLE 断链与休眠唤醒缺口。** macOS 宿主仅在 `Koe.app` 启动时经由 `BluetoothBridge` 扫描并直连已知设备。录音豆离开蓝牙范围触发 `didDisconnectPeripheral` 后，`resetLinkState` 会清空扫描与连接状态且不再重启扫描；既有的 `reconnectKnownIfAvailable` 未在生产路径调用；macOS 宿主也未监听系统休眠唤醒通知以恢复扫描。用户外出返回 Mac 附近后，宿主不会自动感知设备并接续离线拉取。
2. **无头 MCP 回退抢占工作区排他锁。** `Koe.app` 未运行时，`koe --mcp-stdio` 会回退直开 `ProductStore`，持有 `.koe-workspace.lock` 排他锁，并落入无 CoreBluetooth 驱动、无 Keychain 凭据的 `IsolatedCredentials` 模式。外部调度进程一旦先于 `Koe.app` 启动 MCP，既读不到真实设备与云端凭据，还会阻塞随后启动的 `Koe.app` 打开工作区。
3. **内存批处理队列与本机离线模型准入缺口。** `auto_transcribe` 与 `auto_summarize` 仅驻留内存集合，宿主重启后尚未启动的批量离线录音不会自动续跑。同时 `OfflineSpeechWorker` 的有界队列上限为 `MAX_OUTSTANDING`（4），而 `drive_analysis_queue` 未对本机下载模型与 Apple 本机文件转写施加并发上限，大批量离线文件入队时容易直接报队列满失败。
4. **本地桥 2 MiB 单行上限、代次归零与控制缺口。** `local_bridge`（`koe.sock`）与 MCP stdio 的单行协议上限为 `MAX_LINE_BYTES`（2 MiB），超长会议调用 `get_record` 返回全量片段会超限并导致连接进入 `Poisoned`。`poll_updates` 返回的 `generation` 在宿主重启后重置为 1，`pendingJobs` 仅统计云端任务而不包含本机转写；MCP 也尚未暴露批量离线拉取与记录项目归类入口，且外部代理盲目触发 `manage_record` 的 `transcribe` 可能与自动转写竞态并在云端模式下生成重试副本。
5. **纪要热词未接线与无门禁派单风险。** 引擎层 `build_meeting_minutes_prompt` 已预留最多 200 词的 `vocabulary` 参数，但运行时固定传空切片；免费本机 ASR 与 DeepSeek ASR 不输出说话人分离标签。随身录音豆拉回的音频混杂正式会议、闲聊与私密对话，缺少闭集分流、置信度闸门、不可信文本隔离与幂等账本时，直接由语音内容触发外部工单或代码执行会引发隐私外泄、重复建单和提示词注入劫持写操作。

## 决策

### 四系统严格边界

整套语音到工单或执行的自动化链路按单一职责拆分为四个独立系统，并用位于 `Koe` 之外的薄调度层串联。

| 系统 | 职责边界 | 明确不承担的职责 |
| --- | --- | --- |
| `Koe` | 唯一的硬件、音频、原文与有据纪要事实源。负责 D3200 BLE 加密连接与批量拉取、`.wav`/`.opus` 托管与 `CustodyReceipt`、本机与云端转写、经 `validate_minutes_grounding` 校验的纪要、带 `SourceRef` 的 `SourcedItem` 候选项，以及经 `koe.sock` 提供的受控 MCP 契约。 | 不内置 Linear、GitHub 或飞书工单客户端，不维护公司部门路由表，不在内核执行跨系统自动派单。 |
| `Responsay` | 可选的外部专业词库来源（向 `Koe` 纪要阶段同步专有名词）与平行手机口述收件箱入口。 | 不改造成供 `Koe` 调用的批量音频文件转写 API。长音频与录音豆文件始终由 `Koe` 内置本机引擎或云端 ASR 处理。 |
| `Kotone` | 本机闭集分流判断与置信度闸门，遵守 `execution="未执行；仅返回判断"` 契约。依据候选项目或部门列表返回结构化归属与置信度，低置信度或弃权结果强制拦截进入人工复核。 | 不轮询蓝牙设备，不持有 `Koe` 工作区锁，不直接向公司职能部门工单系统写单。 |
| `Kido Kantai` | 仅负责已获准的研发与个人项目代码执行派发，经由 `Codex` 或 `DSH` 提供幂等委派与会话审计。 | 不充当非研发职能部门的 Issue 追踪器。产品、法务、财务、运营等团队事项投递到独立 Issue 系统（如 Linear、GitHub Issues 或飞书）。 |

外部薄调度层运行在 `Koe` 内核之外，维护一份独立的本地 SQLite 派发账本，以 `(record_id, item_id, content_revision, decision_id)` 作为幂等复合键，确保轮询重试、宿主重启与网络抖动下不会重复建单。所有来自 `Koe` 的转写原文与纪要内容一律视为不可信数据并实施隔离，禁止把原始转写文本直接拼入高权限执行代理的系统指令；分流与派单仅消费结构化摘要、行动项与 `SourceRef` 证据定位。多人会议需要明确说话人责任归属时，由用户在 `Koe` 中显式选用支持说话人分离的云端非实时模型，避免对本机无说话人模型产生误判。

### 六态派发生命周期

端到端处理采用六态主生命周期，并保留归档与忽略两个终态：

```text
Captured -> Transcribed -> Summarized -> Classified -> ReviewGate -> Dispatched
终态：Archived / Dismissed
```

- `Captured`、`Transcribed` 与 `Summarized` 的事实完全由 `Koe` 的 `ProductWorkspace` 与 `ProductStore` 拥有，依次对应音频落盘与 `CustodyReceipt`、原文分段定稿写入 `ProductRecord`、以及通过 `validate_minutes_grounding` 校验并生成 `SourcedItem` 候选项。
- `Classified`、`ReviewGate` 与 `Dispatched` 的状态机及外部工单标识由外部薄调度层的本地 SQLite 账本与 `Kotone` 复核队列拥有，不回写进 `Koe` 工作区模型。
- `Archived` 对应记录归档防误删，`Dismissed` 对应待办或分流项被人工忽略，均终止后续自动派发。

### Koe 核心四项有序工程里程碑

在接入外部薄调度层之前，`Koe` 自身按以下四项有序里程碑补齐无人值守底座，且每项保持文件边界清晰、独立可验证。

1. **macOS BLE 断链与休眠唤醒自动重连状态机。** 在 `KoeAppleCore` 中为 `BluetoothBridge` 引入纯状态机与有界指数退避重连策略，覆盖中途意外断链、连接失败、射频状态复位和 macOS 休眠唤醒通知，并接通既有的 `reconnectKnownIfAvailable` 能力。用户显式断开、释放蓝牙给手机或关闭 `ble_auto_connect` 时必须抑制自动重连；保留 iOS 状态恢复分支，并保持宿主 Swift 文件不超过 500 行门禁。
2. **本机免费引擎批处理恢复与 `OfflineSpeechWorker` 单路准入。** 扩展 `recover_local_captures`，在重启打开工作区时直接从已持久化的 `ProductWorkspace` 事实推导待转写的本机免费引擎录音（`RecordOrigin::Bean`、音频文件存在、无原文分段且分析状态为空闲或中断），在 `drive_analysis_queue` 中对本机下载模型与 Apple 本机文件转写施加单路准入（同时至多 1 个活跃本机文件会话）以杜绝 `MAX_OUTSTANDING`（4）溢出。严格遵守 [贡献规则](../../CONTRIBUTING.md) 第 4 条，处于 `Interrupted` 的云端转写与文字纪要任务永不在启动时静默重试，始终以 `RequestKey` 防重扣费并等待人工显式重试。
3. **CLI/MCP `--bridge-only`、大记录分页与轮询及控制契约。** 为 `koe --mcp-stdio` 增加 `--bridge-only` 选项，在 `koe.sock` 未就绪时返回明确离线错误而不打开 `ProductStore` 或抢占 `.koe-workspace.lock`，并在宿主开放 `koe.sock` 后按需重连。扩展 `get_record` 支持分段分页与低于 2 MiB 单行上限的字节预算裁剪，根除超长会议导致的连接 `Poisoned`。扩展 `poll_updates` 返回 `generationReset`（重启代次归零提示外部代理按持久 `revision` 对齐）并在 `pendingJobs` 中展示活跃本机转写任务。扩展 `device_control` 支持 `download_all`（对应 `HostIntent::DeviceDownloadAll`），扩展 `manage_record` 支持 `set_project`（对应 `HostIntent::SetRecordProject`）以及避免重复触发的 `if_idle` 守卫。
4. **200 词纪要热词表持久化与 MCP 同步契约。** 在 `ProviderConfiguration` 中持久化规范化后的 `minutes_vocabulary`（去空、去重、最多 200 词），工作区编解码对缺少该字段的历史 JSON 保持零破坏兼容，`HostIntent::ConfigureProvider` 以可选字段保持跨端契约一致。运行时在摘要请求中把持久词表传入 `build_meeting_minutes_prompt` 替代空切片，并经 MCP 暴露词表读写同步契约，供外部同步脚本将 `Responsay` 等外部词库写入 `Koe`。

### 第一阶段刻意延后硬件自动删档

D3200 协议的按文件删档命令 `0x1A/0x10`（见 [D3200 协议笔记](../../PROTOCOL.md)）虽已在引擎层具备 `CustodyReceipt` 类型门禁，但第一阶段明确不在无人值守拉取完成后自动触发硬件闪存删除。实体 D3200 机载闪存为 58.2 GB，按当前 Opus 码率可容纳约 1,900 小时录音，短期不存在存储耗尽风险；同时实体录音豆长周期离线同步与真实云端联调工单（`#757`）尚未完成真机闭环。延后自动删档可避免未闭环前的不可逆丢数据风险，待长期真机验收完成后再单独制定受控回收策略。

## 比较过的方案

1. **另建独立无头 BLE 抓取进程或封装第三方破解脚本。** `Koe.app` 已具备零 `unsafe` 的 Rust D3200 加密与传输状态机、系统 Keychain 凭据绑定和单写者 `ProductStore`。另起 BLE 守护进程会与 `Koe.app` 争夺 D3200 单活跃 GATT 连接，重复实现 `CustodyReceipt` 托管逻辑并引入锁竞争，因此不采用。
2. **在 `Responsay` 上暴露批量音频文件转写 API 供 `Koe` 调用。** `Responsay` 面向短句语音输入，不提供长音频批量转写与说话人分离；`Koe` 已有同源本机引擎（Apple Speech、下载模型）与云端千问、DeepSeek ASR。增加跨应用音频转发只会抬高延迟与故障面，因此不采用。
3. **将公司部门路由、Linear、GitHub 或飞书凭据与派单逻辑放进 `koe-engine`。** 这违背 [架构与状态所有权](../ARCHITECTURE.md) 的四层纯领域边界，会让核心音频与纪要运行时承载大量外部 SaaS 凭据与定制工作流，并与 `Kotone` 的闭集审核重叠，因此不采用。
4. **为批量转写新增第二份持久化重试队列文件。** 外部队列文件容易与 `ProductWorkspace` 内每条 `ProductRecord` 的实际原文、音频与归档状态发生漂移。改为重启时直接从持久化工作区事实推导待运行的本机免费任务，既保持幂等收敛又严格守住云端 `Interrupted` 禁止静默重跑的规则，因此不采用。
5. **在第一阶段启用 `0x1A/0x10` 自动硬件闪存清理。** 机载 58.2 GB 空间足以覆盖约 1,900 小时录音，而物理长测 `#757` 仍未关闭；在无人值守自动重连和批量处理经实机长期验证之前自动删除硬件原件风险过高，因此第一阶段不采用。

## 验收标准

以下标准区分为可随代码合并的自动化行为门禁，以及拆分为独立 `ready-for-human` 工单的实体 D3200 真机验收。

- **里程碑一自动化验收。** 在虚拟蓝牙适配器与可注入休眠通知测试中，意外断链、连接失败、射频复位和宿主唤醒均按有界指数退避自动重连；用户主动断开、释放给手机或关闭 `ble_auto_connect` 后零次自动重连；桥接销毁时全部重连定时器被清理；受影响的 Swift 宿主文件均不超过 500 行且 iOS 恢复路径不回归。
- **里程碑二自动化验收。** 连续入队 12 条及以上本机下载模型离线录音时，按单路并发顺序完成且不出现 `OfflineSpeechWorker` 队列满错误；重启 `KoeRuntime` 后未完成的本机免费 `RecordOrigin::Bean` 录音自动续跑，而处于 `Interrupted` 的云端转写与文字纪要保持暂停、绝不静默重发请求。
- **里程碑三自动化验收。** 在 `Koe.app` 未运行时启动 `koe --mcp-stdio --bridge-only`，不占用 `.koe-workspace.lock` 且工具调用返回明确离线错误，宿主开放 `koe.sock` 后同一会话自动恢复可用；超过 2 MiB 序列化体积的合成长记录经 `get_record` 分页完整取回且不触发连接 `Poisoned`；宿主重启后 `poll_updates` 返回 `generationReset` 并在 `pendingJobs` 暴露活跃本机转写任务；`download_all`、`set_project` 与 `if_idle` 防重复制均由行为回归测试覆盖，MCP 仍拒绝永久清除记录。
- **里程碑四自动化验收。** 通过 MCP 写入的 `minutes_vocabulary` 经去重与 200 词上限校验后持久化并跨重启保留，超限请求明确报错且不破坏既有配置；缺少该字段的历史工作区可无损读取；摘要请求正文包含已配置词表；跨端宿主契约检查继续通过。
- **实体硬件与真机验收分离。** 实体 D3200 离开并返回 Mac 蓝牙范围、真实 macOS 休眠锁屏恢复、手机与 Mac 蓝牙交接、以及长周期离线批量拉取与真实云端联调（延续 `#757`、`#612`、`#725`、`#731`），不以替身测试或模拟器结果替代，统一按 [贡献规则](../../CONTRIBUTING.md) 拆分为独立 `ready-for-human` 工单并在 [进度页](../../progress/) 单独跟踪。核心架构定位同步关联 [ADR 0003](0003-shared-speech-and-all-day.md) 与 [路线图](../../ROADMAP.md)。
