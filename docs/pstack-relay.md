# Koe macOS 与 iOS 11 条 UI 原则重设计接力队列

本文件是 PStack 跨对话自动接力的唯一全景队列（对应 `pstack` 的 `figure-it-out`、`sequence-verifiable-units` 与 `Session pickup`）。
只维护每个对话切片（Slice）的用户可感知效果（Outcome）与可证伪验收条件（Done Predicate）。

- 总目标：以 `olgvroe/Vecta` 的原生双栏轻盈界面（90% `#FAFAFA`/`#F0F0F2` 灰白画布 + 8% `AIVisualEditorialPalette` 6 色柔彩卡片 + 2% 伊利诺伊橙 `#FF5F05`/`#D9480F` 点睛）和 `wquguru/cicada` 的实时同传与滚动纪要引擎为基准，将 Koe 全面塑造为纯 Rust + GPUI 的「安克随心记」（日常心力豆工作台，顺带覆盖会议纪要），通过私有阿里云百炼（DashScope ASR/LLM）与本机原生 MCP/ACP 对外服务，并彻底根治 D3200 真机「对着豆子说话不出字」的三处链路断点。
- 架构主线：三层零胶水统一架构，包含 (1) 单一录音生命周期聚合根 `RecordingAggregate`（以 `UtteranceSpine S1..Sn` 为唯一事实源，统一承载音频分片、双击 `SliceMark`、双语同传、6 宫格视觉卡片、根因鱼骨图、个人承诺与 `.koepack v2`），(2) 自驱流水线运行时 `SuixinRuntime`（对标 Vecta `NativeAppRuntime` + `NativeAnalysisQueue` 与 Cicada `ListenEngine`，在 `desktop/core` 内部闭环驱动 `BLE/Wi-Fi -> 16kHz Opus -> DashScope 流式 ASR -> 滚动纪要 -> BM25/MCP`，无需 UI 手写胶水串联），(3) 纯投影视图与单向意图 `WorkspaceProjection + WorkspaceCommand`（`desktop/app` GPUI 只渲染不可变投影并发射命令）。
- 自动验收入口：`scripts/verify-ui-principles.py` + `scripts/check`
- 视觉与架构原型画板：`.scratch/koe-ui-options/export/koe-uiuc-plaud-mcp-cli.html`
- 决策账本（`show-me-your-work`）：`.scratch/pstack-relay/decisions.tsv`
- 动态交接胶囊：`.scratch/pstack-relay/handoff_capsule.json`
- 下一棒提示词快照：`.scratch/pstack-relay/NEXT_PROMPT.md`

---

## 现状 vs 11 条原则差距基线（62 个 UI/Theme 文件实测）

基线由 `scripts/verify-ui-principles.py --mode audit` 实测采集（回执 `.scratch/pstack-relay/ui-baseline-receipt.json`）：

| 原则 | 改动前实测问题（62 个文件） | 结构化门禁与修复目标 |
| --- | --- | --- |
| 1 & 3. 小白主链路与去啰嗦说明 | 首页未连接时写「点『扫描』查找安克录音豆」却配无字雷达图标；资料页/项目页顶栏堆砌解释句 | 未连接处直接给「连接录音豆」按钮；界面自明处删除解释副标题，仅保留真实状态 |
| 2 & 8. 母语词藻、标点与统一动词 | 全仓 `·` 中间点连接符 **94 处**；`SectionLabel` 强制 `.toUpperCase()`；「扫描 / 连接 / 重连」动词混用 | 清零 `·` 连接符与 `.toUpperCase()`；统一动词为「连接录音豆」「开始录音」「移到回收站」 |
| 4. 数字单位与校验 | 电量、时长、存储空间、时间轴部分缺少单位上下文或混用散落格式 | 统一等宽数字（`tabularFigures`）与单位表达（`时长 42:18`、`电量 86%`、明确字节/条数校验） |
| 5. 克制确认与去大片红 | 弹窗引用 **137 处**、`coral` 红色引用 **70 处**，多处使用红底实心按钮 | 可恢复操作（移入回收站、断开设备）免弹窗；不可逆操作保留确认但不用大片红底实心按钮 |
| 6. 单一中国传统强调色与暖灰 | 原 `accent` 为 `#A4472B`（色相 `13.9°`，属陶土/砖橙色系）；`BatteryRing` 等混用红黄多色 | 切换为中国传统色「竹青」`#2E5E4E`（白字对比度 `7.42:1`；备选「靛青」`#2B4C65`、「松烟墨」`#2C2B29`）与宣纸暖灰（`R ≥ G ≥ B`） |
| 7. 单页最多 4 种字号 | 全仓散落 **19 种不同字号**（`10.5`–`44`），12 个页面单页超过 4 种字号 | 收敛至 `AppFontSizes` 四级阶梯（`12 / 14 / 16 / 22`），单页严格 `<= 4` 种字号 |
| 9. 纯平表面、同心圆角、禁套卡片 | `AppColors.cardShadow` 默认带两层阴影，37 处阴影/高度引用，存在卡片套卡片 | `AppColors.cardShadow` 默认置空（纯平），阴影仅留给 `floatingShadow` 浮层；新增 `AppRadii.concentric(outer, gap)` |
| 10 & 11. 多尺寸测试与三方案演进 | 部分状态栏与长文案靠省略号截断 | 320/390/430/1280 × 1.0x/2.0x 字号全覆盖；提供 3 套交互 HTML 画板供随时切换 |

