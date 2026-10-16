# #39 文档统一与跨平台改名验收

核对基线：`origin/main` @ `932b60cf4fefcac3293fdb9e541b939f36f5df40`。主名称 **Koe**，副标题 **适配安克录音豆**，完整介绍 **Koe — 安克录音豆录音与转写工具**（`pubspec.yaml` 的 `description` 与 README 主标题）。

本页只记录本次核对。历史验收文档里的安装路径和当时的窗口名保持原样，不拿来充当这次的通过结论。

## 用户入口

| 入口 | 本次对齐的产物 |
| --- | --- |
| README 主标题 | 完整介绍名称 |
| `scripts/install-macos.sh` | 默认 `/Applications/Koe.app`；改名前的 `Soundcore Manager.app` 在安装成功后打包再移除 |
| `scripts/build-dmg.sh` | `dist/koe-<version>-macos.dmg`，卷名与包名都是 Koe |
| iPhone 操作按钮步骤 | 应用名 Koe，快捷指令短标题「开始录音」，动作标题「用 Koe 开始录音」 |

回归：`test/readme_install_identity_test.dart` 把 README 和上述脚本、`ios/Runner/RecordingShortcut.swift` 对照。改动前第一条断言失败：主标题实际是「# Soundcore Manager（安克录音豆）」。当时 README 还写着 `dist/soundcore-manager-<version>-macos.dmg` 和「安克录音豆 → Start Recording」。修后该用例通过，并包含在全量 `flutter test` 里。

## 旧名称残留分类

扫描范围是仓库里仍出现的改名前应用名（Soundcore Manager、`soundcore-manager`）以及容易被当成应用名的「安克录音豆」。设备协议、上游署名、历史证据和兼容标识保留，不改写。

### 保留：兼容标识

改这些会拆开已安装的数据、快捷指令或已发出的请求，本轮不动。

| 标识 | 位置 |
| --- | --- |
| macOS Bundle ID `com.anker.ankerRecorder` | `macos/Runner/Configs/AppInfo.xcconfig`、`scripts/sign-macos.sh`、`darwin/KeychainStore.swift` |
| iOS Bundle ID `com.semanticcraft.soundcore` | `ios/Runner.xcodeproj/project.pbxproj` |
| URL 名 `com.anker.soundcoreManager`、scheme `soundcore` | `macos/Runner/Info.plist`、`ios/Runner/Info.plist` |
| 数据目录 `Documents/AnkerRecorder` 与开发隔离目录 `AnkerRecorderDevelopment` | `lib/state/`、`lib/wifi/`、`lib/ble/` |
| 快捷指令类型 `StartRecordingIntent`、`SoundcoreAppShortcuts`，通道 `com.capyvibe.soundcore/recording_shortcut`，待执行键 `recordingShortcut.pendingStartRecording` | `ios/Runner/RecordingShortcut.swift` |
| 后台同步通道 `com.anker.anker_recorder/background_sync` | `lib/platform/background_sync_service.dart` |
| 转写请求里的 `uid` `soundcore-manager` | `lib/ai/cloud_stt_stream.dart` |
| Ogg vendor `AnkerRecorder` | `lib/audio/ogg_opus.dart` |
| Android 包名 `com.anker.anker_recorder` | `android/`（本轮不改，见下） |

### 保留：设备协议与硬件称谓

`PROTOCOL.md`、`lib/protocol/`、`lib/ble/`、`lib/crypto/` 里的 Anker、soundcore、D3200、`soundcored3200` 是设备协议和硬件型号。界面里的「安克录音豆」「soundcore Work / D3200」是适配设备，不是应用名（`lib/app_identity.dart` 副标题仍是「适配安克录音豆」）。

### 保留：上游署名

README 首段仍指向 https://github.com/tacshi/Soundcore，并写明上游无许可证、权利归原作者。`PRODUCT_COPYRIGHT` 仍是「基于 tacshi/Soundcore 修改，上游代码权利归原作者 tacshi 所有；仅供私人自用。」

### 保留：历史验收事实

这些句子描述的是当时的安装事实，不改成现在的名称。

- `docs/recording-processing-validation.md`：当时覆盖安装到 `/Applications/Soundcore Manager.app`
- `docs/brand-35-evidence/README.md`：当时系统窗口名仍是「安克录音豆」，并写明那属于后续平台工单
- `docs/credential-storage-validation.md`、`lessons.md`：凭据与签名验收当时的路径和 Bundle ID

### 保留：旧 macOS 包的退役路径

`scripts/retire-legacy-macos-app.sh`、`scripts/install-macos.sh` 的 `--keep-legacy` 提示、`skills/verify-koe/` 以及对应测试仍用 `Soundcore Manager.app` 指改名前的那一个包。它和 Koe 共用 Bundle ID，退役脚本靠可执行文件名把它和 `Koe.app` 分开。

