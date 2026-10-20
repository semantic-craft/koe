# Android 执行计划

[打开 HTML](Main.html)。范围仅为 [Android #331](https://github.com/semantic-craft/koe/issues/331)，按工单已有的五个 PR 顺序交付。旧 [#38](https://github.com/semantic-craft/koe/issues/38) / [PR #62](https://github.com/semantic-craft/koe/pull/62) 是历史来源，不能另行开工。GitHub 是规格与交付事实来源，本目录只保存可继续维护的执行计划与留言。

## 使用

在仓库根目录运行（仅监听本机，60 分钟无请求自动退出）：

```bash
python3 -I docs/android-plan/board.py serve
```

打开 http://localhost:8767 。勾选、开发状态、设备结果、交付证据和留言由「保存本批更新」写回 `plan.json`，同时重生成 `Main.html`。页面不会关闭 GitHub 工单或发布评论。离线打开 HTML 时可编辑并下载新快照，但不会自动修改项目文件；正式接续以项目 `plan.json` 为准，不使用浏览器 localStorage。

## 依赖与并行分工

现有对话可作为集成人继续开发，无需为了阶段划分新开窗口。PR 按 A1 → A2 → A3 → A4 → A5 顺序交付；这里是集成交付顺序，不是所有准备工作都必须等待。

| 时段 | 集成人 | 可并行的独立工作 | 汇合条件 |
| --- | --- | --- | --- |
| A1 | 工具链、身份、Android 工程 | 只读核实四项系统适配与锁定依赖候选；准备验收场景 | 不改 Manifest、Gradle、pubspec、lock |
| A2 | 安全存储、控制器与手机入口 | 基于已确定接口准备 A4 的行为测试方案、样例音频 | 依赖及接口由集成人先定稿 |
| A3 | 前台服务、通知、录音生命周期 | 在独立文件准备 A5 验收脚本；A4 各适配可在隔离分支实现 | 不改共享入口，不提前合并 A4 |
| A4 | 原生注册、权限、依赖及控制器集成 | 转码、朗读、日历、快捷录音分别分配不重叠文件 | 四项适配归入同一 A4 PR，整体验证 |
| A5 | 构建安装、集中自动验收、最后 D3200 验收 | 结果整理可独立进行 | 同一设备只有一个驱动者；离线不算通过 |

Manifest、MainActivity、Gradle、pubspec/lock、scripts/ref、控制器接线、ROADMAP 与 plan.json 由集成人协调。一次只给一个任务指定这些文件的写权限。A3 的前台启动约束必须在 A4 快捷录音集成前明确；A5 最终验收依赖 A1–A4 全部落地。现有 Android 开发副本的执行者必须先核对，避免另开重复 PR。

## 其他对话接续

1. 用 `git worktree list` 找到主工作区，读取本文件和 `plan.json`，核对 #331、开放 PR 与已有执行者。不要在不同 worktree 各建一份记录，也不要把旧快照当实时状态。
2. 选择 A1–A5；若已有执行对话，先核对归属。同一文件只有一个写入者，共享原生入口和依赖锁文件顺序接管。
3. 使用**主工作区**的 `board.py update` 更新单个批次。它使用文件锁、按任务修订号和原子写入；保留既有留言。CLI 只合并指定字段，不覆盖整份 JSON。浏览器过期保存会拒绝并保留输入。

登记接手（将 A1 与署名换为实际值）：

```bash
python3 -I docs/android-plan/board.py update A1 --status active --owner "Android 工具链对话" --comment "已核对开放 PR，开始工具链与身份；下一步核对 SDK。"
```

记录一个检查项（把证据替换成实际事实，不照抄示例当验收）：

```bash
python3 -I docs/android-plan/board.py update A1 --check A1.1 --author "Android 工具链对话" --comment "在此填写实际检查结果、版本与证据位置。"
```

可用选项：`--status queued|active|blocked|done`、`--owner`、`--author`、`--evidence`、`--device pending|passed|failed|skipped`、`--device-evidence`、`--comment`、重复 `--check A1.1` / `--uncheck A1.1`。`done` 必须填写交付证据，非 pending 的设备结果必须填写证据或原因。代码交付、安装与真机验收不得互相替代。

更新后将 `plan.json` 和 `Main.html` 的改动按项目分支 + PR 流程交付；不同机器/clone 必须经 Git 同步。此工具没有云端自动同步，也不能替代文件归属协调。勾选与留言属于本次任务授权内的项目进度记录；不要在本文件或页面记录密钥。

## 维护页面

- 唯一内容源：`plan.json`；布局：`template.txt`；样式：`ds/koe/`。
- `Main.html` 是生成产物，不直接编辑；执行 `python3 -I docs/android-plan/board.py render` 重生成。
- `export/` 是设计稿校验导出的临时预览，不入 Git。正式交互入口是 `Main.html` 或本地服务。
- 本次 GitHub 快照对应 `plan.json` 的 snapshot。更新排期前先核对工单，不能仅凭标签判断解冻。
- 原生 Android 代码未在本计划任务中实施；初始所有批次待开始、设备待验收，已有开发副本的实际最新进度需执行者回填。
