# feat/ui-redesign 挑回评估（工单 06 token 层 / 工单 07 数据驱动引擎列表）

日期：2026-10-15。拓扑：`feat/ui-redesign` = 3d86fce → **87d5d8c**（token 层）→ **357a426**（数据驱动设置+引擎列表）→ 8fa90a9 → 50ddfee（HEAD，worktree `.worktrees/ui-redesign` 有稳定只读副本）。
主线：`codex/warm-recording-workspace`（ede579e，含 eebad33 的 qwen）。**两支共同基底是 3d86fce**；ui-redesign 分支上没有 qwen、没有 `defersTranscription`、没有暖色工作台 UI。

## 1. `git show --stat 87d5d8c`（挑回目标一：设计 token 层）

```
lib/main.dart               |   2 +   ← darkTheme: AppTheme.dark + themeMode: ThemeMode.light
lib/theme/app_theme.dart    | 697 +++++...  ← 全文件重写为 705 行
lib/ui/widgets/widgets.dart | 289 +++++...  ← 扩为 519 行共享原语
```

（精确 stat：3 files changed, 844 insertions(+), 144 deletions(-)）

### 1.1 token 层目录结构与 API 形状（`git show 87d5d8c:lib/theme/app_theme.dart`）

单文件四段结构，全部静态、无依赖注入：

- `AppSpacing`（:4-21）：`s2 s4 s6 s8 s10 s12 s14 s16 s18 s20 s24 s28 s32 s48` 常量阶梯。
- `AppRadii`（:24-32）：`xs=4 sm=8 md=10 lg=12 xl=16 pill=999`。
- `AppMotion`（:36-46）：`fast 120ms / normal 200ms / exit 140ms / slow 280ms` + `easeOut = Cubic(0.23, 1.0, 0.32, 1.0)`。
- `AppColors`（:50-124）：**open-design 冷色盘常量**（如 `bg 0xFFFAFAFA`、`accent 0xFF1A74FF` 蓝、`amber 0xFFE86418`、`coral 0xFFF04142`、`violet 0xFF6E44FF`）+ `cardShadow`/`floatingShadow` BoxShadow 列表。挑回时这层是**被暖色值替换的取值来源位**，不是照抄对象。
- `KoeTokens extends ThemeExtension<KoeTokens>`（:131-409）：33 个实例字段（bg/bgElevated/bgCard/bgPanel/bgSubtle/bgMuted、border 系 5、text 系 5、inkAccent/onInkAccent、accent+Soft+Border、mint/amber/coral/violet 各三态、gradientTop/Bottom、cardShadow、floatingShadow）；`static final KoeTokens light/dark`（:204/:241）分别取自 AppColors；`static KoeTokens of(BuildContext)`（:290-292，`Theme.of(context).extension<KoeTokens>() ?? light`）；`copyWith`（:295）与逐字段 `Color.lerp` 的 `lerp`（:370-408）。
- `AppTheme`（:411-705）：`static ThemeData get light/dark => _build(Brightness., KoeTokens.)`（:412-414）；`_build` 把 token 铺进 Material 组件主题（filledButton/outlined/textButton、segmentedButton、switch、popupMenu、dialog、bottomSheet、divider、card…，iconTheme 固定 20px）。

### 1.2 共享原语（`git show 87d5d8c:lib/ui/widgets/widgets.dart`，519 行）

11 个类：`GradientScaffold`(:7)、`SurfaceCard`(:40)、`StatusPill`(:103)、`BatteryRing`(:156) + `_RingPainter`(:226)、`AccentButton`(:272)、`InfoRow`(:351)、`SectionLabel`(:393)、**`IconBadge`(:426，新增)**、**`BannerNotice`(:467，新增)**。对比暖色主线（ede579e 的 widgets.dart，354 行）有前 8 个无后两个——IconBadge/BannerNotice 是引擎卡与设置卡需要的。

### 1.3 main.dart 差异

ede579e 只有 `theme: AppTheme.light`（`lib/main.dart:54`）；87d5d8c 加 `darkTheme: AppTheme.dark` + `themeMode: ThemeMode.light`。挑回时保留这两行即可（themeMode.locked light → 视觉不变）。

## 2. `git show --stat 357a426`（挑回目标二：数据驱动引擎列表）