### 未改、未验收：Android（#38）

[#38](https://github.com/semantic-craft/koe/issues/38) 未合并（PR #62 仍开放）。本轮不改 `android/**`，也不跑 Android 构建。源码现状：

- `android/app/src/main/AndroidManifest.xml` 的 `android:label` 仍是「安克录音豆」
- `RecordingSyncService.kt` 的通知标题仍是「安克录音豆」，渠道 ID `recording_sync` 与通知 ID `3200` 未改

因此 Android 的系统名称、图标、权限说明和通知 **未验收**。不能写成三平台都已通过。

## 三平台核对

版本来自本次构建的 Info.plist（`CFBundleShortVersionString` / `CFBundleVersion`），对应仓库 `pubspec.yaml` 的 `1.0.0+1`。未安装到本机或真机，所以没有「关于」面板、主屏幕、系统通知中心或操作按钮的人工核对。

| 项 | macOS | iOS | Android |
| --- | --- | --- | --- |
| 核对方式 | `flutter build macos --release` 后读 `Koe.app`；`scripts/build-dmg.sh` 生成并挂载 DMG | `flutter build ios --release --no-codesign` 后读 `Runner.app` | 未构建。#38 未合并 |
| 版本 | 1.0.0 (1) | 1.0.0 (1) | 未验收 |
| 系统名称 | `CFBundleName` / `CFBundleDisplayName` / 可执行文件均为 Koe。Bundle ID 仍是 `com.anker.ankerRecorder` | `CFBundleName` / `CFBundleDisplayName` 均为 Koe。Bundle ID 仍是 `com.semanticcraft.soundcore`。产物名仍是 `Runner.app` | 源码 `android:label` 仍为「安克录音豆」，未验收 |
| 应用内品牌 | `AppIdentity.name` = Koe；设置里「关于 Koe」。本次未打开真实窗口 | 同左，共用 Flutter 界面。本次未在 iPhone 上打开 | 未验收 |
| 图标 | 包内有 `Contents/Resources/AppIcon.icns`。未看 Finder / Dock 里的实际图标 | 包内有 `AppIcon60x60@2x.png`、`AppIcon76x76@2x~ipad.png` 和 `Assets.car`。未看主屏幕 | 未验收 |
| 权限说明 | 蓝牙两条与本地网络说明都以「Koe」开头，并写明安克录音豆。未弹出系统权限框 | 同左。未弹出系统权限框 | 未验收 |
| 通知 | 无应用级通知渠道 | 无 `UNUserNotification` 文案 | 通知标题仍是旧文案，未验收 |
| 快捷入口 | 已编进包的菜单字符串为 About Koe、Hide Koe、Quit Koe。本次未点菜单 | 产物 `Metadata.appintents` 的动作标题是「用 Koe 开始录音」，说明含完整介绍名称。本次未在快捷指令里运行 | 无对等的操作按钮入口；后台通知未验收 |

DMG：`dist/koe-1.0.0-macos.dmg`（`pubspec` 版本 1.0.0）。只读挂载后卷名为 Koe，内有 `Koe.app` 和指向 `/Applications` 的符号链接；包内标识、显示名、可执行文件均为 Koe，版本 1.0.0 (1)。挂载后已卸载。未拖进 `/Applications`，未启动。版权字符串仍是上游 tacshi/Soundcore 署名。`soundcore` URL scheme 仍在。

## 数据与配置（本次）

本次 diff 不改 Bundle ID、`Documents/AnkerRecorder`、`soundcore://`、设备协议标识、快捷指令动作类型，也不改凭据配置。

未做覆盖安装，没有读取已有录音、配置、设备绑定或任务记录。**未在真实环境验证。** `docs/credential-storage-validation.md` 和 `docs/recording-processing-validation.md` 里的旧安装记录不能代替这次。

## 实施工单的三项证据

| 工单 | 回退测试 | 真实使用 | 没跑到的项目 |
| --- | --- | --- | --- |
| #36 → PR #56，已合并 `75749ac` | `test/macos_koe_identity_test.dart` 与退役脚本用例；合并说明写了改动前会失败 | 合并说明记录了本机构建 `Koe.app`。真机安装、升级读数据和 DMG 挂载不在那次结论里 | 签名 DMG 与真机替换旧包留给用户 |
| #37 → PR #61，已合并 `6eb2b22` | `test/ios_koe_identity_test.dart` 锁显示文案和图标尺寸 | 合并说明写明未在真实环境验证 | 真机覆盖安装、主屏幕图标、已有快捷指令未跑 |
| #38 → PR #62，未合并 | 不在 main 上，本次不算通过 | 未验收 | Android 全部未验收 |

#36 / #37 的合并说明是当时的记录。上面「三平台核对」和「数据与配置」才是这一次的证据。