---

## 全景切片队列（A → E）

### [x] Slice A: 62 文件基线盘点、11 原则自动验证门禁与三套视觉方案画板
- **Playbook**: `Investigation` + `figure-it-out`
- **Outcome**: 完成 `lib/theme/` 与 `lib/ui/` 62 个文件的量化基线盘点；建立可重跑门禁 `scripts/verify-ui-principles.py` 与含负向对照的单元测试 `scripts/test_verify_ui_principles.py`；按原则 6 与 11 产出 3 套中国传统色 + macOS/iOS 双端布局画板（松烟竹青 `#2E5E4E`、靛青书卷 `#2B4C65`、玄墨素笺 `#2C2B29`）并通过 `check_canvas.py` 导出单文件 HTML。
- **Done Predicate**: `python3 -B scripts/test_verify_ui_principles.py`、`python3 /Users/xianweizhang/.gemini/config/skills/xw-design/scripts/check_canvas.py .scratch/pstack-relay/koe-ui-proposals` 与 `scripts/pstack-relay selftest` 全部通过。
- **Evidence**: .scratch/pstack-relay/ui-baseline-receipt.json;scripts/verify-ui-principles.py;scripts/test_verify_ui_principles.py;.scratch/pstack-relay/koe-ui-proposals/export/koe-macos-ios-11.html

### [x] Slice B: 传统色竹青令牌、四级字号、纯平同心圆角与桌面/手机壳层落地
- **Playbook**: `Feature`
- **Outcome**: 在 `lib/theme/app_theme.dart`、`lib/ui/widgets/widgets.dart`、`lib/ui/shell.dart`、`lib/ui/screens/home_screen.dart` 与 `docs/design/ui-guidelines.md` 落地推荐方案一（松烟竹青 `#2E5E4E` + 宣纸暖灰 `#F5F4F0`）：建立 `AppFontSizes`（`12 / 14 / 16 / 22`）与 `AppRadii.concentric`，清空内联卡片阴影，去掉 `SectionLabel` 全大写与 `BatteryRing` 红黄混色，清零 `shell.dart` 中间点 `·`，将首页未连接雷达图标改为自明的「连接录音豆」按钮。
- **Done Predicate**: `python3 -B scripts/verify-ui-principles.py --mode slice-b`、`flutter test test/ui_principles_foundation_test.dart test/theme_tokens_test.dart test/dialog_title_visible_test.dart test/mobile_navigation_test.dart` 与 `scripts/check` 全部通过。
- **Evidence**: .scratch/pstack-relay/slice-b-ui-after.json;lib/theme/app_theme.dart;lib/ui/widgets/widgets.dart;lib/ui/shell.dart;lib/ui/screens/home_screen.dart;test/ui_principles_foundation_test.dart

