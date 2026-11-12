# Koe: Rust 产品管线接力

A–F 记录前一轮目录迁移；其历史完成标记不能代替当前产品行为验收。当前以 Slice G、README 与架构文档为准。

本文件是 PStack 跨对话动态接力的全景路线图（对应 Lauren Tan `pstack` 的 `figure-it-out`、`sequence-verifiable-units`、`guard-the-context-window` 与动态 `Session pickup`）。
前序 V1/V2 队列不参与当前产品验收。
本队列只维护每个切片的用户/工程可感知结果（Outcome）与可证伪验收条件（Done Predicate）；**下一棒提示词绝不静态预写**，必须在每一棒收尾时根据真实代码变更、新发现的约束与上下文水位，通过 `scripts/pstack-relay advance` 动态合成。

- 总目标：以 Rust 持有录音、原文、纪要、待办、记忆和问答的完整状态，接通 macOS 今天、记录详情与全局问答；保留真实输入和原文证据。
- 架构主线：纯领域 ProductWorkspace → 唯一 ProductStore → KoeRuntime 编排 → C ABI v2 → SwiftUI 快照与意图；网络和平台 I/O 经适配器完成，按 record/request 身份回写。
- 参考实现/材料：`metasequoiaime/msime` 与 [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)
- 自动验收入口：`scripts/check`（及重构后对齐 `msime` 的 `scripts/verify-local.sh`）
- 决策账本（`show-me-your-work`）：`.scratch/pstack-relay/decisions.tsv`
- 动态交接胶囊：`.scratch/pstack-relay/handoff_capsule.json`
- 下一棒提示词快照：`.scratch/pstack-relay/NEXT_PROMPT.md`

---

## 现状病灶 vs MSIME 全原生目标架构对表（全仓盘点基线）

| 维度 | 当前 Koe 现状病灶（实测定位） | 对标 `metasequoiaime/msime` 的破坏性重构目标 |
| --- | --- | --- |
| 1. UI 技术栈与宿主形态 | Slice O–T 引入 `gpui-kit = "=0.9.0"`，带来 **8,922 行** `desktop/Cargo.lock`、Rust edition 2024 锁死、4,435 行单文件手绘 UI（`desktop/app/src/main.rs`），缺乏原生输入法组合、原生 Popover、无障碍支持，且无法复用到 iOS | 对齐 `msime` `2026-11-03-all-native-ui.md`，**彻底下线并删除 GPUI**；采用 `platforms/apple-shared` + `platforms/macos` AppKit + SwiftUI 原生宿主（macOS 14+ / iOS 17+ 共用视图包），经 `crates/koe-host-api` 静态链接 Rust |
| 2. 跨代死代码与旧壳层 | 残留 16,000+ 行无生产调用方的历史产物：`rust/koe_core_ffi`（4,368 行旧 C-ABI + 2,218 行 JNI + 3,461 行 `gen_bindings` 仅因 129 行 `opus_ffi.rs` 被引用）、`android/`（6,800 行坏掉的 Flutter 插件壳）、`darwin/`（旧生成桥）、`test/native/`、`tools/koe-mcp/`（2,200 行旧 Python MCP）及 12 个失效脚本 | 遵循 `subtract-before-you-add` 一次性物理清退全部废弃目录与失效脚本；保留 129 行 `opus` 安全桥，仿照 `msime/crates/host-api` 新建 `<= 500` 行的版本化 `crates/koe-host-api` |
| 3. Workspace 与 Crate 边界 | `rust/Cargo.toml` 与 `desktop/Cargo.toml` 双 workspace 割裂；`desktop/core/src/lib.rs` 单文件 **5,418 行**（零子模块），混合了协议重导出、存储、假 ASR、UI 页签枚举、Google 内存 mock 与 30 分支巨型 `dispatch` | 合并为根级单一纯 Rust `Cargo.toml`（零 UI 依赖，`unsafe_code = "deny"`，`[profile.dev] debug = 0, incremental = false`）；按 `msime` 状态所有权拆分为 `crates/koe-engine`、`koe-client-base`、`koe-client-core`、`koe-client-providers`、`koe-client-services`、`koe-runtime` 与 `koe-host-api` |
| 4. 领域模型重复与三层深拷贝 | 录音有 `OfflineFileEntry` / `RecordingEntry` / `RecordingAggregate` 三套；时间线有 `ContextItem` / `TimelineEntry` 两套；问答有 `AskSession` / `CopilotSession` 两套；`DesktopBeanHost` 与 `RecordingAggregate` 与 `WorkspaceProjection` 持三份重复状态，每次命令深拷贝 38 个字段；残留 `V2` 后缀 | 以 `RecordingAggregate`（含 `UtteranceSpine S1..Sn`）为唯一录音事实源，合并单一 `TimelineEntry` 与单一 `AssistantSession`，去掉全部 `V2` 历史后缀；`koe-runtime` 输出带 `generation: u64` 的轻量不可变快照 |
| 5. 生产路径混入假桩代码 | ① `StreamingAsrPump` 无真实 WebSocket，说话时按 RMS 能量生成 `"随心实时转写 #N: 语音能量 RMS=..."` 假句子写入用户文稿；② 空目录启动自动灌入合成法律/Rust 样例句；③ Wi-Fi SoftAP 按钮注入硬编码假字节帧；④ Copilot 在视图层调 `/usr/bin/curl` | 破坏性回退全部生产态假桩：未配凭据或断网时明确处于 `Unconfigured` / `OfflineBuffered`（只落盘真实音频，不造假字）；样例数据仅限 `--demo-seed` 或测试夹具；真实网络传输全部收进 `koe-client-providers` |
| 6. 原生 UI 组织与说明规范 | 4,435 行单文件手绘界面，50ms 定时器轮询 BLE；设置与控制台残存常驻解释文字 | 按 `msime` 的 `DesignKit.swift` + `SettingsRouter.swift` + 独立页面模块（单文件 `<= 500` 行）组织 SwiftUI；CoreBluetooth 委托直接通过 `koe-host-api` 触发代次快照更新；设置说明一律收进标题旁原生 Popover `?`（`InfoTip`） |

