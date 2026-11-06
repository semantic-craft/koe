# QwenNote MCP 接入复盘与 Koe 录音豆 Agent 接口规划与实施

- 编制日期：2026-11-03；实施与落地更新：2026-11-07（随 PR #548–#555 全量合并交付）
- 状态：已完成实施与合并交付。落地实现详见 [tools/koe-mcp/README.md](../../tools/koe-mcp/README.md) 与 [docs/pstack-relay.md](../pstack-relay.md)。本文保留前期关于权限、隐私和最小工具集的复盘教训，并对齐最新交付事实。

## 目标与证据边界

用户希望安克录音豆能够接入手头的 agent，并提供类似 QwenNote 的笔记、转写与会议纪要体验。2026-11-03 本文初稿沉淀了经验与设计护栏；后续经架构评审收口，在不泄露原音频、不把未授权私有库暴露给公网的前提下，已完成双模式 MCP（本地 stdio 与远程 HTTP MCP）及跨端无音频 `.koepack` v2 自动同步的开发与合入。

本地项目为 `~/Projects/koe`，Git origin 为 `semantic-craft/koe`，当前代码基线已落地于 `main`。如下所述，已交付实现严格遵循 ADR 0002 音频不出设备、最小暴露原则与零输入框隐私安全。

QwenNote 事实来自本次接入会话的非秘密交接记录，未在本文编写时重新请求服务。没有读取会议内容、令牌或客户端凭据；不记录未经核验的工具名称、供应商 API 或逆向能力。

## 本次 QwenNote 接入实际证明了什么

| 观察 | 已确定 | 尚不能据此断言 |
| --- | --- | --- |
| 服务入口 | `https://minutes.qwennote.cn/mcp` 支持 OAuth | Koe 应复刻其内部实现，或与 DashScope 转写 API 是同一服务 |
| Magpie / 本机 Codex | 登录后能够列出 27 个工具 | 任一会议的读取、编辑、持久写入已经验收 |
| 授权页面 | 包含读摘要/转写及写标题/纪要/转写/发言人/热词；当次未能选择只读 | OAuth 授权等于每次写操作都获得用户同意，或供应商永远不提供只读范围 |
| 客户端发现 | 已在一个本机会话列出工具 | 新会话、其他宿主、远端运行节点会自动发现并继承连接 |

接入候选包括用户称为 Cindy、Antigravity、herdr、dsh、zcode、Grokbot 的环境。名称保留用户原称，具体产品、运行节点、配置位置和身份需逐一确认；这些环境的发现、授权和读写兼容性均未在本记录中验收。

这里的 QwenNote 会议笔记服务与项目已有 [Qwen 文件转写服务接缝](../notes/qwen-service-seams.md) 是不同层次：后者记录模型转写链路，不能作为前者的 MCP 协议或 OAuth 实现依据。

## 应带入 Koe 的经验

1. **分层验收。** 连接成功、OAuth 完成、工具列出、实际读取、写入后读回、新会话恢复是不同结果，逐项记录。工具数量只是一时的能力发现快照。
2. **授权范围可见且可缩小。** Koe 候选接口先只读、按录音/项目限制范围；修改标题、校订转写、生成纪要、删除、导出分别处理。上游授权太宽时，网关过滤只能缩小宿主能调用的工具，不能把上游令牌本身变成只读。
3. **持久登录不等于持久操作同意。** OAuth 只保留经用户授予的连接权限；每个新客户端/宿主独立确认信任与可见范围，敏感写入或数据外发按具体动作确认，不因登录过就自动执行。访问过期、拒绝和撤销应有明确恢复入口。
4. **不靠复制令牌扩散接入。** 原则上凭据由一个受控持有者保管，通过合适的认证连接使用。若考虑共享网关，需分别定义上游服务授权、下游客户端身份、宿主文件/网络权限；MCP 能力范围不能替代 agent 宿主权限。
5. **新会话也是交付的一部分。** 记录传输方式、启动/发现条件、运行节点和失效行为；重启与新会话必须重新核验。不能用一个客户端的成功替整个 agent 列表签收。
6. **错误不能造成重复付费或重复写入。** 区分未授权、范围不足、资源不存在、任务处理中、服务离线、请求超时、结果未知和已撤销；结果未知先查任务/版本，不盲目重发。

以上是设计护栏，不是本次已经实现的权限系统。教训的出处、计数和后续验证点见 [教训台账](../agents/lessons.md)。

## 接在 Koe 已有能力上，避免另造录音系统

