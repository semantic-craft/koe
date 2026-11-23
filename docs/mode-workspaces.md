# 三模式工作区

产品从“模式选择”进入随心闪记、全天听记、实时纪要，macOS 侧栏保留同名入口，移动端从原生标签页与模式入口进入。首页显示三个模式控制和当前状态，历史资料进入所有记录。打开工作区只查看内容，不自动启动采集。

三端 SwiftUI 与 Compose 页面读取统一的 Rust `workspaces` 投影。实现、自动化和物理设备的验收分别记录。

## 已确定的录音行为

- 普通录音键开始新会话时默认随心闪记。
- 全天听记与实时纪要需要在宿主明确开启本次模式。结束后释放会话选择。
- 重启不自动录音，显式模式选择只在当前会话有效。
- 页面导航与录音启停分开。一次选择一个主采集模式。

## 随心闪记

场景是临时想到的任务、想看的书、灵感和零碎想法，最终形成可继续推进的事情或项目线索。工作区围绕下列内容组织。

1. 收件箱收纳尚未整理或归属不明确的想法。
2. 原始转写保留时间、录音和来源，支持查看与校正。
3. AI分析独立显示这段话在说什么、可能要做什么，不能覆盖原文。
4. 行动与项目建议关联原话。用户可以确认或调整归属，不明确的内容先留收件箱。
5. 支持导出原文、分析和来源；Agent读取优先提供转写原文。

项目归类由 Rust 保存，支持单条与批量归类。待办与记忆审核继续保留各自的来源关系。

## 全天听记

粒度是一整天的上下文，不能把每个音频文件直接当成一件事情。目标页面包括有时间定位的原文时间线、跨分段语义事件、暂停与未录音空档、待办/承诺/决策/记忆建议、当日回顾，以及回到原话和音频的位置。

全天听记按五分钟分段，工作区投影合并同批事件并标出暂停与未录音空档，集中复查时仍可回到各段来源。

[TaoSheng固定版本README](https://github.com/0xCoach/TaoSheng/blob/6bcf05c333767aea775d6aee7c6d39d65602dc51/README.md)描述全天转写、事件和记忆。[DigestPrompt](https://github.com/0xCoach/TaoSheng/blob/6bcf05c333767aea775d6aee7c6d39d65602dc51/shared/src/commonMain/kotlin/app/resound/digest/core/DigestPrompt.kt#L119-L180)把事件关联到原文行范围。借鉴这些组织方式，不据此声称Koe的硬件、能耗或长时间场景已经通过。本次未运行该项目，未确认它提供MCP；其Agent导出不等同于MCP。

## 实时纪要

场景是一场当前讨论。宽屏并排显示实时原文和纪要，窄屏切换标签；原文、讨论要点、决策与行动保留来源定位。显示原文和纪要各自的处理覆盖与更新状态，结束后对完整已收到的内容整理，支持校正、回听和导出。

当前 Rust 与原生宿主的实现规则：

1. 界面统一称「实时纪要」，SwiftUI 与 Compose 渲染 Rust 快照，纪要请求由 Rust 管理。
2. Rust 只用定稿原文触发整理：首次满 3 段或等待 20 秒可请求，后续有新原文且距上次请求满 45 秒更新，已有在途任务时不叠加。
3. 每次请求绑定记录、原文版本与完整来源快照，追加原文不阻断已覆盖展示，原文修订使旧结果失效，失败保留已有纪要且不自动重发。
4. 停止并保存原文后完成一次最终整理，此时才生成待确认行动，实时更新不重复创建行动。

[Cicada固定版本Notes](https://github.com/wquguru/cicada/blob/f119ba618814cc43ebee60548795754010bcca40/Sources/Cicada/Notes.swift#L243-L340)以新增原文更新既有纪要，[NotesWindow](https://github.com/wquguru/cicada/blob/f119ba618814cc43ebee60548795754010bcca40/Sources/Cicada/NotesWindow.swift#L255-L285)区分宽屏并排与窄屏标签。这里只借鉴会话组织。本次未运行该项目；来源行存在检查不能证明结论在语义上正确。

实时工作区展示转写覆盖、纪要引用覆盖与停录后整理状态，按投影显示当前更新与往期会议。

## 共享资料和接口

三种模式读取同一份工作区，不各建资料库。Rust领域/服务/runtime拥有录音、原文、来源和派生结果，宿主渲染快照并发送意图。

已有MCP的`list_records`、`search`和`get_record`可提供原文、分析及来源。分段包含text、originalText、时间与说话人，摘要与重点分别返回。`ask`会创建并保存新问答，不是只读读取已有分析。Agent只需读资料时应使用对应读取工具，不因为注册了16个工具就默认授予写入用途。

在 Koe 源码目录运行 `cargo run --package koe-cli -- mcp-stdio`，可通过 `--workspace <现有工作区>` 沿用实际资料库。实现位置见 [MCP 工具注册](../crates/koe-runtime/src/mcp_surface/mod.rs) 和 [CLI 文档](../README.md#cli-与-mcp)。

## 当前交付和验收

三个模式工作区已接入 macOS、iOS 与 Android。三端共用项目、时间轴空档、纪要覆盖率和记录筛选的 Rust 规则。移动端另有宽屏布局、系统文件选择和分享，macOS 另有系统音频双路。模拟器及媒体夹具的证据见 [进度页](../progress/)。

实体录音豆和真实采集验收分别追踪在 macOS [#668](https://github.com/semantic-craft/koe/issues/668)、iOS [#775](https://github.com/semantic-craft/koe/issues/775) 和 Android [#777](https://github.com/semantic-craft/koe/issues/777)。