### [x] Slice C: iOS 核心主链路（今日页、资料页、项目页、新建录音与配对引导）去啰嗦与规范统一
- **Playbook**: `Feature`
- **Outcome**: 重整 `today_screen.dart`、`library_screen.dart`、`projects_screen.dart`、`new_recording_sheet.dart`、`connect_onboarding.dart`、`scan_sheet.dart`、`morning_brief_card.dart` 与 `context_timeline.dart`：单页字号严格 `<= 4` 档（`12 / 14 / 16 / 22`），清零中间点 `·`，删除与搜索框/列表重复的解释性副标题，消除卡片套卡片，确保小白从「连接/录音 → 阶段摘要 → 纪要查看」零卡点，且在 `320/390/430` × `1.0x/2.0x` 大字号下不缩字、不截断关键语义。
- **Done Predicate**: `python3 -B scripts/verify-ui-principles.py --mode slice-c` 与 `scripts/check` 全部通过。
- **Evidence**: .scratch/pstack-relay/slice-c-ui-after.json;.scratch/pstack-relay/slice-c-full-check.log;lib/ui/screens/today_screen.dart;lib/ui/screens/library_screen.dart;lib/ui/screens/projects_screen.dart;lib/ui/screens/new_recording_sheet.dart;lib/ui/widgets/connect_onboarding.dart;lib/ui/widgets/scan_sheet.dart;lib/ui/widgets/morning_brief_card.dart;lib/ui/widgets/context_timeline.dart;test/ui_principles_slice_c_test.dart

### [x] Slice D: 录音库、录音详情、结构化纪要、设备页与设置页减负（去大片红、克制弹窗、数据单位规范）
- **Playbook**: `Feature`
- **Outcome**: 重整 `files_screen.dart`、`recording_detail_screen.dart`、`minutes_document_screen.dart`、`device_screen.dart`、`settings_screen.dart` 与 `minutes_panel.dart`：移除常规可逆操作的多余确认弹窗，将危险操作的大片红底实心按钮改为克制的文字/描边危险态，清零中间点 `·` 与非标字号，统一时长/电量/文件大小/时间轴的数字单位与校验。
- **Done Predicate**: `python3 -B scripts/verify-ui-principles.py --mode slice-d`、`scripts/check` 与 `KOE_PERF_FOREGROUND=1 scripts/perf-check` 全部通过。
- **Evidence**: .scratch/pstack-relay/slice-d-ui-after.json;.scratch/pstack-relay/slice-d-full-check.log;.scratch/pstack-relay/slice-d-perf-check.log;lib/ui/screens/files_screen.dart;lib/ui/screens/recording_detail_screen.dart;lib/ui/screens/minutes_document_screen.dart;lib/ui/screens/device_screen.dart;lib/ui/screens/settings_screen.dart;lib/ui/widgets/minutes_panel.dart;lib/state/recorder_controller.dart;test/ui_principles_slice_d_test.dart;test/ui_principles_slice_c_test.dart;test/mobile_navigation_test.dart;test/translation_source_playback_test.dart;test/recording_place_test.dart;test/meeting_minutes_test.dart;test/minutes_quality_and_glossary_test.dart;scripts/check

### [x] Slice E: 全仓剩余次级页面收口、多尺寸/多语言真实截图复验与交付
- **Playbook**: `Shipping`
- **Outcome**: 完成剩余次级页面与组件的 11 原则收口，使 `python3 -B scripts/verify-ui-principles.py --mode all` 全仓 62 个文件零违规；在 macOS 与 iOS 模拟器抓取真实界面截图核对视觉、字号、对比度与长文案排布，运行 `interrogate` / `deslop` / `no-comments` 并更新 PR 与进度页。
- **Done Predicate**: `python3 -B scripts/verify-ui-principles.py --mode all`、`scripts/check`、`python3 progress/progress.py check` 与 `scripts/pstack-relay status --require-all-done` 全部 `PASS`。
- **Evidence**: .scratch/pstack-relay/slice-e-ui-after.json;.scratch/pstack-relay/slice-e-full-check.log;.scratch/pstack-relay/screenshots/shell-mac-1280x900.png;.scratch/pstack-relay/screenshots/today-ios-390x844.png;.scratch/pstack-relay/screenshots/library-ios-390x844.png;.scratch/pstack-relay/screenshots/detail-ios-390x844.png;.scratch/pstack-relay/screenshots/detail-ios-320x740-2x.png;.scratch/pstack-relay/screenshots/settings-ios-390x844.png;scripts/verify-ui-principles.py;scripts/test_verify_ui_principles.py;test/ui_principles_slice_e_test.dart;progress/progress.json;progress/index.html

---

## 全景切片队列（F → I：Rust + SwiftUI + Compose/GPUI 三端高性能录音豆内核收口）

