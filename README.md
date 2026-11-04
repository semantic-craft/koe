<p align="center">
  <img src="macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_128.png" alt="Koe" width="96" height="96">
</p>

<h1 align="center">Koe</h1>

<p align="center"><strong>不用飞书，直接用安克录音豆录音、转写，并把每天的事整理成能交给 AI 的个人记录。</strong></p>

<p align="center">
  <a href="https://flutter.dev"><img alt="Flutter 3.47.7" src="https://img.shields.io/badge/Flutter-3.47.7-02569B?style=flat-square&logo=flutter&logoColor=white"></a>
  <img alt="iOS 15+" src="https://img.shields.io/badge/iOS-15%2B-000000?style=flat-square&logo=apple&logoColor=white">
  <img alt="macOS 12+" src="https://img.shields.io/badge/macOS-12%2B-000000?style=flat-square&logo=apple&logoColor=white">
  <img alt="Android 17 (Pixel 11 Pro)" src="https://img.shields.io/badge/Android-17%20%C2%B7%20Pixel%2011%20Pro-3DDC84?style=flat-square&logo=android&logoColor=white">
  <a href="https://github.com/semantic-craft/koe/actions/workflows/ci.yml"><img alt="CI" src="https://img.shields.io/github/actions/workflow/status/semantic-craft/koe/ci.yml?branch=main&style=flat-square&label=CI"></a>
  <img alt="License pending" src="https://img.shields.io/badge/License-pending-lightgrey?style=flat-square">
</p>

<p align="center">
  <strong>简体中文</strong> · <a href="README.en.md">English</a>
</p>

---

