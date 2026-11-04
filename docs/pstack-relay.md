# Koe 录音纪要与 MCP 接力

## 目标与边界

按下录音豆说话，Koe 使用已配置的 ASR 转写、Qwen 或指定 LLM 整理；iPhone 在录音过程中显示阶段摘要，停止后保存有概述、章节、分层要点与回顾的完整纪要。MCP 对外提供允许范围内的最新文字与纪要。核心整理不依赖 Codex、Mac 中转或手动复制；外部结果回写、sidecar、插件 UI 暂不在范围内。

用户 2026-11-05 明确要求全自动验收。不得把人工听录音、点击页面、确认截图列为完成条件。自动化必须实际驱动并检查结果；设备离线、权限不足、提供商不可用、实体键无法自动驱动时记为未验收，不能将 skip 当 PASS。合成、真实服务、模拟器和真实设备证据分开。用户无需重新选择模型或配置已有凭据。

参照本轮已读取的钉钉闪记样例：整体标题和概述、时间章节、章内编号、要点卡片、关键回顾。保留口述的观点、理由、例子和改口；不强制套用会议待办模板。样例排版观察不证明其原音频准确性。

## 现状 vs 目标差距对表与防冲突护栏

基线 main `6a8c217`；本棒分支 `codex/koe-minutes-relay`。GitHub semantic-craft/koe 当前开放 PR 为 0；不得省略 gh 的 --repo，否则可能选到 upstream。

| 环节 | 已观察入口 | 差距与验证要求 |
| --- | --- | --- |
| 模型配置 | lib/state/recorder_controller.dart 的 QwenAnalysisService、analysisBackend、analysisApiKey | 复用设置，自动测试不得读取个人 Keychain 或打印凭据；真实服务只用授权测试输入 |
| 自动整理 | lib/state/recorder/organize.dart；test/auto_organize_test.dart | 已有转写、摘要、待办流程；核对是否会自动产出完整分层纪要，不把摘要完成当纪要完成 |
| 分层纪要 | lib/state/meeting_minutes.dart；lib/ui/widgets/minutes_panel.dart、minutes_topic_card.dart | 核对个人口述类型、细节保留、章节与手机布局，不重复造模型 |
| 实时摘要 | lib/state/recorder/live_meeting.dart；lib/state/live_minutes.dart；test/live_meeting_test.dart | 已有实时纪要流程，需证明录音豆输入接线、停止收尾、持续更新和旧结果失效 |
| 外部读取 | tools/koe-mcp/server.py；test/koe_mcp_export_test.dart | 当前 main 为手动导出快照；需自动提供允许范围内最新版本并在真实客户端读回 |
| 离线门禁 | scripts/check；上述控制器和 widget 测试 | 可验证行为，但不证明真实供应商与设备链路 |
| iOS 自动界面 | integration_test/screenshots/app_tour.dart | 文件明确写无断言；目前不构成纪要端到端验收。Slice B 首先补齐 |

另一工作区 `/Users/xianweizhang/Projects/.worktrees/koe/agent-preflight` 已有未提交修改，涉及 organize.dart、recorder_controller.dart、minutes_panel.dart、归档、转写、MCP server 及测试。其改动不视为已交付，本棒不编辑这些文件；B 开始前核对该工作区最新状态与所有权，复用已合并改动，避免双写。该工作区还新增 `integration_test/screenshots/daily_minutes_acceptance.dart`、`test/minutes_sync_mcp_e2e_test.dart` 与同步协调器；这些是可复用候选，不是本次通过证据。其 iOS 场景采用 ASR/LLM 替身，不能代替真实服务或 BLE 验收。当前主工作区原有 docs/agents/lessons.md、docs/notes/README.md、未跟踪 docs/design/qwennote-mcp-lessons-and-plan.md 均保留，不纳入本棒提交。

现有总工单 #543、实现 #544/#545/#546、真实验收 #514/#515/#528 继续复用，不新开重复工单。#543 记录指定 GLM 执行及不合并、不发布边界，本棒不接管其业务分支、不合并该工作。新要求全自动与实时更新写在本队列；后续在原工单协调增量范围。

代码定位：main 自动整理仅 summary/todos（organize.dart:450–456）；实时识别已在 live_transcription.dart:536 接入 acceptLiveSpeech，但每场 live_meeting.dart:77 重置 liveMinutesEnabled=false。优先补这两处真实体验缺口，不另造处理系统。

## 全自动验收契约

Slice B 要建立 `scripts/verify-minutes-flow`，后续 Done Predicate 中该命令目前尚不存在，不能提前声称通过。提供 `offline`、`ios`、`provider`、`device`、`mcp` 和 `all` 模式，使用隔离测试资料，输出机器可读回执与去敏截图。记录提交、输入哈希、模型标识、平台、步骤状态、版本和证据路径；缺条件必须非零退出。all 必须同时要求所有层通过，不能只汇总测试数量。

