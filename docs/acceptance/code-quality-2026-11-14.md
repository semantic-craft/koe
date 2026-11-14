# 2026-11-14 代码结构清理

本轮按实际调用关系清理未接入产品的旧实现，保留当前行为、资料格式和平台适配器。

## 判断标准与覆盖范围

采用 [Google 代码评审标准](https://google.github.io/eng-practices/review/reviewer/looking-for.html) 的正确性、设计适配、可理解性和避免过度设计原则；按 [Fowler 重构定义](https://refactoring.com/) 保持可观察行为；接口参考 [Rust API Guidelines](https://rust-lang.github.io/api-guidelines/checklist.html)。

检查原有九个 crate 和两个 Swift 宿主组的模块、依赖和调用者，深入核对旧子系统、MCP、投影和原生边界。并非逐行全面证明，不以删行数代表质量。

## 已验证的变更

- 删除无当前调用者的旧 MCP/ACP、Google/Copilot、分析队列、偏好与 memory hub 子系统；当前运行时的 16 个 MCP 工具、ProductStore 和 FFI 保留。
- 删除上述清理后无消费者的 koe-client-core crate，更新依赖与架构导航。
- UI 门禁改为检查实际 Swift DesignKit 颜色。旧检查读取已弃用 Rust 调色板，会漏掉真实界面的红色强调色和低对比度文字。两个变异用例在旧版失败，新版通过；真实门禁覆盖 70 个文件、零违规。

2026-11-14 在 Apple Silicon Mac 执行完整 scripts/check，退出 0，Rust、Clippy、脚本契约和 Swift 检查全部通过；原生部分 26 项测试通过。删除前后分别执行现有 CLI 9 项、运行时 MCP 1 项和 ProductStore 14 项行为测试，均通过。独立审查未发现阻断问题。

证据保存在 Projects/_artifacts/koe/code-quality-20261114，包括 combined-check.log、旧版失败及新版通过日志、调用者扫描和补丁。本轮未安装清理版，也未进行真实云端、物理双击或原光标写入验收。

## 保留的待处理发现

- 蓝牙退出前已由 `KoeRuntime` 单一投影 `device.teardownStopFramesHex` 并移除 Swift `pauseRecordFrame` 及 standby/recording 规则重复，物理 D3200 真实断连与退出时序仍待硬件实测。
- 后续 CQ2 收敛已将 `.koepack` 独立至 `crates/koe-engine/src/koepack.rs`，并清理未接入产品的 `Cicada` / `ContextReducer` / `MinutesReducer` / `RecordingLibrary` / `VisualSummaryCard`、`StreamingAsrPump` 桩与 `koe-client-services` 冗余重导出，保留 `legacy_restore` 与 `ProductWorkspace`。
- Responsay 的 RustSmartInputBridge 在 ABI 失败时由 Swift 重算部分规则；已确认静态规则差异，尚无运行时故障复现，需要专门的失败契约测试。
- 其余便捷 API、旧测试路径和安装脚本遗留选项需各自证明消费者与升级行为后再删。

真实光标写回和实体双击仍未验收。此次代码门禁通过不改变 PCMHW/#810/#822 的状态。