```
lib/ui/screens/settings_screen.dart | 719 +++++...（993→1284 行重写）
test/widget_test.dart               |  49 +（两个新测试）
2 files changed, 608 insertions(+), 160 deletions(-)
```

### 2.1 数据模型与列表结构（`.worktrees/ui-redesign/lib/ui/screens/settings_screen.dart`）

- `_ProviderSelector`（:163-269）：**不再有 enum 专属分支渲染**——`for (var i = 0; i < SttProvider.values.length; i++) _EngineOptionCard(provider: SttProvider.values[i], selected: …, meta: _metaFor(…), onTap: () => controller.setSpeechProvider(...))`，顶部计数 `'共 ${SttProvider.values.length} 个引擎'`，容器 `ValueKey('speech-provider-${controller.speechProvider.name}')`。
- 元数据查找 `_metaFor(provider, tokens)`（:174-231）返回记录类型 `({IconData icon, String description, String statusLabel, Color statusColor})`，**按 `provider.name` 字符串 switch**（'soniox'/'apple'/'moss' 三个 known case + `default`）。default 分支已预留任意新引擎的兜底（含 `provider.name.toLowerCase().contains('qwen')` 的前瞻判断 → 豆包接入时应改为显式 `'doubao'` case，配"已配置/需密钥"状态）。状态标签逻辑示例：soniox/moss = key 非空 → '已配置'（mint）否则 '需密钥'（amber）；apple = capabilities 就绪度。**这正是"未配置 key 可见但不可选/提示"的挂点**（357a426 原型未实现禁用，工单 07 要补）。
- `_EngineOptionCard`（:271-395）：InkWell + AnimatedContainer 卡（选中态 bgCard+inkAccent 边+cardShadow / 未选中 bgPanel+border），行内 `IconBadge`（选中反白）、标题+状态 pill（statusColor 12% 底/28% 边）、描述两行、尾部 radio 图标；`ValueKey('speech-provider-option-${provider.name}')`。
- 设置卡片结构：`_SettingsGroup`（:586-605，tokens.bgCard + AppRadii.lg + border + cardShadow 容器）；`_SettingsSwitch`（:732-800，可选 `icon` 参数 → IconBadge 左缀）；各语言选择器/输入框全部改用 `KoeTokens.of(context)` 取色（不再 AppColors 直接引用）。
- 357a426 的 settings 基底没有 qwen：`自动转写` 副标题写死 `== SttProvider.moss`（:56-58）、`_SttModeSelector` 条件 `!= SttProvider.moss`（:107）——挑回时都必须换成 `defersTranscription`（见 §4）。

### 2.2 附带测试（`git show 357a426 -- test/widget_test.dart`）

- `light and dark themes register distinct KoeTokens extensions`：断言 `AppTheme.light/dark.extension<KoeTokens>()` 非空且 bg/textPrimary 不同——**挑回时若暖色单主题让 dark=light，此测试要改/删**（工单 06 验收是"视觉不变"而不是"有暗色"）。
- `settings renders data-driven selectable cards for all SttProvider values`：对每个 `SttProvider.values` 断言 `find.byKey(ValueKey('speech-provider-option-{name}'))` + label 文案各一个，然后 tap moss 卡断言 `controller.speechProvider` 切换成功。挑回后加豆包即自动多断言一项——工单 07 验收"新增引擎不需要专属界面代码"的直接证据。

## 3. 与暖色主线（ede579e lib/ui）的冲突面

自共同基底 3d86fce 以来主线也大改了同一批文件（`git diff 3d86fce ede579e --stat`）：`lib/theme/app_theme.dart` +123 行重写（223 行暖色单主题：`accent 0xFFA4472B` 赭、`bg 0xFFF5F5F3` 暖白、`dark => light`，见 `git show ede579e:lib/theme/app_theme.dart:4-26,222`）；`lib/ui/widgets/widgets.dart` -80 行精简（354 行、8 原语、仍引用 AppColors 常量）；settings_screen（993 行，含 `_QwenSettings`/`_MossKeyField`/`_SttModeSelector` 的 defersTranscription 门控）；加上 home/files/device/detail/shell 全套暖色工作台。

逐文件冲突与适配点：

