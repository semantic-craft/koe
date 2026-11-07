# Koe macOS 与 iOS 11 条 UI 原则重设计接力队列

本文件是 PStack 跨对话自动接力的唯一全景队列（对应 `pstack` 的 `figure-it-out`、`sequence-verifiable-units` 与 `Session pickup`）。
只维护每个对话切片（Slice）的用户可感知效果（Outcome）与可证伪验收条件（Done Predicate）。

- 总目标：按用户提出的 11 条 UI 与产品原则重新设计 Koe 的 macOS 与 iOS 界面（小白主链路无卡点免说明书、母语自然文案、不写冗余解释、数据单位准确校验、克制二次确认与去大片红、中国传统色单一强调色与暖灰、单页最多 4 种字号、禁说明斜体/按钮全大写/中间点 `·` 且统一动词、纯平表面+同心圆角+禁卡片套卡片、多语言与多尺寸不缩字不截断、三套高水准方案对比演进）。
- 自动验收入口：`scripts/verify-ui-principles.py` + `scripts/check`
- 三套视觉与布局对比画板：`.scratch/pstack-relay/koe-ui-proposals/export/koe-macos-ios-11.html`
- 决策账本（`show-me-your-work`）：`.scratch/pstack-relay/decisions.tsv`
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
