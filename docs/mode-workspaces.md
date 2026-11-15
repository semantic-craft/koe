# 四模式工作区

产品从“模式选择”进入随心闪记、全天听记、实时纪要、语音输入，侧栏保持同名入口，并提供问 AI。首页显示四个模式控制和当前状态，历史资料进入所有记录。打开工作区只查看内容，不自动启动采集。

这是用户于2026-11-13确认的业务定义。四工作区正式 SwiftUI 页面与 Rust 统一 `workspaces` 投影已按本定义在本机实现并通过单元与自检测试；现有模式入口、录音键默认行为及语音伴侣链路不重复建设，物理录音豆与 Responsay 联动真机验收单独追踪。

## 已确定的录音行为

- 普通录音键开始新会话时默认随心闪记。
- 全天听记、实时纪要和语音输入需要在Mac明确开启本次模式。结束后释放会话选择。
- 重启不自动录音，不新增持久的selectedMode恢复逻辑。
- 侧栏导航与录音启停分开。一次选择一个主采集模式，既有全天听记中的临时听写辅助操作继续保留。

## 随心闪记

场景是临时想到的任务、想看的书、灵感和零碎想法，最终形成可继续推进的事情或项目线索。工作区围绕下列内容组织。

1. 收件箱收纳尚未整理或归属不明确的想法。
2. 原始转写保留时间、录音和来源，支持查看与校正。
3. AI分析独立显示这段话在说什么、可能要做什么，不能覆盖原文。
4. 行动与项目建议关联原话。用户可以确认或调整归属，不明确的内容先留收件箱。
5. 支持导出原文、分析和来源；Agent读取优先提供转写原文。

“项目归类”是待实现目标。已有待办和记忆审核不等于已经实现项目归属。

## 全天听记

粒度是一整天的上下文，不能把每个音频文件直接当成一件事情。目标页面包括有时间定位的原文时间线、跨分段语义事件、暂停与未录音空档、待办/承诺/决策/记忆建议、当日回顾，以及回到原话和音频的位置。

已有全天分段与处理管线继续复用。新增语义事件合并和每日回顾的具体能力按实际实现另行验收，不把缺失时间补成虚构内容。

[TaoSheng固定版本README](https://github.com/0xCoach/TaoSheng/blob/6bcf05c333767aea775d6aee7c6d39d65602dc51/README.md)描述全天转写、事件和记忆。[DigestPrompt](https://github.com/0xCoach/TaoSheng/blob/6bcf05c333767aea775d6aee7c6d39d65602dc51/shared/src/commonMain/kotlin/app/resound/digest/core/DigestPrompt.kt#L119-L180)把事件关联到原文行范围。借鉴这些组织方式，不据此声称Koe的硬件、能耗或长时间场景已经通过。本次未运行该项目，未确认它提供MCP；其Agent导出不等同于MCP。

## 实时纪要

场景是一场当前讨论。宽屏并排显示实时原文和纪要，窄屏切换标签；原文、讨论要点、决策与行动保留来源定位。显示原文和纪要各自的处理覆盖与更新状态，结束后对完整已收到的内容整理，支持校正、回听和导出。

[Cicada固定版本Notes](https://github.com/wquguru/cicada/blob/f119ba618814cc43ebee60548795754010bcca40/Sources/Cicada/Notes.swift#L243-L340)以新增原文更新既有纪要，[NotesWindow](https://github.com/wquguru/cicada/blob/f119ba618814cc43ebee60548795754010bcca40/Sources/Cicada/NotesWindow.swift#L255-L285)区分宽屏并排与窄屏标签。这里只借鉴会话组织。本次未运行该项目；来源行存在检查不能证明结论在语义上正确。

Koe现有原文和纪要页面继续复用。上述实时增量纪要体验、完整覆盖显示和事件化输出不因已有页面而自动视为完成。

## 语音输入

该页面帮助用户保留已有配置并完成Responsay联动。流程依次检查录音豆与Koe、Responsay连接、权限/音源/模型、语音输入快捷键、真实输入测试。进入页面不能把“连接完成”显示成“识别和上屏已通过”。

语音快捷键绑定与两个家族响应开关是不同操作。开启响应开关不会自动建立语音绑定，指引应读取已有绑定并提供直接设置入口，帮助用户录制想使用的组合键。

Responsay已合并[PR #823](https://github.com/semantic-craft/responsay-macos/pull/823)，提供“Responsay 响应 Fn 快捷键”和“Responsay 响应右 Option 快捷键”。各自控制单键及该家族所有组合动作；关闭保留绑定，进行中已接受的按下仍等正常松键收尾。它们不修改macOS听写或其他应用设置。软件回放通过，本机已签名安装；真实系统按键效果见[#822](https://github.com/semantic-craft/responsay-macos/issues/822)，仍未验收。

已有`responsay://connect-koe`入口选择并连接Koe音源，保留现有socket配置。它不设置权限、模型或快捷键，也没有供Koe写入快捷键策略并读回生效结果的协议。把Responsay设置嵌入Koe时，状态与写入由Responsay拥有；不能跨进程直接改其preferences，也不能用诊断control模拟引擎代替正式App状态。

实际应用内音频方向如下。当前路径不是已证明存在的系统虚拟麦克风。

```mermaid
flowchart LR
    Device[录音豆真实声音] --> Koe[Koe采集并发送PCM]
    Koe --> Responsay[Responsay识别与处理]
    Responsay --> Cursor[原目标应用光标]
```

## 共享资料和接口

前三种内容模式读取同一份工作区，不各建资料库。Rust领域/服务/runtime拥有录音、原文、来源和派生结果，宿主渲染快照并发送意图。语音输入的识别与注入由Responsay拥有，不能在Koe重复识别同一段外部听写。

已有MCP的`list_records`、`search`和`get_record`可提供原文、分析及来源。分段包含text、originalText、时间与说话人，摘要与重点分别返回。`ask`会创建并保存新问答，不是只读读取已有分析。Agent只需读资料时应使用对应读取工具，不因为注册了16个工具就默认授予写入用途。

已有启动方式是在Koe源码目录运行`cargo run --package koe-cli -- mcp-stdio`，通过`--workspace <现有工作区>`沿用实际资料库。不得因开发实例路径不同而另建空库。实现位置见[现有MCP注册](../crates/koe-runtime/src/mcp_surface.rs)和[CLI文档](../README.md#cli-与-mcp)。

## 当前交付和验收

Koe 已在 Rust 领域层、持久化层、Runtime 快照层与 macOS SwiftUI 宿主落地四个正式模式工作区页面（随心闪记收件箱/项目归类与原文优先导出、全天听记跨切片事件/暂停/未录音空档时间轴与集中复查、实时纪要三项覆盖率与往期会议切换、语音输入六步联动检查与区分手动打字/伴侣流的测试框）、分层侧栏纯导航以及所有记录按模式/收件箱筛选。前期本机交互稿为`~/Projects/_artifacts/koe/mode-workspaces/export/koe.html`；参考项目调研只阅读锁定源码，未验证其硬件或性能。

真实PCM、软件起止ACK和既有引导选源沿用原验收，不重跑。录音豆物理双击、Responsay实时识别和原光标上屏已在[Responsay #810](https://github.com/semantic-craft/responsay-macos/issues/810)闭环；签名安装的 `/Applications/Koe.app` 四工作区真机交互验收见[Koe #668](https://github.com/semantic-craft/koe/issues/668)。物理项目不能自动执行时保持未验收，不要求人工参与，不用合成PCM或代贴文字替代。