### [x] Slice F: 真实 Opus 语音解码器下沉至 Rust 内核并替换谐波合成预览
- **Playbook**: `Feature`
- **Outcome**: 将 160 字节定长 Opus 帧尾部零填充裁剪（`trim_opus_packet`）与真实 `libopus` 16 kHz / 48 kHz 单声道 PCM16 LE 解码能力接入 `rust/koe_core` 与 `rust/koe_core_ffi`（保持 `rust/koe_core` 100% `#![forbid(unsafe_code)]`，通过回调或 FFI 桥接静态链接 `libopus`），使 `TransportSession::finalize_active_transfer` 与新增的 C-ABI / Swift / Kotlin JNI 接口直接产出真实人声 PCM16 与 WAV，并在包含真实 `libopus` 1.5.2 编码帧（样本 130 为 `-4130`）时解码出精确语音波形。
- **Done Predicate**: `cargo test --manifest-path rust/Cargo.toml`、`./scripts/test-koe-core-swift`、`./scripts/build-swiftui-macos.sh --install`、`/Applications/KoeSwiftUI.app/Contents/MacOS/KoeSwiftUI --verify-self` 与 `./scripts/check` 全部 `PASS`。
- **Evidence**: 5a569a9;rust/koe_core/src/wav.rs;rust/koe_core/src/session.rs;rust/koe_core_ffi/src/opus_ffi.rs;rust/koe_core_ffi/build.rs;test/native/koe_core_swift_test.swift;test/native/KoeCoreJniTest.java;test/rust_core_parity_test.dart

### [x] Slice G: BLE 字节级断点续传、超时重试看门狗、2 秒静默收尾与后台恢复
- **Playbook**: `Feature`
- **Outcome**: 将 D3200 离线拉流的 `already_transferred`（`received_slices * 166`）字节级断点续传、看门狗超时重试状态机（每文件最多重试 2 次、单帧 5 秒超时）与实时流停止后的 2 秒静默排空窗口收进 `rust/koe_core::session::TransportSession`，并在 `darwin/KoeNativeTransport.swift` 补齐 `CBCentralManagerOptionRestoreIdentifierKey` 与外设自动重连。
- **Done Predicate**: `cargo test --manifest-path rust/Cargo.toml`、`./scripts/test-koe-core-swift` 与 `./scripts/check` 全部 `PASS`。
- **Evidence**: 0e9f09c;rust/koe_core/src/session.rs;rust/koe_core/src/transport.rs;rust/koe_core_ffi/src/lib.rs;rust/koe_core_ffi/src/bin/gen_bindings.rs;darwin/KoeNativeTransport.swift;test/native/koe_core_swift_test.swift;test/native/KoeCoreJniTest.java;test/rust_core_parity_test.dart

### [x] Slice H: Wi-Fi SoftAP 高速批量同步（1A/05 配网 + WSS 控制流 + UDP :32003 切片拉流）下沉至 Rust
- **Playbook**: `Feature`
- **Outcome**: 将 D3200 Wi-Fi 快传模式（`0x1A/0x05` 热点开启应答解析、`wss://<bean_ip>:32002/` 控制帧编解码与 `UDP :32003` 高吞吐 `0x1A/0x08` 切片流重组解密）收进 `rust/koe_core`，通过 C-ABI / Swift / Kotlin JNI 统一暴露给三端宿主。
- **Done Predicate**: `cargo test --manifest-path rust/Cargo.toml`、`./scripts/test-koe-core-swift` 与 `./scripts/check` 全部 `PASS`。
- **Evidence**: 10f6d8f;rust/koe_core/src/wifi.rs;rust/koe_core/src/commands.rs;rust/koe_core/src/session.rs;rust/koe_core_ffi/src/lib.rs;rust/koe_core_ffi/src/bin/gen_bindings.rs;darwin/KoeNativeTransport.swift;lib/native/koe_core_ffi.dart;test/native/koe_core_swift_test.swift;test/native/KoeCoreJniTest.java;test/rust_core_parity_test.dart

