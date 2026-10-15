# 暖色录音工作台：实现与验证

2026-10-15，基线 `eebad33`，实现分支 `codex/warm-recording-workspace`。
设计一手材料保留在 `codex/prototype-claude-ui` 的 `lib/ui/prototype/UI_PROPOSAL.md` 与 HTML 原型中。本分支从原业务基线创建，没有带入 HTML 原型。

## 已实现

- 宽度至少 1100 logical px、文字缩放低于 150% 时：184px 导航侧栏 + 340px 录音列表 + 自适应阅读区。其余窗口使用紧凑布局；手机保留首页/设备/设置三项底部导航。
- 右侧详情复用原 RecordingDetailScreen / CommunicationScreen；桌面切换记录替换当前详情，避免不断堆栈。切换设置/设备后返回录音库保留所选详情；在设置页缩窄窗口不意外露出隐藏详情。
- 首页、详情、设备、设置、扫描/下载弹层共享暖灰/深陶土主题。正文 17pt、1.85 行高、24px 段距；原文/译文分段收紧；菜单、表单、按钮按主题统一；危险确认保留原语义。
- 桌面补充明确的选择与刷新入口；开始录音复用原 startRecord 和既有禁用条件。列表用暖色标识当前阅读项，批选仍使用原选择逻辑。
- 原生 macOS 初始窗口调整为 1240×820，最小尺寸仍可使用紧凑模式。
- 嵌套 Navigator 增加独立语义容器，避免详情路由屏蔽并排导航/录音列表；录音行明确标为按钮。

## 范围核对

生产改动仅位于 `lib/theme/`、`lib/ui/` 与 `macos/Runner/MainFlutterWindow.swift`（窗口尺寸）。`lib/state/`、`lib/ble/`、`lib/wifi/`、`lib/ai/`、`lib/audio/`、`lib/protocol/`、`lib/crypto/`、`lib/platform/`、依赖和正式启动入口未修改。
保留录音/下载/转写控制器与请求参数；未改变录音暂停、文件锁定、provider 能力、设置下一段生效、Apple 失败不回退云端等规则。新增交互仅是现有命令入口和 UI 导航。

## 自动验证

- `flutter test`：196 项通过（原有 193 项，加 2 项桌面回归与 1 项逐帧语义更新回归）。
- `flutter analyze --no-pub`：通过。
- `flutter build macos --debug -t lib/main.dart`：正式入口 Debug 构建通过。插件仍提示 flutter_opus 未采用 Swift Package Manager；不影响此次构建。
- `git diff --check`：通过。
- 新增 `test/macos_accessibility_update_test.dart`：拦截逐帧发送引擎的语义更新批次，出现任何不可从根到达的序列化节点即失败。红绿验证：撤销 `lib/ui/widgets/inline_player.dart` 的滑块浮层修复时失败（孤儿节点 id 60、84、108），恢复修复后通过。
- `scripts/check-macos-accessibility.py`：需 VoiceOver 已开启。实测 9 步场景 0 次 `Failed to update ui::AXTree`，日志在 `build/ui-evidence/ax-native.log`；脚本本身不替代人工读屏验收。
- 新增回归覆盖桌面分栏、同一详情去重、切设置后回到选中录音、设置页/详情页缩窄、手机返回、实时录音跨页保持、快捷指令返回、暂停不退页和左侧导航语义可见。
- 原有测试继续覆盖长正文跟随解除/恢复、原译文独立滚动、底部安全区、200% 字号、批选与处理条件。

## 实际渲染与证据

下面是实际 Flutter widgets 的渲染，数据是测试 fixture，不是 HTML 原型，也不代表真实音频验收。

- `build/ui-evidence/detail-wide.png`：1280×900 桌面分栏与正文。
- `build/ui-evidence/home-phone.png`、`detail-phone.png`：390×844 手机三项导航与详情。
- `home-large-text.png`、`detail-large-text.png`：320px 宽、200% 字号。
- `apple-settings-large-text.png`、`apple-recording-language-phone.png` 等：设置与语言弹层。
- `native-desktop.png`：macOS 原生 Debug 窗口，右上角标有 UI PREVIEW；独立临时入口使用合成文字、`loadPersistedState:false`，未加载真实录音或配置。已观察到录音条目点击打开右侧详情、设置页切换。验收实例已关闭，构建目录恢复为正式 lib/main.dart 入口。

复现 widgets 截图：

```sh
flutter test test/recording_detail_test.dart \
  --plain-name 'render recording UI previews' \
  --dart-define=RECORDING_PREVIEW_DIR="$PWD/build/ui-evidence"
```

截图字体仅在测试中加载系统字体，生产仍用平台默认字体。证据在忽略的 build 目录中，清理构建后可重新生成。

## 未完成的端到端验收

- 交互后系统桥接报 `Failed to update ui::AXTree` 已定位：上游 flutter/flutter#190357，Material Slider 的数值指示浮层经全局 Overlay 串入路由切换，序列化出无父可达的孤立节点。修复为 `InlinePlayer` 内用 `Overlay.wrap` 将滑块浮层限制在自身子树，导航结构、切页动画未改。原生回归 0 错误、逐帧语义更新回归红绿通过。完整 VoiceOver 人工朗读验收仍未执行，不记为通过。
- 未安装到 iPhone 实机；手机证据来自 Flutter 的指定尺寸/安全区/字体缩放测试。
- 未连接 D3200、实际录音、下载、调用转写服务、回听或执行系统分享/保存。这些业务实现未修改，自动测试通过不能替代实机验收。

本轮交付停在本地可审阅实现与上述验证，不合并或发布。