> [!IMPORTANT]
> Koe 建立在 [tacshi/Soundcore](https://github.com/tacshi/Soundcore) 的原始 D3200 应用和协议逆向之上。上游项目目前没有许可证，本仓库在原作者授权前不会公开发布。详见 [致谢](#致谢) 与 [许可](#许可)。

## 为什么做 Koe

安克 soundcore Work（录音豆，型号 D3200）是一枚可以别在衣服上的小录音器。官方使用方式绑定在飞书里：录音要上传到飞书妙记才能转写，整理结果也留在飞书。

Koe 让这枚录音豆脱离飞书独立工作：手机或 Mac 通过蓝牙直接连接录音豆，取回原始录音，用你自己选的模型（Apple 设备端、通义千问或豆包）转写和整理。原音频永久留在本机，每一句文字都能点回原声。

在此之上，Koe 逐步长成一个手机优先的个人记录工具：录音、地点、待办和日记按天汇总，可以按项目持续跟进，最后整理成文件交给外部 AI。

## 功能

### 录音与转写

- 蓝牙扫描、配对和绑定录音豆；查看录音豆与充电盒电量，远程开始、暂停录音；结束录音使用录音豆实体按键
- 实时转写：录音时边说边出文字，可选实时翻译（Apple 设备端）
- 从录音豆取回录音（蓝牙或 Wi‑Fi 直连批量导出），续录变长的录音会自动补取
- 手机（iPhone、Pixel）麦克风也能直接录音，锁屏继续，来电自动暂停，进程被杀后下次启动找回
- 文件转写：千问长录音分块上传，豆包极速版；提交后的任务在重启后继续查询
- iPhone 操作按钮 / 快捷指令一键让录音豆开始录音；Android 长按 Koe 图标选「开始录音」

### 回听与校订

- 逐字稿按句段点击回听原声，锁屏也能继续播放
- 校订文字、标注发言人后仍保留到原声的对应关系
- 片段批注与书签，原声连续收听队列
- 发言人分布：按时间线查看每个人说了多久，点片段直达原句
- 译文与原文逐句对应，点译文听原句
- 摘要、自定义分析、结构化纪要（议题 / 决策 / 待办）和思维导图，每条结论都能回到原文出处

### 今日 · 项目 · 待办

- 「今日」时间线汇总当天的录音和记录，可纠正它们所属的主题
- 项目跨天持续跟进；主题笔记与主题汇总
- 从对话里的承诺自动生成待办，可导出到 iPhone 的提醒事项和日历（Android 导出到系统日历）
- 录音自动记录大致地点，也可手动补充
- 新录音自动整理：转写 → 摘要 → 提取待办 → 完整分层纪要，中断后可恢复
- 开启自动整理后，录音豆的确定转写持续生成阶段摘要；结束录音并收齐末句后生成完整版。“只留本机”时不自动发送实时文字。真实设备全流程仍在 Slice C 验收

### 日记 · 问 Koe · 晨报

- 每条都带来源的日记和周小结
- 「问 Koe」：在手机上对自己的记录连续提问，可以按住说话提问，回答可选朗读
- 晨报：按需生成昨天的要点

### 导出给 AI

- 本机 [只读 MCP](tools/koe-mcp/README.md)：用 Python 3 从指定目录读取无音频 `.koepack`，向 agent 提供文稿和已有纪要；无需安装依赖，客户端连接另行配置
- 按天、项目或主题导出 Markdown，交给你常用的外部 AI
- 资料包（`.koepack`）导出与重新导入：在另一台设备或重装后恢复校订、时码、发言人、书签、地点和主题，原音频可选是否带上
- 手机原件自动归档到自己的 Mac（局域网加密直连，校验后才确认）

## 截图

> 截图待补：公开发布前用演示数据重新截取，不使用真实录音与地点。

| 今日 | 录音详情 | 问 Koe |
| --- | --- | --- |
| _待补_ | _待补_ | _待补_ |

## 支持的硬件

| 设备 | 型号 | 状态 |
| --- | --- | --- |
| 安克 soundcore Work（AI 录音豆） | D3200 | 支持：蓝牙连接与控制、实时音频、离线文件取回、Wi‑Fi SoftAP 批量导出 |

其他 soundcore 录音设备未测试。设备协议细节见 [PROTOCOL.md](PROTOCOL.md)。

| 平台 | 状态 |
| --- | --- |
| iOS 15+ | 主力平台。Apple 设备端转写与翻译需要 iOS 26+ |
| macOS 12+ | 会议纪要端与原件归档端；会议纪要功能分期建设中（见 [ROADMAP](ROADMAP.md)），Apple 设备端转写需要 macOS 26+ |
| Android 17 | 只适配 Pixel 11 Pro，代码已合并，待真机验收（#345）。没有 Apple 设备端转写与翻译、提醒事项和 Mac 归档 |

## 快速开始

### 准备

- macOS 与 Xcode（含 iOS 平台），CocoaPods
- Android：Android SDK（compileSdk 37）与 JDK 21
- Flutter 3.47.7（与 CI 一致）
- 一枚 soundcore Work D3200 录音豆（没有录音豆也能用手机录音、导入音频和其余功能）
- 可选：[通义千问（DashScope）](https://dashscope.aliyun.com/) 或 [豆包语音](https://www.volcengine.com/product/voice-tech) 的 API Key

### 安装依赖并运行

```bash
git clone https://github.com/semantic-craft/koe.git
cd koe
flutter pub get
```

```bash
flutter run -d macos
```

```bash
flutter run -d ios
```

```bash
flutter run -d pixel
```

iOS 真机需要在 Xcode 里为 `ios/Runner.xcworkspace` 选择你自己的开发团队。仓库里的 `scripts/install-ios.sh`、`scripts/install-macos.sh` 和 `scripts/build-dmg.sh` 是维护者的安装与打包脚本，运行前先看清目标设备和签名身份。

如果从旧的 SPM 构建切换过来，遇到 `local binary target opus ... does not contain a binary artifact`，先运行 `flutter clean` 再 `flutter pub get`。

### 安装到 Mac

```bash
./scripts/install-macos.sh
```

构建 Release 并安装到 `/Applications/Koe.app`（需要 Developer ID 签名身份）。`./scripts/build-dmg.sh` 打包到 `dist/koe-<version>-macos.dmg`。

### 配置 iPhone 操作按钮

装好 Koe 并至少连接一次录音豆后：

1. 打开 iPhone 的「设置 → 操作按钮 → 快捷指令」。
2. 选择 **Koe → 开始录音**（快捷指令里的动作标题是「用 Koe 开始录音」）。
3. 长按操作按钮：Koe 会打开，录音豆离线时先自动重连再开始录音。

### 配置千问 / 豆包 API Key

1. 打开 Koe 的「设置 → 语音服务」。
2. 选择服务商：
   - **通义千问**：填写 API Key，Workspace ID 可选。摘要、纪要、问 Koe 等整理功能也使用千问。
   - **豆包**：只填写 API Key（使用极速版文件转写和流式识别）。
   - **Apple 设备端**：不需要 Key，iOS 26+ 可用，处理全部在本机完成。
3. 保存后自动启用。服务地址和模型由程序选择。

Key 保存在系统 Keychain（Android 上是 Keystore 加密存储）中，不写入设置文件。开发与调试构建默认使用隔离的内存存储，不会读写你个人 Keychain 里的 Key。

### 测试

```bash
flutter analyze
```

```bash
flutter test
```

连着 Pixel 时，`scripts/android-check` 构建并安装独立验收包（`com.semanticcraft.soundcore.verification`），保留正式版的录音和配置，在手机上跑 [integration_test/android](integration_test/android/) 的无人值守场景。跑之前解锁手机、放着别动：脚本让屏幕一直亮着，锁屏的场景排在最后；手机锁着时，需要 Koe 在屏幕上的场景记为跳过。设备离线或有场景跳过时以 77 退出，记为跳过。

## 架构

Koe 是一个 Flutter 应用，状态由 Provider 管理的 `RecorderController` 统一协调，按功能拆成多个 part 文件；个人记录（时间线、待办、项目、日记、问答）是一组独立的 JSON 存储。

```
录音豆 D3200 ──BLE/Wi‑Fi──▶ ble/ wifi/ protocol/ crypto/
                                  │  取回的 Opus 音频
                                  ▼
                              audio/ ──▶ ai/（Apple / 千问 / 豆包 转写）
                                  │
                                  ▼
                 state/（录音库、转写任务、个人记录）──▶ ui/
                                  │
                                  ▼
                   导出 Markdown / 资料包 · Mac 归档（archive/）
```

| 目录 | 内容 |
| --- | --- |
| [lib/ble](lib/ble/) | 广播解析、GATT 服务、离线文件拉取、实时音频流 |
| [lib/protocol](lib/protocol/) | 帧格式、命令字、数据模型 |
| [lib/crypto](lib/crypto/) | 设备 ECDH / AES 会话加解密 |
| [lib/wifi](lib/wifi/) | SoftAP 连接与批量导出 |
| [lib/audio](lib/audio/) | Ogg/Opus 封装、Opus→PCM 解码、音频转换 |
| [lib/ai](lib/ai/) | 转写服务：Apple 设备端、千问、豆包 |
| [lib/state](lib/state/) | 控制器与持久化；[recorder/](lib/state/recorder/) 按功能分块，[context/](lib/state/context/) 是个人记录 |
| [lib/archive](lib/archive/) | 手机到 Mac 的原件归档 |
| [lib/platform](lib/platform/) | 钥匙串与 Keystore、地点、提醒事项与日历、快捷指令、Android 前台服务等平台接入 |
| [lib/ui](lib/ui/) | 页面与组件 |
| [darwin](darwin/)、[ios](ios/)、[macos](macos/) | Apple 原生代码 |
| [android](android/) | Android 原生代码：前台服务与通知、快捷方式 |
| [test](test/)、[integration_test](integration_test/) | 单元、组件与性能测试 |

术语见 [GLOSSARY](GLOSSARY.md)，设计决策见 [docs/adr](docs/adr/)，界面规范见 [docs/design/ui-guidelines.md](docs/design/ui-guidelines.md)。

## 路线图

当前做什么、下一步、什么暂不做，见 [ROADMAP.md](ROADMAP.md)；版本变化见 [CHANGELOG.md](CHANGELOG.md)。

## 参与贡献

欢迎提 Issue 和 PR。开始前请读 [CONTRIBUTING.md](CONTRIBUTING.md)：只经分支和 PR 交付，PR 要写清三项验收（回退测试、真实使用情况、没跑到的项目）。安全问题请按 [SECURITY.md](SECURITY.md) 私下报告，**不要在 Issue 里贴任何 API Key**。

## 致谢

**Koe 的起点是 [tacshi](https://github.com/tacshi)（Rocky Shi）的 [tacshi/Soundcore](https://github.com/tacshi/Soundcore)。** 这个项目最早写出了脱离飞书使用 D3200 的应用，并完成了录音豆蓝牙与 Wi‑Fi 协议的逆向：服务与特征 UUID、帧格式和命令字、ECDH 握手与 AES 解密、离线文件拉取、SoftAP 批量导出。[PROTOCOL.md](PROTOCOL.md) 就是这份逆向工作的记录。没有它，就没有 Koe。

Koe 的蓝牙、协议、加解密、音频和 Wi‑Fi 模块仍有相当部分源自上游代码。

结构化纪要的整理规则参考了 Meetily 与 Ownscribe（MIT），详见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

## 许可

**License pending：上游项目目前还没有许可证；在原作者授权之前，本仓库不会公开发布。**

在此之前，上游代码的全部权利归原作者所有，本仓库仅供私人使用，请勿再分发。

Android 离线发言人区分场景：`KOE_DIARIZATION_FIXTURES=/path/to/fixtures scripts/android-check integration_test/android/diarization_test.dart`。目录需包含生产固定版本的 `segmentation-model.onnx`、`3dspeaker_speech_campplus_sv_zh_en_16k-common_advanced.onnx` 和 [sherpa 官方四人中文样例](https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-segmentation-models/0-four-speakers-zh.wav)。模型仍由生产校验逻辑核对 SHA-256；场景禁用模型网络请求、调用真实 Android 解码和原生推理。样例人数检查不代表独立会议 DER 达标。

独立会议评测可用 `dart tool/diarization_eval.dart --cache-dir /path/to/models --audio meeting-mono-16k.wav --reference meeting.rttm --clip-seconds 600 --ami-only --mode both --output-prefix meeting`；音频和人工 RTTM 必须成对提供，保留语料来源、许可、声道和截取区间。