### [x] Slice I: 三端原生生产宿主接线（iOS SwiftUI + Android Compose JNI + 桌面 GPUI 共享 koe_core）与最终收口
- **Playbook**: `Shipping`
- **Outcome**: 将 `rust/koe_core` 接入桌面端 `desktop/core`、补齐 iOS/macOS SwiftUI 与 Android `KoeCore.kt` 全链路接线，完成对抗审查（`interrogate`）、代码精简（`deslop` / `no-comments`）、性能基准（`scripts/perf-check`）与晨间审计（`show-me-your-work` + `ketchup`）。
- **Done Predicate**: `./scripts/test-koe-core-swift`、`./scripts/check`、`python3 progress/progress.py check` 与 `scripts/pstack-relay status --require-all-done` 全部 `PASS`。
- **Evidence**: ca50e76;desktop/core/src/lib.rs;darwin/KoeNativeTransport.swift;darwin/KoeNativeHost.swift;darwin/KoeNativeAppMain.swift;android/app/src/main/kotlin/com/anker/anker_recorder/KoeCore.kt;scripts/test-koe-core-swift;test/native/koe_core_swift_test.swift;test/native/KoeCoreJniTest.java;progress/progress.json;progress/index.html

---

## 全景切片队列（J → O：千问闪记 + Cicada 同步翻译 + 心力豆个人图谱 + Rust 原生 MCP/ACP 全量下沉 + 纯 Rust GPUI 桌面端与存量 Flutter/SwiftUI 彻底退役）

### [x] Slice J: 统一句子主干 `UtteranceSpine`（`S1..Sn`）与四模块纯 Rust 领域骨架
- **Playbook**: `Feature`
- **Outcome**: 在 `rust/koe_core`（100% `#![forbid(unsafe_code)]`、`#![deny(missing_docs)]`）建立 `domain.rs`（`SegmentId` `S1..Sn`、`UtteranceSegment`、`UtteranceSpine`、`MeetingMinutesV2`、`MinuteTopic`、`MinuteFishbone`、`MinuteTerm`、`ContextItem`、`TodoItem`、`AiProviderCommand`）并预分配 `minutes.rs`、`cicada.rs`、`context.rs` 与 `mcp_acp.rs` 四个零冲突独立模块入口，跑通 `S1..Sn` 不可变追加、修订号递增与原句溯源基线单测，并通过 C-ABI / Swift / Kotlin JNI 暴露 `UtteranceSpine` 基础操作。
- **Done Predicate**: `cargo test --manifest-path rust/Cargo.toml`、`cargo test --manifest-path desktop/Cargo.toml`、`./scripts/test-koe-core-swift` 与 `./scripts/check` 全部 `PASS`。
- **Evidence**: `d7fab08;cargo test 41 passed;desktop 4 passed;swift+jni+dart parity passed`

### [x] Slice K: 千问闪记 ASR 协议、分块归并纪要状态机、`S1..Sn` 防幻觉校验与 `qwennote-minutes` 热词模板下沉
- **Playbook**: `Feature`
- **Outcome**: 在 `rust/koe_core/src/minutes.rs` 完整实现 DashScope 语音转写任务与流式识别协议编解码、千问大模型二阶段分块归并纪要生成状态机、`S1..Sn` 严格原句证据校验器（拒绝跨句拼接工资与百分比、拒绝无基数比例与未引用数字），以及千问听记 `qwennote-minutes` 热词表、说话人替换与自定义模板注入，通过 Dart vs Rust 纪要校验差分对拍测试。
- **Done Predicate**: `cargo test --manifest-path rust/Cargo.toml`、`./scripts/test-koe-core-swift` 与 `./scripts/check` 全部 `PASS`。
- **Evidence**: 2f1523a;rust/koe_core/src/minutes.rs;rust/koe_core/src/domain.rs;rust/koe_core_ffi/src/lib.rs;rust/koe_core_ffi/src/jni.rs;rust/koe_core_ffi/src/bin/gen_bindings.rs;darwin/KoeCore.swift;android/app/src/main/kotlin/com/anker/anker_recorder/KoeCore.kt;lib/native/koe_core_ffi.dart;test/native/koe_core_swift_test.swift;test/native/KoeCoreJniTest.java;test/rust_core_parity_test.dart