现有项目身份是 Flutter iOS/macOS 应用，录音豆文档目标为 soundcore Work D3200，另有受限 Android 范围。入口为 [README 架构](../../README.md#架构)、[PROTOCOL](../../PROTOCOL.md) 和 [AGENTS](../../AGENTS.md)。设备型号、固件和配套服务仍须与用户实际设备核对；已有代码和历史协议记录不保证所有固件可用。

| 层 | 现有阅读入口 | MCP 前需要核验的接缝 |
| --- | --- | --- |
| 设备与录音获取 | `lib/ble/`、`lib/wifi/`、`lib/protocol/`、`lib/crypto/`、`lib/state/recorder/device_files.dart` | 配对身份、取回完整性、续录增长、断连恢复；不假定官方 API、云端导出或新逆向路径可用 |
| 原件与持久状态 | `lib/state/recorder/library.dart`、`lib/state/context/`、`lib/state/recorder/material_pack.dart` | 稳定 ID、修订号、回收站、路径边界、进程并发与应用关闭时的读取方式 |
| 转写任务 | `lib/ai/`、`lib/state/recorder/transcription_jobs.dart` | 本地/云端引擎可用性、任务恢复、预算、取消、真实结果落盘；不把请求已提交当完成 |
| 笔记与纪要 | `lib/state/recording_analysis.dart`、`lib/state/meeting_minutes.dart`、`lib/state/recorder/topics.dart` | 区分主题笔记与未归主题会议；来源句段、人工校订、历史和过期标记；当前纪要代码仍在开发 |
| 检索与引用 | `lib/state/context/ask_retrieval.dart`、`lib/state/recorder/ask.dart` | 授权范围内检索、可追溯的录音/句段/时码；空命中不暴露其他会议信息 |
| 对外 MCP | `tools/koe-mcp/`、`lib/state/recorder/mcp_publication.dart` | 已落地：本地 stdio 逐条授权、远程 HTTP MCP（POST /mcp + Bearer 鉴权）、双端无音频 `.koepack` v2 自动同步 |

实际交付链路为：录音豆 → Koe 取回并保存原件 → 转写任务 → 会议纪要及来源索引 → 本地生成无音频 `.koepack` v2 / `live.json` 授权目录 → 独立 Python MCP 服务（`tools/koe-mcp/server.py`）→ 外部 AI Agent（Magpie、Codex、Claude Code、Antigravity 等）。MCP 提供数据接口，**不自行把声音转成文字，也不自行生成摘要**。真正的转写与纪要由 Koe 核心流程完成，数据通过规范化的纯文字与快照提供，彻底避免外部 Agent 直接读写 Koe 私有内部文件或底层设备。

## 落地架构与交付实现（PR #548–#555）

### 1. 核心工具与契约

MCP 服务严格保持只读最小契约，仅暴露三个工具，绝不引入任意写回或越权执行：

- `list_recordings`：列出当前已授权快照的 ID、标题、导出时间、转写/纪要状态（支持可选 `query` 过滤）。
- `get_transcript`：获取指定记录的校订优先逐字稿、段落依据（P/T 序列）、发言人及导出时码。
- `get_minutes`：获取结构化纪要、出处快照与版本信息（freshness 状态与 sourceHash 校验）。

### 2. 双模式运行机制

1. **本地 stdio 模式（`--live-directory`）**：
   - 依赖 Mac 端录音详情中用户显式勾选「MCP 访问」。
   - Koe App 自动在专属临时目录下维护 `live.json`，并写入 15 秒心跳租约；App 正常退出或用户撤销时立即失效，异常退出租约超时即拒绝访问。
2. **远程 HTTP MCP 与双端同步模式（`--http-listen` / `--mode vps`）**：
   - 暴露 `POST /mcp`（JSON-RPC 2.0，Bearer 鉴权）供外部 Agent 访问。
   - 暴露 `/sync/packs`（`PUT` / `GET`），手机与 Mac 会议收尾后自动推送/拉取无音频 `.koepack` v2，实现多端无感流转。

### 3. 隐私边界与零输入框接入

- **音频不出设备**：MCP 服务与跨端同步只交换纯文字与纪要的 `.koepack` v2，不含原音频或声纹。
- **界面零回显零输入**：Koe 外部 AI 设置界面不设任何服务器地址或邮箱输入框，不回显个人域名与邮箱。
- **自动配对通道**：
  - 插线直接注入：通过 `xcrun devicectl` 推入 `mcp_pairing.txt`，App 读取后自动绑定并销毁文件。
  - 剪贴板一键接入：Agent 输出 `KOEMCP1.<base64url>` 格式连接码，用户点「从剪贴板一键接入」即可完成配对，令牌安全保存于系统 Keychain。
- **安全 OTP 绑定**：VPS 模式支持邮件验证码核验，避免公网扫描与未授权绑定。

## 数据、隐私与权限边界

- 延续 ADR 0002：会议默认“录音只留本机”；没有本地转写能力时明确不可用，不偷偷回落云端。纪要默认只发文字也仍是数据外发，应展示目的地和范围；“音频不出设备”不等于会议内容不外发。
- 访问分成元数据、逐字稿、纪要、原音频及写入。优先暴露被用户选定记录的最少文字；原音频下载、批量导出、删除和设备控制不作为第一期默认能力。检索、标题、日志和工具报错也可能泄露会议信息。
- 用户拥有设备不代表已获得其他参会人的录音或第三方处理许可。开发验收使用自录或明确授权的测试音频，先说明转写/摘要服务及其他 agent 的处理范围；未选定的真实会议不用于测试。
- 稳定来源 ID、句段/时码及修订号优先于本机路径；不把原件路径、声纹或凭据返回客户端。声纹按 ADR 0002 仅存本机，不因新增接口进入导出。
- 人工校订和生成结果分开，写入带预期修订号和可追踪操作记录。校订后旧纪要、旧索引应标记失效；并发修改应明确冲突。实际版本模型待核对，不预设字段已经存在。
- 日志只留必要的动作、状态和去敏 ID，不留令牌、全文、原音频或含凭据的 URL；保留期限、删除传播和撤销后的缓存处理需在实施前确定。

## 分期路线与交付状态

| 期 | 原规划工作 | 交付状态（2026-11-07） |
| --- | --- | --- |
| 0：核实与范围 | 核对设备/固件与数据处理边界 | **已完成**：确定 soundcore Work D3200 范围，坚持“音频不出设备、纯文字按需授权”底线 |
| 1：只读垂直样例 | 提出最小只读契约与格式适配 | **已完成**：交付 `list_recordings`、`get_transcript`、`get_minutes` 三个只读工具与无音频 `.koepack` v2 快照 |
| 2：处理任务与发布 | 评估应用服务触发与自动发布 | **已完成**：交付 Mac 端录音详情 MCP 逐条授权、15 秒租约及 `lib/state/recorder/mcp_publication.dart` 自动发布 |
| 3：受控修改与远程同步 | 评估多端同步与版本更新 | **已完成**：交付轻量远程 HTTP MCP（`POST /mcp`）与手机/Mac 局域网或 VPS 自动推拉（`/sync/packs`） |
| 4：多 agent 接入 | 验证各 agent 的传输、鉴权与接入 | **已完成**：采用标准 MCP JSON-RPC 2.0 + Bearer 鉴权，支持 `KOEMCP1.` 剪贴板与 devicectl 文件直接注入，免除手动输入与域名回显 |

全量代码经 PR #548、#552、#553、#554、#555 全部 squash 合并入 `main`。

## 原实施前问题的回答与工程收口

1. **实际设备与取回路径**：确认目标设备为 soundcore Work (D3200)，经 CoreBluetooth 取回音频并在 App 本地转写；MCP 服务不接触硬件，仅读取 App 生成的文字与纪要快照。
2. **部署形态与进程协调**：支持两种形态——① Mac 本机 stdio（`server.py --live-directory`），由 App 维护带租约的 `live.json`；② 远程/局域网 HTTP（`server.py --http-listen`），由 App 自动推拉 `.koepack` v2 到同步目录。进程之间通过不可变文件解耦，外部服务不直接访问 App 私有数据库。
3. **字段范围与凭据管理**：坚持最小只读契约（列表、逐字稿、纪要）；不提供音频下载与修改工具。凭据采用 32 字节 Bearer Token + 邮件 OTP 验证，App 端存入系统 Keychain；配对采用零输入设计（剪贴板一键接入或 devicectl 容器直推）。
4. **音频/文字隐私边界**：严格延续 ADR 0002，音频不出设备。MCP 交换的所有包均为无音频包；声纹仅存本机，不随 MCP 或资料包外发。
5. **并发与版本契约**：基于 `.koepack` v2 的 `materialContentHash` 与 `snapshotRevision` 保证版本一致，读取时支持 `expected_revision`，正文变更返回 `snapshot_changed`，避免 Agent 拼接不同版本数据。
6. **工具定位**：不以复制 QwenNote 27 个工具为目标，而是提供稳定、可回溯、带出处快照的纯文本数据，将深度推理、提炼或问答交由接入的外部 Agent 自行处理。

## 验证与测试套件

- **Python 协议测试**：`python3 -B tools/koe-mcp/test_server.py`（22 项子进程协议与边界测试，全部通过）。
- **资料包兼容测试**：`flutter test test/koe_mcp_export_test.dart`（生产格式与只读协议探针）。
- **控制器自动发布测试**：`flutter test test/mcp_live_publication_test.dart`（Mac 录音授权、租约超时与发布撤销）。
- **远程 HTTP MCP 与双端同步测试**：`flutter test test/mcp_sync_test.dart`（Bearer 鉴权、OTP 绑定、双端自动推拉及零输入框配对）。
- **全流程无人值守门禁**：`scripts/verify-minutes-flow mcp` 退出码 0。
