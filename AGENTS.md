# Koe 开发入口

Koe 是对标 [`metasequoiaime/msime`](https://github.com/metasequoiaime/msime)「纯 Rust 内核 + 全原生平台宿主」四层分离架构的 macOS 应用（iOS 为后续宿主），脱离飞书直接管理安克 soundcore Work（D3200）录音豆，完成 BLE 连接、录音取回、真实云端流式转写、结构化纪要与个人上下文索引。架构权威规范见 [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)，产品身份以根 [Cargo.toml](Cargo.toml) 和 [README.md](README.md) 为准，当前路线见 [ROADMAP.md](ROADMAP.md)。

开发进度在 `progress/`（`progress.json` 与生成的自包含 `index.html`），更新时按 progress-page 技能运行 `python3 progress/progress.py refresh|render|check`，生成物不手改。

## 四层架构与目录

| 层级 | 目录 | 职责与边界 |
| --- | --- | --- |
| 第一层 Engine | [crates/koe-engine](crates/koe-engine/)、[crates/koe-opus](crates/koe-opus/)、[PROTOCOL.md](PROTOCOL.md) | 无 I/O 的协议与领域规则：D3200、按文件排序的采集事件、`ProductWorkspace`、`ProductRecord`、`RequestKey`、`SourceRef`、纪要证据验证、待办/记忆审核与 BM25。Opus 包装静态链接锁定源码构建的 libopus |
| 第二层 Client | [crates/koe-client-base](crates/koe-client-base/)、[crates/koe-client-providers](crates/koe-client-providers/)、[crates/koe-client-services](crates/koe-client-services/) | `base` 提供文件锁和原子写；`providers` 负责真实 HTTP/WS、实时转写和有界任务；`services` 的 `ProductStore` 是唯一可写工作区，音频文件独立保管 |
| 第三层 Runtime & Host API | [crates/koe-runtime](crates/koe-runtime/)、[crates/koe-host-api](crates/koe-host-api/) | `KoeRuntime` 接收意图，绑定录音/请求身份、安排 I/O、持久化后发布。`KOE_HOST_API_VERSION = 2`，含 BLE 与本机识别出站队列的 C ABI，panic 隔离、句柄管理、`generation` 不可变快照 |
| 第四层 Native Hosts & CLI | [platforms/apple-shared](platforms/apple-shared/)、[platforms/macos](platforms/macos/)、[crates/koe-cli](crates/koe-cli/) | SwiftUI 实现今天、记录详情、待办、记忆、问答与设置；Swift 仅保留界面草稿和平台句柄，单文件 `<= 500` 行。CoreBluetooth、文件选择器与 AVPlayer 作为平台适配器。CLI/MCP 使用同一 `KoeRuntime` 与存储，工作区为单写者 |
| 构建、签名与门禁脚本 | [scripts/check](scripts/check)、[scripts/verify-local.sh](scripts/verify-local.sh)、[scripts/verify-ui-principles.py](scripts/verify-ui-principles.py)、[scripts/install-macos.sh](scripts/install-macos.sh)、[scripts/sign-macos.sh](scripts/sign-macos.sh) | 本地快速增量校验、全量测试、原生 SwiftUI 界面原则门禁、Developer ID 签名与 `/Applications/Koe.app` 安装自检 |
| 术语、ADR、工单与标签 | [GLOSSARY.md](GLOSSARY.md)、[docs/adr](docs/adr/)、[docs/agents](docs/agents/) | 领域术语、架构决策记录与协作规范 |

## 运行与测试

- 快速增量验证：`./scripts/verify-local.sh --quick`（编译、Clippy、脚本契约与 UI 原则）；默认执行全量测试。
- 全量门禁：`check`（运行 `./scripts/check`：Python 脚本契约测试、`verify-ui-principles.py`、全量 `cargo test --workspace`、`cargo clippy --workspace --all-targets -- -D warnings` 与 `swift test --package-path platforms/macos`）。CI（[.github/workflows/ci.yml](.github/workflows/ci.yml)）在每个 PR 和 `main` 推送上运行此入口。
- 构建并安装签名版 macOS 应用：`./scripts/install-macos.sh`（静态链接 `libkoe_host_api.a` 构建通用/原生二进制，打包并 Developer ID 签名为 `/Applications/Koe.app`，自动执行 `--verify-self` 与 `--smoke-test`）。
- 实现、评审或验收前先读 [CONTRIBUTING.md](CONTRIBUTING.md) 的十条规则。
- 写 BLE、录音、音频或记忆/待办类代码前，先用 `scripts/ref search` 检索上游、omi 和锁定版本依赖的同类实现，引用 `路径:行号` 再写；细则见 [docs/agents/reference-code.md](docs/agents/reference-code.md)。

## 硬规则

1. **只经分支 + PR 交付，只用 squash 合并。** 不直接推 `main`，不用 merge commit；中断留下的 WIP 提交留在分支上，合并时 squash 掉。
2. **禁止 force push。** 不 rebase、不改写已推送历史、不改别人的分支；要更新就追加提交。
3. **每个 commit 正文和 PR 都写三项验收：** ①回退测试：哪条测试改动前失败、改动后通过，没有就说明为什么；②真实使用情况：在真机、真实数据或真实界面上跑了什么、结果如何，没跑就写「未在真实环境验证」；③没跑到的项目：跳过的检查、没覆盖的场景和原因。只写「测试通过」不算验收，旧记录不能充当这次的证据；squash 时把三项带进合并提交正文。
4. **不碰密钥。** 不读、不写、不打印任何密钥、token、`.env`/`.envrc`；不把密钥写进代码、日志、评论或 PR。
5. **测试必须在修复前失败。** 只加改动前会失败、能拦住真实回归的行为测试；不加凑数、重复覆盖或只测实现细节（内部常量、调用次数、源码字符串）的测试。
6. **一个文件同一时间只有一个写入者。** 一个工单只有一个在做的 PR；并行工作不得改同一文件，开工前查开放 PR 有无同文件冲突。
7. **需要真机的步骤单独开工单。** 要 iPhone/Mac 真机、安装包、GUI、硬件或录音的验收写进 PR 的 `## 需要真机` 小节，并拆成独立「需要真机」工单；代码评审通过就先合并，不让真机闸住后续工作。
8. 新教训先记进 [docs/agents/lessons.md](docs/agents/lessons.md)（出处、修复、Seen 计数），够分量的再补进 [CONTRIBUTING.md](CONTRIBUTING.md) 的十条规则；同一条教训在 3 个不同日子出现，就升为本节规则。
9. **异步测试和真机场景都等确定的完成状态再断言。** 要读的结果如果在 I/O 或另一段异步流程之后才写出，就等到那个结果本身出现，不拿中间状态当完成信号；修这类问题要在改前把失败稳定复现出来。
10. **零生产假数据与零跨层胶水。** 生产态禁止用本地 RMS 音量拼凑伪造中文句子，禁止用 `/usr/bin/curl` 子进程发请求，禁止在 SwiftUI 宿主复制业务规则或状态字段；宿主只渲染 `koe_host_snapshot_json` 返回的带 `generation` 视图快照并发送单向命令。

完整原文见 [docs/agents/delivery-rules.md](docs/agents/delivery-rules.md)。

## 工单与 agent 协作

- 工单统一用 `semantic-craft/koe` 的 GitHub Issues（[docs/agents/issue-tracker.md](docs/agents/issue-tracker.md)），分流标签见 [docs/agents/triage-labels.md](docs/agents/triage-labels.md)，领域文档布局见 [docs/agents/domain.md](docs/agents/domain.md)。
- 贡献流程、PR 模板与安全报告：[CONTRIBUTING.md](CONTRIBUTING.md)、[PR 模板](.github/PULL_REQUEST_TEMPLATE.md)、[SECURITY.md](SECURITY.md)。
