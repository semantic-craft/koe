# 参与贡献

谢谢你愿意改进 Koe。本文说明怎么开工、怎么验证、怎么交付，以及我们定下的十条工程规则。项目文档以中文为主，代码、命令和标识符用英文。

## 开工前

1. 先读 [README.md](README.md) 与 [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) 了解四层纯 Rust + 原生 SwiftUI 架构，再读 [ROADMAP.md](ROADMAP.md) 确认当前范围。
2. 改动较大时先开 Issue 讨论范围和验收条件。工单与标签约定见 [docs/agents/issue-tracker.md](docs/agents/issue-tracker.md) 和 [docs/agents/triage-labels.md](docs/agents/triage-labels.md)。
3. 开工前查一下有没有开放 PR 在改同一个工单或同一批文件，一个工单同一时间只有一个在做的 PR。
4. 领域术语见 [GLOSSARY.md](GLOSSARY.md)，设计决策见 [docs/adr](docs/adr/)，设备协议见 [PROTOCOL.md](PROTOCOL.md)。

## 开发与验证

日常快速增量检查：

```bash
./scripts/verify-local.sh
```

提交与 PR 前的全量门禁：

```bash
./scripts/check
```

`./scripts/check` 会依次运行 Python 脚本契约测试、`scripts/verify-ui-principles.py` 原生 SwiftUI 界面原则门禁、`cargo test --workspace`、`cargo clippy --workspace --all-targets -- -D warnings` 与 `swift test --package-path platforms/macos`。CI 对代码改动运行同一入口；纯文档和进度更新的分流见 [docs/agents/ci-runner.md](docs/agents/ci-runner.md)。

涉及 macOS 宿主、C ABI、签名或安装包改动时，还需运行：

```bash
./scripts/install-macos.sh
/Applications/Koe.app/Contents/MacOS/Koe --verify-self
/Applications/Koe.app/Contents/MacOS/Koe --smoke-test
```

## 交付

- 只经分支 + PR 交付，只用 squash 合并；不直接推 `main`，不 force push，不改写已推送的历史。
- PR 正文按 [PR 模板](.github/PULL_REQUEST_TEMPLATE.md) 写三项验收：①回退测试（哪条测试改动前失败、改动后通过，没有就说明原因）；②真实使用情况（在真机、真实数据或真实界面上跑了什么、结果如何，没跑就写「未在真实环境验证」）；③没跑到的项目（跳过的检查、没覆盖的场景和原因）。只写「测试通过」不算验收。
- 只加改动前会失败、能拦住真实回归的行为测试；不加凑数、重复覆盖或只测实现细节的测试。
- 需要 D3200 物理录音豆或 iPhone/Mac 真机硬件环境的验收，写进 PR 的 `## 需要真机` 小节，并拆成独立工单；代码评审通过就先合并。
- **不要提交任何密钥。** 不把 API Key、token、`.env`/`.envrc` 写进代码、日志、Issue 或 PR。安全问题按 [SECURITY.md](SECURITY.md) 私下报告。

完整交付规则见 [docs/agents/delivery-rules.md](docs/agents/delivery-rules.md)。

## 十条规则

这些规则来自真实的返工和漏验。实现、评审或验收前先读一遍。

1. **只经分支 + PR 交付，只用 squash 合并，PR 和提交正文写三项验收。**
2. **一个工单同一时间只有一个在做的 PR。** 开工前查 `gh pr list -R semantic-craft/koe --state open --search "#<工单号>"`，PR 正文写 `Closes #N`。
3. **开发与验证构建不得触达个人 Keychain；签名或凭据改动必须验一次真实安装升级后的读取。**
4. **付费云端任务在请求前记录状态，结果持久保存后才算完成；结果未知时不盲目重发。**
5. **云端流式与文件上传必须遵守真实协议（如 RFC 6455 客户端掩码帧），严禁在生产环境用本地 RMS 音量伪造回退句子。**
6. **首次配置要从「没有任何密钥」的用户状态走通，未配密钥时在 Doctor 自检面板显式提示。**
7. **跨层严格遵守单向依赖与快照代次：** SwiftUI 宿主只通过 `koe_host_snapshot_json` 消费带 `generation` 的不可变快照并通过 `koe_host_dispatch_json` 发送单向命令，不在宿主层复制业务状态。
8. **SwiftUI 视图模块保持精简：** `platforms/` 下单个 `.swift` 源文件不超过 500 行，设置项说明收敛至 `InfoTip`（「?」气泡），由 `scripts/verify-ui-principles.py` 强制门禁。
9. **删除、覆盖、移动类脚本的路径保护要一次列全相等、互相包含、符号链接、大小写五种关系。**
10. **阻塞项要追到根因并清障；真机验收拆成独立工单，不闸住已过审的合并。**

新教训先记进 [docs/agents/lessons.md](docs/agents/lessons.md)，同一条教训在 3 个不同日子出现就升为 [AGENTS.md](AGENTS.md) 的硬规则。

## AI 编程助手

仓库根目录的 [AGENTS.md](AGENTS.md)（`CLAUDE.md` 指向它）是给编程 agent 的入口，规则与本文一致。用 agent 提交的 PR 同样要写三项验收。
