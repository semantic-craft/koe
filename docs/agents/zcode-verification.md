# Perplexity × Helios ZCode 本机验证契约

> 2026-10-19 从 AGENTS.md 原样移入（仅调整标题层级，正文未改）。文中「上文硬规则」「上文「阻塞链所有权」」指 [AGENTS.md](../../AGENTS.md) 的硬规则与 [delivery-rules.md](delivery-rules.md)。


首次走通：PR #55 @ `54b4b6e`（2026-10-16，结论 PASS）。

本合同是**只读**验证路径：ZCode 在此不改文件、不提交。Dot 已认领工单的编码派发（执行者可改文件、在分支上提交）走另一条路径，见 [docs/agents/project-dispatch.md](project-dispatch.md)；本节的限制不适用于那条路径，那条路径的边界以该文档为准。

1. **交接只走 PR 评论。** Perplexity 开 PR 后在该 PR 评论写 `## 本机待办`，不使用 `~/AgentBridge/`、`~/Projects/.sonori-handoff/` 等文件信箱。内容：
   - `repo: semantic-craft/koe`、`ref: <branch>@<完整 sha>`、可选 `cwd:`（默认仓库根 `~/Projects/koe`）
   - `- [ ] <命令>` 清单，按顺序执行（如 `flutter pub get` / `flutter analyze` / `flutter test`）
2. **派单。** 图灵在 Helios `~/Projects/koe` fetch 并切到该 sha（工作区须干净），然后**只经 zcode-dispatch**（Helios receiver `:7791`，项目名 `koe`）派给 ZCode；不得绕开 zcode-dispatch 直调 ZCode CLI。该路径上 ZCode 不改文件、不提交（仅限本只读合同）。
   - 主工作区正被另一单占用（多个 PR 同时有本机待办）时，不切主工作区分支，改用独立 worktree：`git worktree add --detach /tmp/koe-pr<N>-<短sha> <完整 sha>`，跑完 `git worktree remove --force` 清掉（首次用于 PR #56）。
   - 派单提示词须原样抄入第 3 条的回帖格式，不另写模板（PR #56 因提示词自带模板，回帖少了标题短 sha、`<details>` 日志和 `结论:` 行）。
3. **回帖。** ZCode 在同一 PR 评论 `## 本机结果 (<短 sha>)`：
   - 每项一行 `- ✅/❌ \`<命令>\` — 退出码 N`
   - 其下 `<details>` 折叠该命令日志末尾 ≤50 行，原样
   - 最后一行 `结论: PASS`（全部退出码 0）或 `结论: FAIL`
4. **核对。** 图灵对照 dispatch 会话结果核对回帖真实性与格式后再推进；合并仍按上文硬规则（squash，由亚里士多德执行）。

## 需要真机

需要 iPhone/Mac 真机、安装包、GUI、硬件或录音的步骤，单列在 PR / issue 的 `## 需要真机` 小节，留给用户手动完成，不进入 `## 本机待办` 默认路径。真机步骤不得闸住已过审代码的合并：评审通过后先合并，真机项拆成独立工单继续等用户（见上文「阻塞链所有权」）。

