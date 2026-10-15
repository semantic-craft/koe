> **Private mirror — self-use only.** Source: https://github.com/tacshi/Soundcore (upstream author: [tacshi](https://github.com/tacshi)). Upstream has **no license**; all rights remain with the author. Private personal use only — **not for redistribution**; do not make this repository public.

# Soundcore Manager（安克录音豆）

**soundcore Work**（安克 AI 录音豆 / **D3200**）本地管理 App，基于逆向出的设备协议（见 [`PROTOCOL.md`](PROTOCOL.md)）用 Flutter 实现，脱离飞书 App 独立使用：BLE 配对连接、录音管理、AI 实时/批量转写、Wi‑Fi SoftAP 批量导出。

## 开发状态

开发计划与验收以 [GitHub 总工单 #6](https://github.com/semantic-craft/koe/issues/6) 为入口。当前包含多引擎转写和暖色双端布局；已接入千问长录音上传及 Qwen3.8-Flash 摘要/自定义分析，摘要、结构化纪要和思维导图已有双端短录音验收；剩余范围见 [当前进度](docs/product-progress.md)。双端同步和跨录音问答暂不实施。代码、自动测试、真实服务和真机验收分别记录，平台目录存在不代表整条使用流程已经验收。

## 支持平台

| 平台 | 状态 |
|------|------|
| Android | BLE 扫描 / GATT |
| iOS | BLE 扫描 / GATT |
| macOS | BLE 扫描 / GATT（需 Bluetooth entitlement） |

## 功能

- **首页**：浏览本地与设备端录音，下拉刷新、长按批量选择；点开详情阅读全文、翻译、播放、分享或重命名
- **录音详情**：实时转写与保存后的文本使用同一详情页；返回首页不停止录音，暂停后保留当前页面。向上滚动可阅读旧内容，点「最新内容」恢复跟随
- **设备**：电量（耳机 + 充电盒）、录音控制、配对绑定 / 解绑、恢复出厂设置
- **设置**：选择 Apple 设备端、通义 Qwen 或豆包，准备语言、自动转写、API Key 管理与诊断日志
- **扫描**：首页顶部按钮触发底部弹窗（非独立 Tab）搜索并连接 BLE 设备
- **Wi‑Fi 批量导出**：SoftAP 直连 + AES 解密，导出文件本地播放
- **iPhone 操作按钮**：从锁屏或其他 App 打开本应用，并让已绑定的 D3200 立即开始录音

## 配置 iPhone 操作按钮

安装并至少连接一次录音豆后，在支持操作按钮的 iPhone 上打开：

1. **设置 → 操作按钮 → 快捷指令**。
2. 选择 **安克录音豆 → Start Recording**。
3. 长按操作按钮。App 会打开；如果录音豆暂时离线，会先自动重连再开始录音。

录音已经进行时再次运行快捷指令只会回到当前实时会话，不会重复发送开始命令。若 30 秒内找不到已绑定设备，请唤醒并靠近录音豆后重试。

## 项目结构

```
lib/
├── ai/          # Apple / 千问 / 豆包转写（实时 + 文件）
├── audio/       # Ogg/Opus 封装、Opus→PCM 解码
├── ble/         # 扫描广播解析、GATT 服务、离线文件拉取、实时音频流
├── crypto/      # 设备端 ECDH / AES 会话加解密
├── protocol/    # 帧格式、命令字、数据模型
├── state/       # Provider 状态：设备连接、录音、转写、导出目录、App 设置
├── theme/       # 主题与配色
├── ui/          # 首页 / 设备 / 设置页面与组件
└── wifi/        # SoftAP 连接与批量导出服务
```

## 运行

```bash
# macOS（推荐用脚本）
./scripts/debug-mac.sh              # flutter run -d macos --debug
./scripts/debug-mac.sh --build-only # 仅构建 debug .app
./scripts/debug-mac.sh --open       # 构建 debug .app 并打开

# 其他平台
flutter run -d ios
flutter run -d android
```

## 构建

```bash
# macOS 本机安装（固定 Developer ID 签名，升级后保留 Keychain 访问）
./scripts/install-macos.sh           # 先退出已安装 App，再构建并安装
./scripts/install-macos.sh --skip-build # 安装已有 Release 构建

# macOS release + DMG → dist/soundcore-manager-<version>-macos.dmg
./scripts/build-dmg.sh
./scripts/build-dmg.sh --open       # 构建后在 Finder 中显示 DMG
./scripts/build-dmg.sh --skip-build # 打包已有的 Release .app

# iOS 真机安装（Xcode 签名）
./scripts/install-ios.sh

flutter build ios
flutter build apk   # 或 appbundle
```

## 测试

```bash
flutter test
```

覆盖协议帧编解码、设备加解密、Opus/Ogg 处理、导出目录、STT 数据模型等核心逻辑（`test/`）。

## 说明

- **Apple 设备端处理**（iOS 26+，取决于设备和语言）：D3200 实时音频与已保存录音可在 iPhone 上转写；支持实时单向翻译及已有转写文本的翻译。实时录音语言在设置中选择；已有录音可在转写或重新转写时选择语言，并按提示下载资源。Apple 处理失败不会自动切换到云端。云端 ASR 当前不提供翻译或双向交流。
- **密钥存储**：iPhone/Mac 用户 Key 使用系统 Keychain，旧配置验证迁移后移除明文；可清除已保存 Key，安全存储异常可从设置重读。开发环境注入不回写。见 [迁移与验证](docs/credential-storage-validation.md)。
- **配置**：豆包只填写 API Key；千问填写 API Key 和可选 Workspace ID。程序自动选择服务地址与模型，首次保存后自动启用并关闭配置窗口。
- **摘要与分析**：录音详情点击“摘要与分析”，手动生成摘要或输入自定义要求；使用 Qwen3.8-Flash 与已有千问 Key。结果独立保存，可复制、导出和查看原文依据；长文分段处理并保留完成进度。
- **结构化纪要**：在“摘要与分析”进入纪要，使用千问生成议题、决策、待办及未决问题；支持编辑、来源回溯与 Markdown 导出。验证范围见 [交付记录](docs/structured-minutes-validation.md)。
- **思维导图**：从结构化纪要直接生成，可缩放、折叠、查看原文并导出完整 PNG；不再次调用模型。大图限制与验证见 [交付记录](docs/mind-map-validation.md)。
- **豆包极速版上传**：按 100 MB / 2 小时分别检查，优先使用匹配的压缩录音；分块 Base64 上传，可停止等待，结果未知时不自动重发。范围及验证见 [交付记录](docs/doubao-upload-validation.md)。
- **千问长录音**：支持范围以模型规格与当前临时上传限制共同约束；分块封装与上传，保留已提交任务供重启后查询。短录音链路验收及长时使用边界见 [交付记录](docs/qwen-long-recording-analysis.md)。
- **文件转写**：千问默认 `qwen-audio-3.1-asr-flash-filetrans`；豆包使用极速版 `volc.bigasr.auc_turbo`，本地文件直接上传，上限为 100,000,000 字节及 2 小时，优先选择匹配的压缩录音。按当前产品决定，不接入豆包标准版；超过豆包支持范围时明确提示，用户可手动选择已配置的千问，不自动切换供应商。
- **实时转写**：BLE Opus → PCM16 → 服务商 WebSocket。千问使用 `qwen-audio-3.1-asr-flash-streaming`；豆包使用 `volc.seedasr.sauc.duration`，优化双向流式接口开启 `enable_nonstream` 二遍识别。成功的实时结果不再自动重复提交文件；实时未完成时由同一服务的文件任务补齐。
- **配置与验收**：在设置中保存服务商 Key。Helios 开发可参考 `.envrc.example`，通过 `direnv exec . python3 scripts/run-with-secrets.py macos` 给已安装 Mac App 注入凭据；凭据不会编入产物。iPhone 普通使用仍通过设置保存 Key。真实样本、接口限制与双端验收见 [语音服务替换验证](docs/speech-provider-validation.md)。
- **Wi‑Fi SoftAP 批量导出 + 解密**：BLE 连接后先做 ECDH 握手（`0x2E/0x01`）生成会话密钥；导出时打开设备 SoftAP → 加入 → WebSocket 拉取，每 160 字节分片用 `1A07` 头（`soundcored3200` magic）中的单文件密钥做 AES‑CTR 解密。导出文件保存在 `Documents/AnkerRecorder/exports` 下，命名为 `{fileId}.opus`（握手失败则为 `.opus.bin`）。本地**播放**使用 `just_audio` 播放已导出文件。
- 设备协议细节（服务/特征 UUID、命令字、加密流程等）见 [`PROTOCOL.md`](PROTOCOL.md)。
- 请保持蓝牙开启；旧版 Android 扫描需授予定位权限。
- 录音进行中修改处理服务、模式或语言，将在下次录音生效。旧服务的历史文本和来源保留，旧密钥不再读写，未完成的旧任务不会自动改投新服务。有效的已选服务优先；否则优先已配置的千问，再考虑 Apple。
