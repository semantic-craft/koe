# 项目教训

实现、评审或验收前阅读相关条目；用户纠正、返工或漏验暴露可复用教训后补记。
当前仅保留模板，尚未整理经核实的教训；这不表示项目从未出现问题。

## 记录模板

复制下列模板新增条目，已有同类条目则更新原条。未知的提交、原因或验收结果明确写“待核实”。
同一事件的多次修复、测试重跑不增加复发次数；只统计有独立证据的再次发生。
记录保留可复用的原因与证据定位；凭据、私人资料及完整日志留在各自获准的位置。

```markdown
### <教训标题>

**<一句话说明下次应遵守的规则。>**

- 起因与后果：<触发条件、原因、用户可感知的影响；关联 issue 或引入提交，未知则写待核实。>
- 修复与证据：<修复提交或 PR、回归检查与实际验收证据；区分已验证和未验证的部分。>
- 正确做法（Done right）：<下次的具体做法；链接到防复发代码、检查或所属规范。>
- 复发记录：Seen <N>x (<YYYY-MM-DD, ...>)；<每次独立发生的证据；修复提交数与重试次数不计入。>
```

### 逐像素对照才能抓住主题构造形态差异

**重构主题时"字段值相同"不等于"ThemeData 相同"；视觉回归必须逐像素对照。**

- 起因与后果：2026-10-15 挑回 87d5d8c token 层时，把 `const ColorScheme.light(...)` 换成 `ColorScheme.light().copyWith(...)`，抽查字段（surface/primary/onSurface/outline）全等，但无参 `ColorScheme.light()` 在当前 Flutter 版本会留下一批 NULL 字段，设置页文字变纯黑、下拉与分隔线偏色；字节级对比 9/14 张截图全同的假象下 5 张已偏。
- 修复与证据：改回全参构造、经 token 取值；`build/ui-evidence/spec-06/` 下 14 张 before/after 截图逐像素全同（`flutter test --dart-define=RECORDING_PREVIEW_DIR` 抓图 + 逐字节 RGBA 对照）。
- 正确做法（Done right）：主题重构以截图基线先行；对照要像素级而非抽查字段，构造器形态（无参 vs 全参、const 与否）本身是行为面。
- 复发记录：Seen 1x (2026-10-15)。

### 并排工作区需要独立的导航语义边界

**嵌套 Navigator 与可交互侧栏并排时，必须验证路由外的控件仍在语义树中。**

- 起因与后果：2026-10-15 将录音列表和详情并排后，视觉与点击正常，但详情路由会遮掉左侧语义；单纯布局测试没有覆盖这一点。
- 修复与证据：为 Navigator 增加独立 Semantics 容器，录音行标注 button；`test/recording_detail_test.dart` 的桌面回归检查导航语义仍可见。后续定位剩余桥接错误为 Slider 浮层孤立节点（见下条），原生回归已 0 错误；完整 VoiceOver 尚未人工验收，见 `docs/ui-workspace-validation.md`。
- 正确做法（Done right）：同时验证宽/窄窗口、真实可达导航与 Semantics；widgets 语义通过不等于原生读屏验收。
- 复发记录：Seen 1x (2026-10-15)。

### 第二个同类引擎落地时应收拢机制，而不是再复制一份

**接入与现有引擎同形的新引擎时，先收拢共享机制再接线；复制现有实现的成本（含随后的统一返工）总是被低估。**

- 起因与后果：2026-10-15 接豆包（00be6ef）时按 Qwen 现状复制了一份内存队列（`_pendingDoubao`/`_doubaoStarted`/`_pumpDoubaoJobs`）和一份约 130 行的 `_DoubaoSettings` 表单，当时认为"照抄最快"；22 分钟后 c486ea6 就不得不把两条并行队列（连同 Moss 路径）收拢成单一 `DeferredFileJobs`，两轴评审又以 7 处 provider 分支与重复表单立案，复制体被付费两次。
- 修复与证据：c486ea6 统一延迟文件任务机制（既有用例零修改通过）；本分支 3dd27d2 将控制器 provider 分支收进 per-provider 引擎适配记录、3df423a 把两份云端表单并为一个数据参数化组件，`engine_lineup` 等既有测试零修改全绿。
- 正确做法（Done right）：当第二份同形实现（队列、表单、凭据读写）即将出现时，先抽共享机制/数据参数化，再接新引擎——"新增引擎是数据项而非新界面"应在接入提交里就成立，而不是留给下一次重构；估期时把"复制 + 日后收拢"记为双倍成本。
- 复发记录：Seen 1x (2026-10-15)。

### 孤立语义节点只能靠逐帧更新流回归抓住

**判断原生 AXTree 健康不能只看 settle 后的语义树；必须检查逐帧发送引擎的序列化更新批次。**

- 起因与后果：2026-10-15 录音工作台切路由时 macOS 报 `Failed to update ui::AXTree`（上游 flutter/flutter#190357，Material Slider 数值气泡浮层经全局 Overlay 送出孤立节点）。settle 后的语义树检查通过，问题只存在于过渡帧的更新批次。
- 修复与证据：`lib/ui/widgets/inline_player.dart` 用 `Overlay.wrap` 把滑块浮层限制在自身子树，导航与动画保留。`test/macos_accessibility_update_test.dart` 重载 `createSemanticsUpdateBuilder` 记录每批 updateNode 边并做根可达检查：撤销修复时失败（孤儿 id 60/84/108），恢复后通过；`scripts/check-macos-accessibility.py` 实测 9 步 0 错误（`build/ui-evidence/ax-native.log`）。
- 正确做法（Done right）：涉语义的改动至少覆盖宽/窄窗口、settle 树、逐帧序列化更新与原生读屏四层；前两层通过不代表后两层通过。
- 复发记录：Seen 1x (2026-10-15)。
