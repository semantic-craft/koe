# Koe 协作上下文
- 项目目标：随时随地记录想法，同时保留灵活接入各种 system prompt、让 AI 处理这些想法的能力。
- 阶段：协作层 P1 试点仓。
- 约束：D-0116（GitHub 唯一事实源）、D-0117（协作协议）；Koe Android 部分暂停（#38 #62），本协作不接 Android；只加改动前会失败的测试；不 force push / rebase。

## 真机验收

Koe 的 iPhone 真机验收由用户本人做（用户定 2026-10-16 21:25）；`needs-device-test` 标签表示等用户真机验收。ZCode 的本机工作分两条路径：Perplexity 只读验证（不改文件、不提交，见 AGENTS.md「Perplexity × Helios ZCode 本机验证契约」）和 Dot 编码派发（隔离检出内改码、经分支 PR 交付，见 docs/agents/project-dispatch.md）；两条都不替用户做真机步骤。