### [x] Slice L: Cicada 同步双语翻译、有界实时滚动纪要（120次/时）、`.koepack v2` 资料包与同传路由下沉
- **Playbook**: `Feature`
- **Outcome**: 在 `rust/koe_core/src/cicada.rs` 完整实现对齐 `wquguru/cicada` 的句段增量双语翻译队列、有界实时滚动纪要调度器（每小时最多 120 次、满 200 字或 30 秒触发、手改保留）、30 秒麦克风静默自动收尾检测、无音频 `.koepack v2` 资料包（当前纪要 + 最多 10 版历史 + SHA-256 校验）编解码，并在 `darwin/` 原生 SwiftUI 宿主挂载 CoreAudio + BlackHole 按住同传路由。
- **Done Predicate**: `cargo test --manifest-path rust/Cargo.toml`、`./scripts/test-koe-core-swift` 与 `./scripts/check` 全部 `PASS`。
- **Evidence**: f48c2a3;rust/koe_core/src/cicada.rs;rust/koe_core/src/domain.rs;rust/koe_core/src/hash.rs;rust/koe_core_ffi/src/lib.rs;rust/koe_core_ffi/src/jni.rs;rust/koe_core_ffi/src/bin/gen_bindings.rs;darwin/KoeCore.swift;darwin/KoeNativeHost.swift;android/app/src/main/kotlin/com/anker/anker_recorder/KoeCore.kt;lib/native/koe_core_ffi.dart;test/native/koe_core_swift_test.swift;test/native/KoeCoreJniTest.java;test/rust_core_parity_test.dart

### [x] Slice M: 心力豆（Sweetpea）个人上下文时间线、待办/项目/日记沉淀与中文双字 BM25 离线问答检索下沉
- **Playbook**: `Feature`
- **Outcome**: 在 `rust/koe_core/src/context.rs` 完整实现随心随力记录时间线（录音、地点、随手记、承诺提取、待办事项、项目归类、每日晨报与日记聚合）以及零云端向量依赖的中文双字（Bigram）+ 拉丁词根 BM25/TF-IDF 离线问答检索引擎與多轮溯源对话状态机，40 万字语料单次检索延迟 `< 5 ms`。
- **Done Predicate**: `cargo test --manifest-path rust/Cargo.toml`、`./scripts/test-koe-core-swift` 与 `./scripts/check` 全部 `PASS`。
- **Evidence**: 0930e7d;rust/koe_core/src/context.rs;rust/koe_core/src/domain.rs;rust/koe_core_ffi/src/lib.rs;rust/koe_core_ffi/src/jni.rs;rust/koe_core_ffi/src/bin/gen_bindings.rs;darwin/KoeCore.swift;android/app/src/main/kotlin/com/anker/anker_recorder/KoeCore.kt;lib/native/koe_core_ffi.dart;test/native/koe_core_swift_test.swift;test/native/KoeCoreJniTest.java;test/rust_core_parity_test.dart

### [x] Slice N: Rust 原生 MCP + ACP 服务端、三端原生宿主全量接线与最终收口
- **Playbook**: `Shipping`
- **Outcome**: 在 `rust/koe_core/src/mcp_acp.rs` 与 `desktop/core` 实现原生 JSON-RPC 2.0 MCP（`list_recordings`、`get_transcript`、`get_minutes`、`search_context`、`qwennote` 热词/模板同步与 `.koepack v2` `/sync/packs`）及 ACP（Agent Communication Protocol）协议栈，将 `minutes`、`cicada`、`context`、`mcp_acp` 全链路接入 `desktop/core`、`darwin/` SwiftUI 与 Android `KoeCore.kt`，完成对抗审查（`interrogate`）、代码清理（`deslop` / `no-comments`）、性能基准与早间审计。
- **Done Predicate**: `./scripts/test-koe-core-swift`、`./scripts/check`、`python3 progress/progress.py check` 与 `scripts/pstack-relay status --require-all-done` 全部 `PASS`。
- **Evidence**: 3d50ef5;b899fca;rust/koe_core/src/mcp_acp.rs;desktop/core/src/lib.rs;rust/koe_core_ffi/src/lib.rs;rust/koe_core_ffi/src/jni.rs;rust/koe_core_ffi/src/bin/gen_bindings.rs;darwin/KoeCore.swift;darwin/KoeNativeHost.swift;android/app/src/main/kotlin/com/anker/anker_recorder/KoeCore.kt;lib/native/koe_core_ffi.dart;test/native/koe_core_swift_test.swift;test/native/KoeCoreJniTest.java;test/rust_core_parity_test.dart