---

## 动态接力切片队列（Slice A → F）

### [x] Slice A: 全仓现状深潜、放弃 GPUI 确立 MSIME 全原生路线与 V3 动态接力队列就位
- **Playbook**: `Investigation` + `figure-it-out`
- **Outcome**: 完成 `rust/`、`desktop/`、脚本与根文档的三路代码级审计，剖析 `metasequoiaime/msime` 的内核与全原生 UI 路线（`2026-11-03-all-native-ui.md`），确立**放弃 GPUI、采用纯 Rust `crates/*` + `koe-host-api` + Apple 共享 SwiftUI 与 AppKit 原生宿主**的 [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)，将旧 20 切片归档至 `docs/pstack-relay-archive-v1-v2.md`，并在 `docs/pstack-relay.md` 激活 V3 破坏性重构接力队列（Slice A → F）。
- **Done Predicate**: `test -f docs/ARCHITECTURE.md && test -f docs/pstack-relay-archive-v1-v2.md && scripts/pstack-relay selftest`
- **Evidence**: docs/ARCHITECTURE.md;docs/pstack-relay.md;docs/pstack-relay-archive-v1-v2.md

### [x] Slice B: 大减法（Subtract First）——彻底移除 GPUI (`desktop/app`) 与 1.6 万行旧 FFI/Android/Python 死代码，建立根级单一纯 Rust Workspace
- **Playbook**: `Refactoring`
- **Outcome**: 按 subtract-before-you-add 执行 Slice B 大减法：彻底删除 GPUI 应用层 desktop/app、desktop/ble 与 desktop/Cargo.lock，将 129 行 opus_ffi.rs 独立为 crates/koe-opus 后物理删除 rust/koe_core_ffi 其余 1 万行旧 FFI/JNI/gen_bindings，删除 android/、darwin/、test/native/、tools/koe-mcp/ 与 12 个失效旧脚本，合并为仓库根级单一纯 Rust Cargo.toml 并跑通全量测试
- **Done Predicate**: test ! -d desktop/app && test ! -d android && test ! -d tools/koe-mcp && test ! -d rust/koe_core_ffi && cargo test --workspace --offline && ./scripts/check
- **Evidence**: Cargo.toml;crates/koe-opus/src/lib.rs;rust/koe_core/src/theme.rs;scripts/verify-local.sh;scripts/check

