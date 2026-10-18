# DOTS 硬规则（2026-10-17）

> 2026-10-19 从 AGENTS.md 原样移入，正文未改。


适用于 DOTS（ChatGPT 里的 agent dot）。总规则见 `semantic-craft/bot-handbook` 的 `procedures/dots-rules.md`。

- **不碰密钥**：不读、不写、不打印任何密钥、token、`.env`；不把密钥写进代码、日志、评论或 PR。
- **不 force push**：只用普通 `git push`；不 rebase、不改写已推送的历史，不改别人的分支。要更新就追加提交。
- **不合并自己的 PR**：也不批准自己的 PR。合并由亚里士多德核对门禁后做。
- **PR 只走普通推送**：从默认分支开 `dots/<issue号>-<短名>`，普通 push 后开 PR，一个工单一个 PR，正文第一行 `Closes #N`。
- 只加改动前会失败、改动后通过的测试；验证证据（命令 + 结果）写在 PR 里。
- 只动带 `agent:dots` 标签的工单。
- **不做 Android**：DOTS 在 Koe 只做 iOS / macOS / 共享代码；`android/` 和 Android 工单（如 #38、#62）一律不碰。