- offline：固定语料含理由、例子、否定、改口、未知事项；断言结果保存和重启读回、修订与引用一致、失败恢复。模型替身只证明流程。
- ios：自动启动隔离应用、驱动录音详情、核对章节和正文、滚动及重开读回，抓截图检查溢出；不读个人资料。截图存在本身不等于成功。
- provider：指定授权音频经实际配置 ASR 和 LLM。用预定义事实、必须保留的改口、不得出现的断言及来源定位评估内容；模型评分仅补充，不能独自决定 PASS。
- device：真实 iPhone 与 D3200 输入到持久结果。自动声源和远程录音命令可验证声音链路，但不能冒充实体按键；实体键若无自动驱动装置或可观察事件证据，报告对应项未验收，不转嫁人工验收、不降低目标。
- mcp：真实子进程和实际客户端读取同一版本；继续转写、校订、撤销后再次读取，确认最新版本和访问范围；不能用导出夹具代替客户端证明。

回执存 .scratch/pstack-relay/，不提交录音、全文或运行日志。业务改动仍跑 scripts/check；涉及 BLE/音频/JSON 存储或检索时跑 scripts/perf-check。需真机的项独立 GitHub 工单；代码合并与产品全自动验收分开记录，不因代码合并勾完产品切片。

## 接力运行说明

scripts/pstack-relay 已安装；.agents/hooks.json 是本机配置。此脚本的 hook 格式面向 Antigravity，尚无 Codex 自动触发证据，不能声称在 Codex 已自动接线。本会话显式运行 status/advance 生成提示词和复制剪贴板。selftest 只验接力文件，不验应用；advance 本身不会执行 Done Predicate，调用前必须核对实际回执。

下一棒在 `/Users/xianweizhang/Projects/koe` 读取本文件与分支状态。账本只是线索，完成证据与当前源码不符时调查，不盲信历史勾选。未来缺少本机 .scratch 时以提交的本文件和 PR 证据恢复。

## 全景切片队列

### [x] Slice A: 现状与全自动验收边界
- **Playbook**: Investigation
- **Outcome**: 核对现有能力、并发改动和自动验证缺口，建立可接续队列；不宣称产品已实现。
- **Done Predicate**: `scripts/pstack-relay selftest`、`python3 progress/progress.py check`、现有自动整理/纪要页面/实时纪要/MCP四组定向测试通过；缺少 iOS 端到端断言明确列为 B 首个前置工作。
- **Evidence**: docs/pstack-relay.md; .scratch/pstack-relay/baseline.log (20 tests PASS); MCP subprocess 11 tests PASS; progress check PASS

### [ ] Slice B: 自动验收入口与单条录音的 iOS 完整纪要
- **Playbook**: Feature
- **Outcome**: 先核对 agent-preflight 重叠改动，补齐自动验收入口；复用已有 ASR/Qwen 与纪要模型，自动生成并在 iOS 保存、分章显示个人口述纪要。无需人工点击或审稿才能判通过。
- **Done Predicate**: `scripts/check`、`scripts/verify-minutes-flow offline`、`scripts/verify-minutes-flow ios`、`scripts/verify-minutes-flow provider` 均通过；入口在本片先实现，真实模型失败或设备缺失不得记为通过。
- **Evidence**: PENDING

### [ ] Slice C: 录音豆实时摘要与自动收尾
- **Playbook**: Feature
- **Outcome**: 实际录音豆输入持续进入转写与阶段摘要，停止后完整纪要落盘；重启恢复、失败提示、旧版本保护可自动验证。
- **Done Predicate**: `scripts/check`、`scripts/perf-check`、`scripts/verify-minutes-flow device` 通过，包含录制中更新、停止最终化与重启读回；实体按键覆盖必须有自动证据，否则保留未验收。
- **Evidence**: PENDING

### [ ] Slice D: MCP 自动读取最新文字和纪要
- **Playbook**: Feature
- **Outcome**: 外部 AI 无需手动导出即可读取允许范围内的最新文字与纪要，与 iPhone 同一记录和版本对应；不扩展外部写回和插件 UI。
- **Done Predicate**: `scripts/check`、`python3 -B tools/koe-mcp/test_server.py`、`scripts/verify-minutes-flow mcp` 通过，包含实际客户端读取、更新再读和撤销检查。
- **Evidence**: PENDING

### [ ] Slice E: 全流程无人值守复验与交付
- **Playbook**: Shipping
- **Outcome**: 同一授权测试音频无人值守走过录音豆、实际 ASR/LLM、iPhone 纪要和外部 MCP，记录版本、安装、合并、实际验收分别状态。
- **Done Predicate**: `scripts/verify-minutes-flow all`、`scripts/check`、`python3 progress/progress.py check` 通过；无 skip、缺失证据或人工验收项，所有切片完成后再运行 `scripts/pstack-relay status --require-all-done`。
- **Evidence**: PENDING