### [x] Slice O: 纯 Rust GPUI 桌面端（`desktop/app`）挂载 `DesktopBeanHost` 与存量 8.8 万行 Flutter/SwiftUI 彻底退役
- **Playbook**: `Shipping`
- **Outcome**: 在 `desktop/app` 使用纯 Rust `gpui`（`gpui-kit = "=0.9.0"`）直接挂载 `desktop/core`（`DesktopBeanHost` over `rust/koe_core` 2.0.0），实现 5 页签（今日时间线、本机录音库与千问闪记纪要、Cicada 双语实时翻译与 `.koepack v2`、心力豆 BM25 离线问答、MCP/ACP 代理接口）与竹青色 `#2E5E4E` + 暖纸灰 `#F5F4F0` 视觉规范；将 `/Applications/Koe.app` 编译并签名为纯 Rust 二进制（同时清理 `/Applications/KoeSwiftUI.app`）；物理删除 `lib/`、`pubspec.yaml`、全部 Dart 测试与 Flutter/SwiftUI 宿主壳层，将 `scripts/check`、`scripts/verify-ui-principles.py`、`scripts/install-macos.sh` 与 CI 门禁全面收敛至纯 Rust。
- **Done Predicate**: `find lib test integration_test -name '*.dart' 2>/dev/null | wc -l` 为 `0`、`./scripts/check`、`./scripts/install-macos.sh`、`/Applications/Koe.app/Contents/MacOS/Koe --verify-self`、`/Applications/Koe.app/Contents/MacOS/Koe --smoke-test`、`python3 progress/progress.py check` 与 `scripts/pstack-relay status --require-all-done` 全部 `PASS`。
- **Evidence**: e150335;d9b54ed;87e60f6;desktop/app/src/main.rs;desktop/app/src/theme.rs;desktop/ble/src/lib.rs;scripts/install-macos.sh;scripts/check;/Applications/Koe.app

---

## 全景滚动切片队列（P → T：「安克随心记」Vecta × Cicada 零胶水三层架构与真机实时流闭环）

### [x] Slice P: 「安克随心记」Vecta × Cicada 三层零胶水架构确立、4 屏原型画板、三处实时流断点定位与 `pstack-relay` 动态合成升级
- **Playbook**: `Investigation` + `figure-it-out`
- **Outcome**: 深度剖析 `olgvroe/Vecta` 与 `wquguru/cicada` 源码，确立「安克随心记」三层零胶水架构（`RecordingAggregate` 聚合根 + `SuixinRuntime` 自驱管道 + `WorkspaceProjection/WorkspaceCommand` 纯投影视图）；完成 Vecta 90-8-2 伊利诺伊橙 4 屏交互画板（`.scratch/koe-ui-options/export/koe-uiuc-plaud-mcp-cli.html`）；定位「对着豆子说话不出字」的三处代码级断点；将 `pstack-relay` 升级为根据每棒真实进展与上下文水位动态合成下一棒提示词的滚动引擎。
- **Done Predicate**: `python3 /Users/xianweizhang/.gemini/config/skills/xw-design/scripts/check_canvas.py .scratch/koe-ui-options`、`python3 /Users/xianweizhang/Projects/xw-skills/xw-tooling/skills/pstack-relay/tests/test_pstack_relay.py` 与 `scripts/pstack-relay selftest` 全部 `PASS`。
- **Evidence**: .scratch/koe-ui-options/export/koe-uiuc-plaud-mcp-cli.html;scripts/pstack-relay;docs/pstack-relay.md

### [ ] Slice Q: 第一与第二层收口 (`RecordingAggregate` + 自驱实时流管道，修复 `1A/06`->`1A/07`、注入 16kHz Opus 解码与 DashScope 流式 ASR 泵)
- **Playbook**: `Feature`
- **Outcome**: 在 `rust/koe_core` 与 `desktop/core` 消除散装状态拼接，落地自驱实时流与分析管道：(1) 在 `rust/koe_core/src/session.rs` 补齐 `(0x01, 0x01)` 录音中状态及 `(0x1A, 0x06)` `state == 1`（机身按下开始录音）自动排队下发 `1A/07 (realtimeFlag=1)`，并提供 `start_realtime_recording()` (`18/81`)；(2) 在 `desktop/core` 为 `DesktopBeanHost` 默认注入真实 16kHz/48kHz Opus 解码器工厂，使 `ingest_ble_chunk` 实时产出 640B/20ms `live_pcm16_16khz`；(3) 在 `desktop/core` 建立自驱流式转写与 Cicada 滚动提炼泵（支持私有阿里云 DashScope `paraformer-realtime-v2` / 本地流式识别回退），自动将 `live_pcm16_16khz` 转为 `UtteranceSpine (S1..Sn)` 原句、双语同传、个人承诺与五阶自检遥测（`PipelineDoctorSnapshot`），无需 GPUI 层手写胶水逻辑。
- **Done Predicate**: `cargo test --manifest-path rust/Cargo.toml`、`cargo test --manifest-path desktop/Cargo.toml` 与 `./scripts/check` 全部 `PASS`。
- **Evidence**: `PENDING`