### [x] Slice C: 领域模型大一统与 `crates/koe-engine` + `crates/koe-client-{base,core}` 拆分（消除三套重复结构与 V2 后缀）
- **Playbook**: `Refactoring`
- **Outcome**: 执行 Slice C 领域模型大一统与核心 Crate 边界重构：(1) 按 docs/ARCHITECTURE.md 将 rust/koe_core 重组拆分为 crates/koe-client-base（hash、prng、原子文件读写与锁）、crates/koe-client-core（theme 令牌、偏好配置、MaterialPack）与 crates/koe-engine（协议、加密、音频、领域状态机），删除旧 rust/ 目录；(2) 消除重复领域模型与历史后缀：去掉 MeetingMinutesV2 / MaterialPackV2 / PackMinutesV2 的 V2 后缀，合并 ContextItem 与 TimelineEntry，收敛 RecordingEntry 冗余结构，清理 McpAcpOwnedRuntime、SliceMarkProbe、ScannedDevice 等死符号，同步更新 desktop/core 调用方并通过全工作区 Clippy 与测试
- **Done Predicate**: test ! -d rust && test -d crates/koe-engine && test -d crates/koe-client-base && test -d crates/koe-client-core && cargo clippy --workspace --all-targets --offline -- -D warnings && cargo test --workspace --offline && ./scripts/check
- **Evidence**: crates/koe-client-base/src/lib.rs;crates/koe-client-core/src/lib.rs;crates/koe-engine/src/lib.rs;scripts/verify-local.sh

### [x] Slice D: 拆解 `desktop/core` 为 `koe-client-{providers,services}`、`koe-runtime` 与 `koe-host-api`（版本化 C ABI），并回退全部生产假桩
- **Playbook**: `Feature` + `Refactoring`
- **Outcome**: 执行 Slice D 拆解 5,418 行 desktop/core 巨石并回退生产假桩：(1) 建立 crates/koe-client-providers（DashScope ASR/Qwen、OpenAI/DeepSeek、Google Tasks/Keep/Notebooks 真实协议与凭据探测）与 crates/koe-client-services（个人上下文时间线、晨报日记、待办同步与本机 MCP/ACP 服务）；(2) 建立 crates/koe-runtime（持有单一权威会话状态，输出带 generation: u64 的不可变视图快照）与对齐 msime/crates/host-api 的 crates/koe-host-api（<= 500 行版本化 C ABI）；(3) 彻底回退生产假桩（删除 StreamingAsrPump 的 RMS 假中文字句生成、删除 Wi-Fi SoftAP 假字节帧注入、删除新目录启动自动灌入假样例句）并物理删除 desktop/ 目录
- **Done Predicate**: test ! -d desktop && test -d crates/koe-client-providers && test -d crates/koe-client-services && test -d crates/koe-runtime && test -d crates/koe-host-api && cargo clippy --workspace --all-targets --offline -- -D warnings && cargo test --workspace --offline && ./scripts/check
- **Evidence**: crates/koe-client-providers/src/lib.rs;crates/koe-client-services/src/lib.rs;crates/koe-runtime/src/lib.rs;crates/koe-host-api/src/lib.rs

### [x] Slice E: 对标 MSIME 全原生 SwiftUI 宿主（`platforms/apple-shared` + `platforms/macos`）：`DesignKit`、`ViewRequestGeneration` 与「?」`InfoTip` 落地
- **Playbook**: `Feature`
- **Outcome**: 执行 Slice E 构建对标 MSIME 的 Apple 全原生 SwiftUI 宿主（platforms/apple-shared 与 platforms/macos）：(1) 建立 platforms/apple-shared Swift Package 与 platforms/macos 原生 App 容器，静态链接 libkoe_host_api.a 并桥接 crates/koe-host-api 版本化 C ABI；(2) 按单文件 <= 500 行模块化实现 DesignKit.swift、InfoTip.swift（标题旁 ? 原生 Popover，消除页面常驻解释灰字）、HostSessionStore.swift（ViewRequestGeneration 代次守卫）、SidebarView.swift、PlayerBarView.swift、TodayBentoView.swift、FormatsView.swift、AliyunMcpView.swift、SettingsDoctorView.swift、CopilotDrawerView.swift；(3) 支持 --verify-self 与 --smoke-test 原生自检命令，更新 scripts/install-macos.sh 与 scripts/verify-ui-principles.py，编译签名安装 /Applications/Koe.app 并通过全部门禁
- **Done Predicate**: python3 -B scripts/verify-ui-principles.py --mode all && ./scripts/install-macos.sh && /Applications/Koe.app/Contents/MacOS/Koe --verify-self && /Applications/Koe.app/Contents/MacOS/Koe --smoke-test && ./scripts/check
- **Evidence**: platforms/apple-shared/Package.swift;platforms/macos/Package.swift;scripts/install-macos.sh;scripts/verify-ui-principles.py

