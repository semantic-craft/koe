# Koe 开发入口

Koe 采用「纯 Rust 内核 + 全原生平台宿主」四层架构，通过 macOS、iOS、Android 与 CLI/MCP 管理 D3200 录音、转写、纪要和检索。状态与接口以 [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) 为准，产品范围见 [README.md](README.md) 与 [ROADMAP.md](ROADMAP.md)。

开发进度在 `progress/`（`progress.json` 与生成的自包含 `index.html`），更新时按 progress-page 技能运行 `python3 progress/progress.py refresh|render|check`，生成物不手改。

## 四层架构与目录

| 层级 | 目录 | 职责与边界 |
| --- | --- | --- |
| 第一层 Engine | [crates/koe-engine](crates/koe-engine/)、[crates/koe-opus](crates/koe-opus/)、[PROTOCOL.md](PROTOCOL.md) | 无 I/O 的协议与领域规则：D3200、按文件排序的采集事件、`ProductWorkspace`、`ProductRecord`、`RequestKey`、`SourceRef`、纪要证据验证、待办/记忆审核与 BM25。Opus 包装静态链接锁定源码构建的 libopus |
| 第二层 Client | [crates/koe-client-base](crates/koe-client-base/)、[crates/koe-client-providers](crates/koe-client-providers/)、[crates/koe-client-services](crates/koe-client-services/) | `base` 提供文件锁和原子写；`providers` 负责真实 HTTP/WS、实时转写和有界任务；`services` 的 `ProductStore` 是唯一可写工作区，音频文件独立保管 |
| 第三层 Runtime & Host API | [crates/koe-runtime/src](crates/koe-runtime/src/)、[crates/koe-host-api](crates/koe-host-api/) | 8 个领域目录为 `capture`、`device`、`mcp_surface`、`observability`、`processing`、`projection`、`speech`、`workspace`。Rust 持久化后发布不可变 `generation` 快照，C ABI v2 导出 16 个符号 |
| 第四层 Native Hosts & CLI | [apple-shared](platforms/apple-shared/)（`KoeAppleCore`、`KoeMacUI`）、[macOS](platforms/macos/)、[iOS](platforms/ios/)、[Android](platforms/android/)、[CLI](crates/koe-cli/) | macOS 使用 `KoeMacUI`，`KoeiOSApp` 复用无界面依赖的 `KoeAppleCore`，Android 通过 JNI 接 Rust 并由 Compose 渲染。宿主负责系统 I/O 和界面草稿。CLI/MCP 使用同一运行时契约和单写者工作区 |

## 运行与测试

- 快速增量验证用 `./scripts/verify-local.sh --quick`，包含 `test_host_contracts.py`、`check_docs.py`、进度页、UI 原则及 Rust 编译和 Clippy。全量入口 `./scripts/check` 另跑 Rust 测试与形式状态模型，并按本机环境运行 Apple SwiftPM 和桌面 JVM/JNI 测试。
- CI 必过 `test` 检查覆盖文档门禁；`swiftlint`、`ios`、`android`（含 Android Compose Lint）和 `lint-scripts`（Ruff、ShellCheck）按改动分流。入口与审查准则见 [CI 运行环境](docs/agents/ci-runner.md) 和 [代码审查标准](docs/agents/code-review-standards.md)。
- 构建并安装签名版 macOS 应用：`./scripts/install-macos.sh`（静态链接 `libkoe_host_api.a` 构建通用/原生二进制，打包并 Developer ID 签名为 `/Applications/Koe.app`，自动执行 `--verify-self` 与 `--smoke-test`）。
- 打包并公证发布版 macOS 应用：`./scripts/release-macos.sh`（使用 `--options runtime --timestamp` 与 `platforms/macos/Release.entitlements`，经 `macos-notary` 与 `xw-notary` 提交公证并生成 zip 与 `SHA256SUMS.txt`）。
- 实现、评审或验收前先读 [CONTRIBUTING.md](CONTRIBUTING.md) 的十条规则。
- 写 BLE、录音、音频或记忆/待办类代码前，先用 `scripts/ref search` 检索上游、omi 和锁定版本依赖的同类实现，引用 `路径:行号` 再写；细则见 [docs/agents/reference-code.md](docs/agents/reference-code.md)。

## 硬规则

1. **只经分支 + PR 交付，只用 squash 合并。** 不直接推 `main`，不用 merge commit；中断留下的 WIP 提交留在分支上，合并时 squash 掉。
2. **禁止 force push。** 不 rebase、不改写已推送历史、不改别人的分支；要更新就追加提交。
3. **每个 commit 正文和 PR 都写三项验收：** ①回退测试：哪条测试改动前失败、改动后通过，没有就说明为什么；②真实使用情况：在真机、真实数据或真实界面上跑了什么、结果如何，没跑就写「未在真实环境验证」；③没跑到的项目：跳过的检查、没覆盖的场景和原因。只写「测试通过」不算验收，旧记录不能充当这次的证据；squash 时把三项带进合并提交正文。
4. **不碰密钥。** 不读、不写、不打印任何密钥、token、`.env`/`.envrc`；不把密钥写进代码、日志、评论或 PR。
5. **测试必须在修复前失败。** 只加改动前会失败、能拦住真实回归的行为测试；不加凑数、重复覆盖或只测实现细节（内部常量、调用次数、源码字符串）的测试。
6. **一个文件同一时间只有一个写入者。** 一个工单只有一个在做的 PR；并行工作不得改同一文件，开工前查开放 PR 有无同文件冲突。
7. **需要真机的步骤单独开工单。** Mac、iPhone/iPad、Android 真机及签名安装、GUI 或录音豆验收写进 PR 的 `## 需要真机`，拆成独立 `ready-for-human` 工单。代码过审后先合并。
8. 新教训先记进 [docs/agents/lessons.md](docs/agents/lessons.md)（出处、修复、Seen 计数），够分量的再补进 [CONTRIBUTING.md](CONTRIBUTING.md) 的十条规则；同一条教训在 3 个不同日子出现，就升为本节规则。
9. **异步测试和真机场景都等确定的完成状态再断言。** 要读的结果如果在 I/O 或另一段异步流程之后才写出，就等到那个结果本身出现，不拿中间状态当完成信号；修这类问题要在改前把失败稳定复现出来。
10. **零生产假数据与零跨层胶水。** 生产态禁止用本地 RMS 伪造转写或用 `/usr/bin/curl` 子进程发请求。SwiftUI 与 Compose 从 `koe_host_session_snapshot_json`（Android 经 JNI）消费带 `generation` 的快照，向 Rust 发意图和适配器事件，禁止复制业务规则或状态字段。

完整原文见 [docs/agents/delivery-rules.md](docs/agents/delivery-rules.md)。

## 工单与 agent 协作

- 工单统一用 `semantic-craft/koe` 的 GitHub Issues（[docs/agents/issue-tracker.md](docs/agents/issue-tracker.md)），分流标签见 [docs/agents/triage-labels.md](docs/agents/triage-labels.md)，领域文档布局见 [docs/agents/domain.md](docs/agents/domain.md)。
- 贡献流程、PR 模板与安全报告：[CONTRIBUTING.md](CONTRIBUTING.md)、[PR 模板](.github/PULL_REQUEST_TEMPLATE.md)、[SECURITY.md](SECURITY.md)。