| 文件 | 冲突 | 适配策略（工单 06） |
| --- | --- | --- |
| `lib/theme/app_theme.dart` | 双方都整文件级重写（87d5d8c 705 行 vs 暖色 223 行），直接 cherry-pick 必全文件冲突 | 以 87d5d8c 的**结构**为准（AppSpacing/AppRadii/AppMotion/AppColors/KoeTokens/AppTheme），把暖色 223 行里的取值（accent/bg/text/mint/amber/coral/violet/gradient、圆角、字号）灌进 `KoeTokens.light` 与 `AppColors`；验收口径是截图对照视觉零变化 |
| `lib/ui/widgets/widgets.dart` | 暖色删了 80 行、redesign 扩到 519 行；同名原语双方实现都动过 | 取 redesign 版 + IconBadge/BannerNotice 新增，内部颜色改经 tokens；对照暖色版逐原语 diff 确认行为（BatteryRing/AccentButton 等） |
| `lib/main.dart` | 仅 +2 行（darkTheme/themeMode），暖色未动此处 | 直接加；`themeMode: ThemeMode.light` 锁亮色保证视觉不变 |
| `lib/ui/screens/settings_screen.dart`（357a426） | 暖色 993 行含 qwen/defersTranscription/三 key 输入；redesign 1284 行无 qwen | **不整文件挑回**。只移植 `_ProviderSelector` + `_metaFor` + `_EngineOptionCard`（约 :163-395）与 widget 测试，嫁接到暖色 settings 骨架；`_metaFor` 补 qwen（已配置→'已配置'）与 doubao case；`== SttProvider.moss` 两处 → `defersTranscription`；`_QwenSettings` 三输入框保留为选中引擎卡下方的成组配置区（工单 07 的三件套值对象 UI） |
| `lib/ai/speech_provider.dart` | redesign 基底无 qwen | 不动主线版；`_metaFor` 的 default 兜底已能吃新枚举 |

另注意 pubspec 依赖：token 层只用 Flutter 自带（ThemeExtension），无新增 package。

## 4. 8fa90a9 / 50ddfee 中"不挑回"的清单（spec Implementation Decisions：只挑 token 层与数据驱动引擎列表两块）

**8fa90a9（feat(transcript): polish transcript panel, detail reader, and communication view）——全部不挑回：**

```
lib/ui/screens/communication_screen.dart    | 148 ±
lib/ui/screens/recording_detail_screen.dart | 593 ±
lib/ui/widgets/transcript_panel.dart        | 238 ±
```

（暖色主线在 ede579e 已有自己的 recording_detail/focused reader 实现，挑回会正面冲突且 spec 明确废弃"转写面板打磨"。）

**50ddfee（feat(ui): refine recorder controls, library list, players, and connection sheets）——全部不挑回：**

```
lib/ui/screens/device_screen.dart       | 255 ±
lib/ui/screens/files_screen.dart        | 510 ±
lib/ui/screens/home_screen.dart         |  79 ±
lib/ui/shell.dart                       |  86 ±
lib/ui/widgets/connect_onboarding.dart  | 162 ±
lib/ui/widgets/inline_player.dart       |  67 ±
lib/ui/widgets/playback_bar.dart        |  80 ±
lib/ui/widgets/scan_sheet.dart          | 132 ±
```

（对应 spec 废弃项"录音控件重绘"。其中 `inline_player.dart` 在主线工作区当前也有未提交修改，评审时留意。）

两个"不挑回"提交全部改动都只落在上述文件，与 token 层/引擎列表两块无交集；唯一间接关系是它们引用了 87d5d8c 的 tokens API（KoeTokens.of/AppRadii/IconBadge）——即 token 层先挑回后，主线这些屏幕仍可继续用保留的 `AppColors` 常量（87d5d8c 的 AppColors 保留 static const 形态），互不阻塞。

## 5. 挑回顺序建议（对应工单依赖）

1. 工单 06：87d5d8c 结构 + 暖色取值 → `flutter test` 全绿 + 截图对照；widget_test 的 light/dark 断言按暖色单主题调整。
2. 工单 07：357a426 的 `_ProviderSelector/_EngineOptionCard/_metaFor` + 测试移植，同时落三件套值对象与豆包数据项（禁用态：`!configured` → 视觉弱化 + tap 提示"先去配置"）。
3. 之后工单 09 豆包进列表 = 只加 `_metaFor` 一个 case + 枚举值，界面零改动（357a426 测试自动覆盖）。