### [x] Slice F: 全仓文档同源重写（`AGENTS.md` / `README.md` / `ROADMAP.md`）、对抗审查（`interrogate`）、性能基准与终局收口
- **Playbook**: `Shipping`
- **Outcome**: 执行 Slice F 全仓文档同源重写（AGENTS.md / README.md / README.en.md / ROADMAP.md / CONTRIBUTING.md / GLOSSARY.md）、对抗审查（interrogate）、性能基准与终局收口：清除所有过时的 Flutter/Dart 与 GPUI 描述，与 docs/ARCHITECTURE.md（msime 全原生架构）完全对齐；更新 progress/progress.json 与 progress/index.html，确保 scripts/pstack-relay status --require-all-done 零警告通过
- **Done Predicate**: ./scripts/check && python3 progress/progress.py check && /Applications/Koe.app/Contents/MacOS/Koe --verify-self && /Applications/Koe.app/Contents/MacOS/Koe --smoke-test && ./scripts/pstack-relay status --require-all-done
- **Evidence**: AGENTS.md;README.md;README.en.md;ROADMAP.md;CONTRIBUTING.md;GLOSSARY.md;progress/progress.json;progress/index.html

### [x] Slice G: 接通 Rust 产品工作区与 macOS 三块主流程
- **Playbook**: `Feature` + `Refactoring` + `Shipping`
- **Outcome**: 今天、记录详情和全局问答共用一个持久化领域工作区；真实设备采集、离线/实时转写、证据纪要、待办/记忆审核、来源跳转与旧数据迁移接通原生宿主；故障恢复不串记录、不丢已完成结果。
- **Done Predicate**: ./scripts/check && python3 progress/progress.py check && /Applications/Koe.app/Contents/MacOS/Koe --verify-self && /Applications/Koe.app/Contents/MacOS/Koe --smoke-test
- **Evidence**: scripts/check PASS; installed /Applications/Koe.app; issue #587

### [x] Slice H: Dock 图标大小与系统对齐
- **Outcome**: 保留现有插画，校正打包留白并使用系统处理后的运行图标；更新本机日常安装版。
- **Done Predicate**: ./scripts/check && swift scripts/verify-app-icon.swift build/macos/AppIcon.iconset && codesign --verify --strict /Applications/Koe.app
- **Evidence**: /Applications/Koe.app; scripts/check PASS; issue #594; installed ICNS opaque frame 824px

### [x] Slice I: 修复未运行态 Dock 静态图标注册与重装部署 #600 至 #630
- **Playbook**: `Bug fix` + `interrogate` + `Shipping`
- **Outcome**: 修复 `scripts/install-macos.sh` 无 `Assets.car` 时误写 `CFBundleIconName`、非原子覆盖与缺少 `lsregister -f` 导致退出后 Dock 变白格占位图的问题；收敛路径守卫与 `renamex_np(RENAME_SWAP)` 同卷原子互换回滚；重装 Developer ID 签名版 `/Applications/Koe.app`（把 #600 至 #630 全量部署到位），并在未运行态完成 Dock 并排截图验收（#594）。
- **Done Predicate**: ./scripts/check && python3 progress/progress.py check && /Applications/Koe.app/Contents/MacOS/Koe --verify-self && /Applications/Koe.app/Contents/MacOS/Koe --smoke-test
- **Evidence**: scripts/install-macos.sh;scripts/cleanup_app_registrations.py;CDHash 4665f09f7d0353513efc1acab745f2dbfb8d3a25;Closes #594

