# Koe 开发入口

Koe 是 Flutter 写的 iOS/macOS 应用，脱离飞书直接管理安克 soundcore Work（D3200）录音豆：BLE 连接、取回录音、指定模型转写与分析，并逐步做成手机优先的个人记录与持续事项工具（录音 + 地点 + 待办 + 日记，可交给 AI）。产品身份以 [pubspec.yaml](pubspec.yaml) 和 [README](README.md) 为准；当前做什么、冻结什么见 [ROADMAP](ROADMAP.md)。

## 目录

| 改动 | 入口 |
| --- | --- |
| BLE/Wi-Fi 通信、帧协议与解密 | [PROTOCOL](PROTOCOL.md)、[lib/ble](lib/ble/)、[lib/wifi](lib/wifi/)、[lib/protocol](lib/protocol/)、[lib/crypto](lib/crypto/) |
| 录音、转写与状态 | [lib/audio](lib/audio/)、[lib/ai](lib/ai/)、[lib/state](lib/state/) |
| RecorderController 的各块功能 | [lib/state/recorder](lib/state/recorder/)：每块一个 part 文件（播放、本机录音库、地点、Mac 归档、主题、转写任务、转写文字、实时转写、设置、录音豆连接、录音豆文件），类本体、构造与共享状态留在 [recorder_controller.dart](lib/state/recorder_controller.dart)。用到别块的成员，在该 mixin 顶部「Provided by…」段加抽象声明 |
| 个人记录：时间线条目、待办、项目、日记、问答 | [lib/state/context](lib/state/context/)，控制器接线在 [lib/state/recorder/context.dart](lib/state/recorder/context.dart)；真机项写进 [final-device-pass](docs/acceptance/final-device-pass.md) |
| 界面与平台接入 | [lib/ui](lib/ui/)、[lib/platform](lib/platform/)，再读 [ios](ios/)、[macos](macos/)、[darwin](darwin/) |
| 签名、安装脚本、系统 Keychain 凭据 | [skills/verify-koe/SKILL.md](skills/verify-koe/SKILL.md)，验收含真实安装升级读取 |
| 测试 | [test](test/) |
| 术语、ADR、工单与标签 | [GLOSSARY](GLOSSARY.md)、[docs/adr](docs/adr/)、[docs/agents](docs/agents/) |

## 运行与测试

- `flutter pub get`、`flutter analyze`、`flutter test`；CI（[.github/workflows/ci.yml](.github/workflows/ci.yml)）在每个 PR 和 main 推送上跑这三步，Flutter 3.47.7，运行在用户自己的 Mac（自托管运行机，见 [ci-runner](docs/agents/ci-runner.md)）。
- 要逐文件确认跑过哪些测试，用 `flutter test --reporter expanded`；终端默认 compact 输出会覆盖进度行（见 [lessons](lessons.md)「compact 日志里缺文件不等于没跑」）。
- 验证：`check`（运行 `scripts/check`：`flutter analyze` 与 `flutter test`；依赖先按上条 `flutter pub get` 装好，真机、签名与安装验收不在其中）。
- 性能：`scripts/perf-check`（约 2 分钟，不在 `check` 里）在本机以 profile 模式跑 [integration_test/perf](integration_test/perf/) 的场景，按 `thresholds.json` 判定；屏幕需解锁，窗口进不了前台时超时退出。改动 BLE、播放、音频转换、JSON 存储或问答检索时跑一次，把数字写进 PR。
- 构建、真机运行与安装脚本按 [README](README.md)；[scripts](scripts/) 运行前核对目标设备和副作用。
- 实现、评审或验收前先读 [lessons](lessons.md) 顶部的十条规则。
- 写 BLE、录音、音频或记忆/待办类代码前，先用 `scripts/ref search` 检索上游、omi 和锁定版本依赖的同类实现，引用 `路径:行号` 再写；何时用、语料和存放位置见 [reference-code](docs/agents/reference-code.md)。

## 硬规则

1. **只经分支 + PR 交付，只用 squash 合并。** 不直接推 main，不用 merge commit；中断留下的 WIP 提交留在分支上，合并时 squash 掉。
2. **禁止 force push。** 不 rebase、不改写已推送历史、不改别人的分支；要更新就追加提交。
3. **每个 commit 正文和 PR 都写三项验收：** ①回退测试：哪条测试改动前失败、改动后通过，没有就说明为什么；②真实使用情况：在真机、真实数据或真实界面上跑了什么、结果如何，没跑就写「未在真实环境验证」；③没跑到的项目：跳过的检查、没覆盖的场景和原因。只写「测试通过」不算验收，旧记录不能充当这次的证据；squash 时把三项带进合并提交正文。
4. **不碰密钥。** 不读、不写、不打印任何密钥、token、`.env`/`.envrc`；不把密钥写进代码、日志、评论或 PR。
5. **测试必须在修复前失败。** 只加改动前会失败、能拦住真实回归的行为测试；不加凑数、重复覆盖或只测实现细节（内部常量、调用次数、源码字符串）的测试。
6. **一个文件同一时间只有一个写入者。** 一个工单只有一个在做的 PR；并行工作不得改同一文件，开工前查开放 PR 有无同文件冲突。
7. **需要真机的步骤单独开工单。** 要 iPhone/Mac 真机、安装包、GUI、硬件或录音的验收写进 PR 的 `## 需要真机` 小节，并拆成独立「需要真机」工单；代码评审通过就先合并，不让真机闸住后续工作。
8. 同一条教训在 lessons.md 出现 3 个不同日子，就升为本节规则，并在 lessons.md 注明去向。

完整原文（含阻塞链所有权、本机待办清单规则）见 [docs/agents/delivery-rules.md](docs/agents/delivery-rules.md)。

## 工单与 agent 协作

- 工单统一用 semantic-craft/koe 的 GitHub Issues（[issue-tracker](docs/agents/issue-tracker.md)），分流标签见 [triage-labels](docs/agents/triage-labels.md)，领域文档布局见 [domain](docs/agents/domain.md)。
- 各 agent 的派发合同（原文移入 docs/agents/，以该文档为准）：
  - Perplexity × Helios ZCode 只读本机验证：[zcode-verification](docs/agents/zcode-verification.md)
  - Dot 编码派发（`project_run`）：[project-dispatch](docs/agents/project-dispatch.md)
  - DOTS（ChatGPT agent dot）规则，含「不做 Android」：[dots-rules](docs/agents/dots-rules.md)
