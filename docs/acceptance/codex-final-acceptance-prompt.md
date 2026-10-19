# Koe 最终统一验收：给 Codex 的提示词

用法：确认 main 已包含本轮全部合并（手机录音 #206、自动整理 #207、续录取回 #208、主题笔记 #51/#76 重做），然后把下面整段原样发给本机 Codex。一次性环境按 `docs/acceptance/iphone-checklist.md`「一次性环境」先搭好。

```text
请对 Koe 做一次无人值守的最终真机验收，全程不要找我；做不到的记 UNCOVERED 并写原因，继续下一步。

准备
1. 在 ~/Projects/koe 执行 git fetch && git switch main && git pull --ff-only，记下 main 的完整 commit。
   未跟踪文件不用管；已跟踪文件有改动（git status --porcelain --untracked-files=no 有输出）就停在这里，
   只报告这条命令的输出，不要动任何文件。
2. 先完整读两份清单：docs/acceptance/iphone-checklist.md（第 0–20 步、17a、M1–M3）
   和 docs/acceptance/final-device-pass.md（第 5–15 步）。再 pua_setup(action="status")、pua_ready，ready=true 后打开 pua_screen。

执行顺序
A. 按 iphone-checklist.md 跑完第 0–14 步、M1、M2，再跑加测 15–20、17a、M3，但「收尾」先不做。
B. 接着在同一台 iPhone、同一个安装上跑 final-device-pass.md 第 5–15 步。这份清单是给人写的，按下面方式自动化：
   - 需要「说话」的地方：iPhone 开始录音后，在 Mac 上用 say -v Tingting 朗读，手机离 Mac 扬声器 20 厘米内。
     第 7 步的承诺台词用「我明天去买牛奶。孩子想要一台相机。同事小王说周五把资料发我。」，
     「后来那段」用「牛奶已经买好了。那件事改到下周吧。」。
   - 「从 App 切换器划掉 Koe」：用 xcrun devicectl device process launch --terminate-existing 重启代替，记为等效。
   - 「锁屏 1 分钟」：能用 pua_press_button 锁屏就做，否则 UNCOVERED。「来电 / Siri 打断」记 UNCOVERED。
   - 「断网」：打开飞行模式（USB 上的 iPhone Use 不受影响），做完立刻关掉，确认 Wi‑Fi 恢复。
   - 第 13 步手机录音、第 14 步自动整理、第 15 步录音豆续录（暂停→手机取回→录音豆继续录→再取回）要实做。
   - 「粘贴到外部 AI」那一项只验复制出的 Markdown 内容（读剪贴板），不要真的发给任何外部网站，记 UNCOVERED 的部分写明。
C. 最后执行 iphone-checklist.md 的「收尾」，另外把本次建的待办、项目、日记、提醒事项条目和日历事件一并删除（移到回收站或系统删除），
   提醒事项 / 日历里只删本次创建的那几条。

我授权你在本次验收中
- 改 iPhone 的自动锁定、文字大小、飞行模式（结束后全部改回）；操作 Mac 版 Koe；用 Mac 扬声器和麦克风。
- 在系统权限弹窗里允许 Koe 使用麦克风、定位、提醒事项、日历（第一次弹出时点允许；拒绝权限的那几项检查改用
  「设置 → Koe」关掉权限来测，测完再打开）。
- 在 iCloud 云盘「Koe验收」文件夹里建删文件；新建和删除本次产生的录音、主题、书签、待办、项目、日记、
  提醒事项条目、日历事件和备忘录。
- 模型调用（千问）全程合计不超过 30 次：清单 17/17a 共 ≤5 次，其余每个功能各验一次即可，不要为了重试反复调用。
  每次调用前后在结果表里累计计数。

不要做
- 不要清空回收站、不要彻底删除、不要删除录音豆上的录音、不要恢复出厂、不要动第 0 步基线之前就有的资料。
- 不要读出、打印、截图或记录配对信息和任何 Key；不要把音频或文字发给清单以外的任何服务。
- 不要改代码、不要 commit、不要 push、不要开 PR。

判定与证据
- 每一项按清单的「通过标准」判 PASS / FAIL / BLOCKED / UNCOVERED，不要写「部分通过」。
- FAIL 写实际看到的文字，附截图路径；卡住先截图重试一次，仍不行记 BLOCKED 继续。
- 声音用清单里的 ffmpeg silencedetect 方法核对，录下的 wav 用完删除。

交付
把结果写进 docs/acceptance/final-acceptance-results-<今天日期>.md（只写这个新文件，不提交），内容：
1. 构建身份：main 完整 commit、Koe 版本号、iPhone 型号与 iOS 版本、录音豆固件。
2. 汇总：PASS / FAIL / BLOCKED / UNCOVERED 各多少条；模型调用总次数。
3. 结果表：两份清单的每一步一行（步骤、结果、实际看到 / 证据路径）。
4. 按工单归纳：每个工单号一行，写「可以关闭 / 有失败 / 未覆盖」及依据步骤
   （#15 #16 #71 #92 #95 #96 #97 #133 #134 #135 #136 #137 #138 #139 #140 #141 #166 #168 #170 #174 #176 #177 #178 #179 #51 #76）。
5. 所有 FAIL 的复现步骤，一条一段。
最后在对话里只回复：文件路径、汇总那几行、FAIL 列表。
```

跑完后把 Codex 的回复（或结果文件路径）交回 Claude，由它核对证据、为每个 FAIL 开工单或修复，并关闭已通过的工单。
