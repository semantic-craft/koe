# 参与贡献

谢谢你愿意改进 Koe。本文说明怎么开工、怎么交付，以及我们踩过坑后定下的十条规则。项目文档以中文为主，代码、命令和标识符用英文。

## 开工前

1. 先读 [README](README.md) 跑起来，再读 [ROADMAP](ROADMAP.md)：冻结区里的功能（P3、外部 AI 接入、Mac 双端同步等）暂不接 PR。Android 已按 [#331](https://github.com/semantic-craft/koe/issues/331) 解冻，范围限 Pixel 11 Pro / Android 17，子工单 #336–#345；Android 改动用 `scripts/android-check` 在 Pixel 上跑 [integration_test/android](integration_test/android/) 的场景。
2. 改动较大时先开 Issue 讨论范围和验收条件。工单与标签约定见 [docs/agents/issue-tracker.md](docs/agents/issue-tracker.md) 和 [docs/agents/triage-labels.md](docs/agents/triage-labels.md)。
3. 开工前查一下有没有开放 PR 在改同一个工单或同一批文件：一个工单同一时间只有一个在做的 PR。
4. 领域术语见 [GLOSSARY](GLOSSARY.md)，设计决策见 [docs/adr](docs/adr/)，界面规范见 [docs/design/ui-guidelines.md](docs/design/ui-guidelines.md)，设备协议见 [PROTOCOL](PROTOCOL.md)。

## 开发与验证

```bash
flutter pub get
```

```bash
scripts/check
```

`scripts/check` 运行 `flutter analyze` 和 `flutter test`，与 CI 相同。要逐文件确认跑了哪些测试，用 `flutter test --reporter expanded`。改动 BLE、播放、音频转换、JSON 存储或问答检索时，再跑一次 `scripts/perf-check` 并把数字写进 PR。

## 交付

- 只经分支 + PR 交付，只用 squash 合并；不直接推 main，不 force push，不改写已推送的历史。
- PR 正文按 [PR 模板](.github/PULL_REQUEST_TEMPLATE.md) 写三项验收：**①回退测试**（哪条测试改动前失败、改动后通过，没有就说明原因）；**②真实使用情况**（在真机、真实数据或真实界面上跑了什么、结果如何，没跑就写「未在真实环境验证」）；**③没跑到的项目**（跳过的检查、没覆盖的场景和原因）。只写「测试通过」不算验收。
- 只加改动前会失败、能拦住真实回归的行为测试；不加凑数、重复覆盖或只测实现细节的测试。
- 需要 iPhone/Mac 真机、安装包或录音豆的验收，写进 PR 的 `## 需要真机` 小节，并拆成独立工单；代码评审通过就先合并。
- **不要提交任何密钥。** 不把 API Key、token、`.env`/`.envrc` 写进代码、日志、Issue 或 PR。安全问题按 [SECURITY.md](SECURITY.md) 私下报告。

完整交付规则见 [docs/agents/delivery-rules.md](docs/agents/delivery-rules.md)。

## 十条规则

这些规则来自真实的返工和漏验。实现、评审或验收前先读一遍。

1. **只经分支 + PR 交付，只用 squash 合并，PR 和提交正文写三项验收。**
2. **一个工单同一时间只有一个在做的 PR。** 开工前查 `gh pr list -R semantic-craft/koe --state open --search "#<工单号>"`，PR 正文写 `Closes #N`。
3. **开发与验证构建不得触达个人 Keychain；签名或凭据改动必须验一次真实安装升级后的读取。**
4. **付费任务在请求前记录状态，结果持久保存后才算完成；结果未知时不盲目重发。**
5. **云端上传要检查序列化后的真实字节，并至少用授权测试音频跑一次真实服务。**
6. **首次配置要从「没有任何密钥」的用户状态点击走通。**
7. **异步测试要覆盖真实时序：** 带 I/O 的对象在 `runAsync` 里构造；模拟重启前等前一实例写完；并发用 Completer 控制交错；原生流失败后不能按输入帧立即重试，旧请求收尾不得清除新请求的失败状态。
8. **判断哪些测试文件跑过，用 `--reporter expanded` 或 json，不看 compact 日志。** compact 输出会覆盖进度行，日志里缺文件不等于没跑。
9. **删除、覆盖、移动类脚本的路径保护要一次列全相等、互相包含、符号链接、大小写五种关系。**
10. **阻塞项要追到根因并清障；真机验收拆成独立工单，不闸住已过审的合并。**

新教训补进上面的列表；同一条教训在 3 个不同日子出现，就升为 [AGENTS.md](AGENTS.md) 的硬规则。

## AI 编程助手

仓库根目录的 [AGENTS.md](AGENTS.md)（`CLAUDE.md` 指向它）是给编程 agent 的入口，规则与本文一致。用 agent 提交的 PR 同样要写三项验收。