### [ ] Slice R: 第三层收口（上），Vecta 90-8-2 伊利诺伊橙主题令牌、`WorkspaceProjection` 纯投影模型与双栏主工作台（随心记录 + 声波书签 + 逐字声纹同传 + 6 宫格视觉总结）
- **Playbook**: `Feature`
- **Outcome**: 在 `desktop/core` 暴露单一不可变视图投影 `WorkspaceProjection` 与单向意图 `WorkspaceCommand`；将 `desktop/app/src/theme.rs` 与 `scripts/verify-ui-principles.py` 升级为 Vecta 90-8-2 配色（`#FAFAFA`/`#F0F0F2` 基底 + `AIVisualEditorialPalette` 6 色柔彩卡片 + 2% 伊利诺伊橙 `#FF5F05`/`#D9480F`）；在 `desktop/app/src/main.rs` 落地 Vecta 双栏壳层、左侧五项导航与底部 `安克心力豆 D3200` 状态卡、右侧顶部日常心力概览条（`MorningBrief` + `ProjectProgress` + `DiaryDraft` + 粗粒度地点）、带橙色已播声波与 `±10s` 双击书签的横向播放器，以及「心智总结（6 宫格柔彩卡片 + Cicada 根因鱼骨图）」与「逐字原话与声纹（`UtteranceSpine` + 双语同传 + 说话人/热词纠错）」双标签页。
- **Done Predicate**: `python3 -B scripts/verify-ui-principles.py --mode all`、`cargo test --manifest-path desktop/Cargo.toml` 与 `./scripts/check` 全部 `PASS`。
- **Evidence**: `PENDING`

### [ ] Slice S: 第三层收口（下），心力格式库（`Formats`）、私有阿里云与本机 MCP/ACP 控制台、设置与心力豆五阶自检（`Bean Doctor` + Wi-Fi `1A/05` 快传）
- **Playbook**: `Feature`
- **Outcome**: 通过 `WorkspaceProjection` 与 `WorkspaceCommand` 完整落地剩余三屏工作流：(1) `心力格式 (Formats)` 页接入 5 套预置心力/会议模板与自定义分区编辑；(2) `阿里云与 MCP` 页接入私有阿里云 DashScope Keychain 配置、`KOEMCP1` 配对票据、`15s live.json` 租约、`--mcp-stdio` 一键配置生成与中文双字 BM25 多轮溯源问答；(3) `设置与硬件自检 (Bean Doctor)` 页落地五阶实时流状态灯、一键重发 `1A/07` 实时流测音按钮、开机自启/后台常驻同步开关与 Wi-Fi SoftAP (`192.168.4.1:32002`) 批量快传控制。
- **Done Predicate**: `cargo test --manifest-path desktop/Cargo.toml`、`./scripts/install-macos.sh`、`/Applications/Koe.app/Contents/MacOS/Koe --verify-self`、`/Applications/Koe.app/Contents/MacOS/Koe --smoke-test` 与 `./scripts/check` 全部 `PASS`。
- **Evidence**: `PENDING`

### [ ] Slice T: 全链路对抗审查（`interrogate`）、零胶水代码精简（`deslop` / `no-comments`）、进度页更新与交付收口
- **Playbook**: `Shipping`
- **Outcome**: 对照「安克随心记」Vecta × Cicada 架构主线执行全仓对抗审查与代码精简，确认 `/Applications/Koe.app` 真机安装与自检全绿，同步 `progress/progress.json` 与 `progress/index.html`，产出完整审计摘要。
- **Done Predicate**: `./scripts/check`、`python3 progress/progress.py check` 与 `scripts/pstack-relay status --require-all-done` 全部 `PASS`。
- **Evidence**: `PENDING`