### [x] Slice R1: 记录删除、30 天回收站与归档防误删保护
- **Playbook**: `Feature` + `interrogate`
- **Outcome**: 按用户排定的功能还原第一优先级落地 Slice R1（记录删除、30 天回收站与归档防误删保护，下一片紧接 Slice R2 转写原文分段编辑与说话人重命名合并）。在 crates/koe-engine/src/product/ 新增独立 trash.rs 子模块承载软删除时间戳 trashed_at_ms、恢复、彻底清除、30 天过期自动收敛与归档锁 archived 防误删不变量（软删记录自动移出今天主列表、BM25 搜索与全局问答上下文，恢复后原样归位）；在 ProductStore 与 KoeRuntime 确保仅在彻底清除或 30 天到期持久化成功后物理删除受管音频资产，活跃录音或排空中的记录拒绝删除；经 koe-host-api C ABI v2 快照与单向意图在 platforms/apple-shared 新增 TrashView.swift 并接通 TodayView.swift 与 RecordDetailView.swift 的归档锁定、即按软删加底部撤销条及回收站恢复与彻底清除。
- **Done Predicate**: ./scripts/check && cargo test --workspace --offline && swift test --package-path platforms/apple-shared && swift test --package-path platforms/macos && ./scripts/install-macos.sh
- **Evidence**: crates/koe-engine/src/product/trash.rs;crates/koe-runtime/src/trash.rs;platforms/apple-shared/Sources/KoeAppleShared/TrashView.swift;CDHash 220aaafcf38da26f2da3e1b26072c03914d8f5f6;Closes #634

### [x] Slice R2: 转写原文分段编辑与说话人重命名合并
- **Playbook**: `Feature` + `interrogate`
- **Outcome**: 按功能还原第二优先级落地 Slice R2（转写原文分段编辑与说话人重命名合并）。鉴于 crates/koe-engine/src/product/record.rs 已达 467 行，必须在 crates/koe-engine/src/product/ 新增独立子模块（如 transcript_edit.rs）承载逐句文本修订、单句说话人改名与同人批量合并领域规则，保留原始 ASR 证据链与 start_ms/end_ms 音频锚点及 SegmentId 引用完备性（ProductWorkspace::restore 强校验），同步刷新 BM25 索引并将既有结构化纪要标记为原文已变更待重算；在 KoeRuntime 拒绝转写进行中或软删态记录的分段编辑并持久化回写；经 koe-host-api C ABI v2（lib.rs 当前 295 行）在 RecordDetailView.swift（当前 213 行）接通分段内联编辑（必带 .onSubmit）与说话人改名合并交互。
- **Done Predicate**: ./scripts/check && cargo test --workspace --offline && swift test --package-path platforms/apple-shared && swift test --package-path platforms/macos && ./scripts/install-macos.sh
- **Evidence**: crates/koe-engine/src/product/transcript_edit.rs;crates/koe-runtime/src/transcript_edit.rs;platforms/apple-shared/Sources/KoeAppleShared/TranscriptDetailView.swift;CDHash 9e248d83414459bcbca9b9d27f66b4ebe37295ac;Closes #637

### [x] Slice UL: PLAUD 风格浅色色板
- **Playbook**: `Feature`
- **Outcome**: 以白色内容区、浅灰侧栏和炭黑主按钮替换深色配色，保留布局与功能。同步浅色原生控件及原有配色门禁。
- **Done Predicate**: ./scripts/check && python3 progress/progress.py check
- **Evidence**: scripts/check PASS; isolated GUI screenshots; signed staged build self-check and smoke PASS; #652

### [ ] Slice ULI: 浅色版日常安装与剩余弹窗验收
- **Playbook**: `Feature`
- **Outcome**: 签名浅色版和离线字幕已安装，自检与实体按键实时出字通过。按 #654 补验连接引导和审核编辑弹窗；#655 仅剩运行中第二页及隐藏唤窗观察。不要重复安装或要求用户断网。
- **Done Predicate**: python3 progress/progress.py check；真实界面观察并记录 #654/#655 尚未覆盖的项目，不把已有证据当作新验收。
- **Evidence**: issue #654; blocked by existing app quit failure

### [x] Slice OL: 录音豆本机实时识别与全局字幕
- **Playbook**: `Feature` + `figure-it-out`
- **Outcome**: macOS 26+ 使用 Apple SpeechAnalyzer 在本机识别 D3200 实时 PCM；Rust 管理请求归属和收尾，当前页面顶部显示字幕，实体录音开始时唤出应用窗口。
- **Done Predicate**: ./scripts/check && python3 progress/progress.py check；签名安装版 D3200 实体按键在本机模式下停止前显示真实中文，停止后同一记录保留最终文字，验收 #655。
- **Evidence**: scripts/check PASS; signed install self-check/smoke PASS; issue #655 comment-6827765221; hardware.jsonl and hardware-final-record.json
