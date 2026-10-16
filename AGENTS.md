# Koe 开发入口

产品身份以 [pubspec.yaml](pubspec.yaml) 和 [README](README.md) 为准。

| 改动 | 入口 |
| --- | --- |
| BLE/Wi-Fi 通信、帧协议与解密 | [PROTOCOL](PROTOCOL.md)、[lib/ble](lib/ble/)、[lib/wifi](lib/wifi/)、[lib/protocol](lib/protocol/)、[lib/crypto](lib/crypto/) |
| 录音、转写与状态 | [lib/audio](lib/audio/)、[lib/ai](lib/ai/)、[lib/state](lib/state/) |
| 界面与平台接入 | [lib/ui](lib/ui/)、[lib/platform](lib/platform/)，再读对应平台目录 |
| 签名、安装脚本、系统 Keychain 凭据 | [skills/verify-koe/SKILL.md](skills/verify-koe/SKILL.md)，验收含真实安装升级读取 |

在根目录运行 `flutter test`，现有用例在 [test](test/)。终端里默认的 compact 输出会原地覆盖进度行，日志只留下有 print 输出的文件，不能据此判断哪些文件跑过；要看到每个测试文件用 `flutter test --reporter expanded`，核对文件数见 [lessons](lessons.md)「compact 日志里缺文件不等于没跑」。构建和真机运行按 README；设备连接、音频接收和真实转写需另留证据。安装脚本在 [scripts](scripts/)，运行前核对其目标设备和副作用。
实现、评审或验收前读相关 [lessons](lessons.md)；出现可复用的纠正或漏验时更新原条目。

## 交付与验收（硬规则）

- 只经分支与 PR 交付，只用 squash 合并；不直接推 main，不用 merge commit，禁止 force push；中断的 agent 运行留下的 WIP 提交留在分支上，合并时 squash 掉。
- 每个 commit 正文和 PR 评论都要写清三项：①回退测试：哪条回归测试先失败、修后通过；没有就说明为什么。②真实使用情况：在真机、真实数据或真实界面上实际跑了什么、结果如何；没跑就写「未在真实环境验证」。③没跑到的项目：跳过的检查、没覆盖的场景和原因。只写「测试通过」不算验收，旧记录不能充当这次的证据；squash 合并时把这三项带进合并提交正文。
- 同一条教训在 lessons.md 里出现 3 个不同日子，就升为本节硬规则，并在 lessons.md 注明去向。
- **阻塞链所有权（2026-10-16 升硬规则，见 lessons.md「阻塞项要追根因并清障」）：** 任何已派工单项回来是阻塞态，图灵立即 (a) 追溯到根阻塞；(b) 自己清掉或派人清掉——代码评审已通过则先合并，把真机验收拆成独立「需要真机」／needs-device-test 工单，不让真机闸住依赖链；(c) 两者都做不到时，只向亚里士多德报告解开最多阻塞的那一个动作。不得只把阻塞交回用户停工；不得让执行人（如 Perplexity）空闲而不检查其他未阻塞工单。「不动等用户真机验收」= 不替用户做真机步骤，但必须另寻路径推进。

## Agent skills

### Issue tracker
工单统一使用 semantic-craft/koe 的 GitHub Issues。见 [docs/agents/issue-tracker.md](docs/agents/issue-tracker.md)。

### Triage labels
使用默认五种分流标签。见 [docs/agents/triage-labels.md](docs/agents/triage-labels.md)。

### Domain docs
采用单一领域文档布局。见 [docs/agents/domain.md](docs/agents/domain.md)。

## Perplexity × Helios ZCode 本机验证契约

首次走通：PR #55 @ `54b4b6e`（2026-10-16，结论 PASS）。

1. **交接只走 PR 评论。** Perplexity 开 PR 后在该 PR 评论写 `## 本机待办`，不使用 `~/AgentBridge/`、`~/Projects/.sonori-handoff/` 等文件信箱。内容：
   - `repo: semantic-craft/koe`、`ref: <branch>@<完整 sha>`、可选 `cwd:`（默认仓库根 `~/Projects/koe`）
   - `- [ ] <命令>` 清单，按顺序执行（如 `flutter pub get` / `flutter analyze` / `flutter test`）
2. **派单。** 图灵在 Helios `~/Projects/koe` fetch 并切到该 sha（工作区须干净），然后**只经 zcode-dispatch**（Helios receiver `:7791`，项目名 `koe`）派给 ZCode；不得绕开 zcode-dispatch 直调 ZCode CLI。ZCode 不改文件、不提交。
   - 主工作区正被另一单占用（多个 PR 同时有本机待办）时，不切主工作区分支，改用独立 worktree：`git worktree add --detach /tmp/koe-pr<N>-<短sha> <完整 sha>`，跑完 `git worktree remove --force` 清掉（首次用于 PR #56）。
   - 派单提示词须原样抄入第 3 条的回帖格式，不另写模板（PR #56 因提示词自带模板，回帖少了标题短 sha、`<details>` 日志和 `结论:` 行）。
3. **回帖。** ZCode 在同一 PR 评论 `## 本机结果 (<短 sha>)`：
   - 每项一行 `- ✅/❌ \`<命令>\` — 退出码 N`
   - 其下 `<details>` 折叠该命令日志末尾 ≤50 行，原样
   - 最后一行 `结论: PASS`（全部退出码 0）或 `结论: FAIL`
4. **核对。** 图灵对照 dispatch 会话结果核对回帖真实性与格式后再推进；合并仍按上文硬规则（squash，由亚里士多德执行）。

### 需要真机

需要 iPhone/Mac 真机、安装包、GUI、硬件或录音的步骤，单列在 PR / issue 的 `## 需要真机` 小节，留给用户手动完成，不进入 `## 本机待办` 默认路径。真机步骤不得闸住已过审代码的合并：评审通过后先合并，真机项拆成独立工单继续等用户（见上文「阻塞链所有权」）。

## 测试硬规则（2026-10-16 按用户要求去掉无收益测试）

- 只写改动前会失败、能拦住真实回归的行为测试；PR 里说明它在改动前怎样失败。
- 不加凑数、重复已有覆盖、或只测实现细节（内部常量、调用次数、复杂度、源码字符串）的测试；不加与风险不相称的性能基准、长时间压测或多轮循环。
- `## 本机待办` 和 `## 需要真机` 只列这次改动真正碰到、而 CI/已列的门禁覆盖不到的内容；一个命令已包含另一个时只列外层那一个。
- 花钱或丢数据的路径、只能在真机上验的项、安全扫描照常保留。

## DOTS 硬规则（2026-10-17）

适用于 DOTS（ChatGPT 里的 agent dot）。总规则见 `semantic-craft/bot-handbook` 的 `procedures/dots-rules.md`。

- **不碰密钥**：不读、不写、不打印任何密钥、token、`.env`；不把密钥写进代码、日志、评论或 PR。
- **不 force push**：只用普通 `git push`；不 rebase、不改写已推送的历史，不改别人的分支。要更新就追加提交。
- **不合并自己的 PR**：也不批准自己的 PR。合并由亚里士多德核对门禁后做。
- **PR 只走普通推送**：从默认分支开 `dots/<issue号>-<短名>`，普通 push 后开 PR，一个工单一个 PR，正文第一行 `Closes #N`。
- 只加改动前会失败、改动后通过的测试；验证证据（命令 + 结果）写在 PR 里。
- 只动带 `agent:dots` 标签的工单。
- **不做 Android**：DOTS 在 Koe 只做 iOS / macOS / 共享代码；`android/` 和 Android 工单（如 #38、#62）一律不碰。
