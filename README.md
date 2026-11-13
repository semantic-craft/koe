<h1 align="center">Koe</h1>

<p align="center"><strong>以 Rust 管理录音与个人记忆，以原生 macOS 界面回顾每一天。</strong></p>

<p align="center">
  <img alt="Rust" src="https://img.shields.io/badge/Rust-2021-000000?style=flat-square&logo=rust&logoColor=white">
  <img alt="SwiftUI" src="https://img.shields.io/badge/SwiftUI-5.10%2B-F05138?style=flat-square&logo=swift&logoColor=white">
  <img alt="macOS 14+" src="https://img.shields.io/badge/macOS-14%2B-000000?style=flat-square&logo=apple&logoColor=white">
  <a href="https://github.com/semantic-craft/koe/actions/workflows/ci.yml"><img alt="CI" src="https://img.shields.io/github/actions/workflow/status/semantic-craft/koe/ci.yml?branch=main&style=flat-square&label=CI"></a>
  <img alt="Upstream license: MIT" src="https://img.shields.io/badge/Upstream_license-MIT-blue?style=flat-square">
</p>

<p align="center"><strong>简体中文</strong> · <a href="README.en.md">English</a></p>

Koe 让安克 soundcore Work（D3200）录音豆脱离飞书使用。Mac 通过蓝牙取回录音，在本机保留音频与文字，再将讨论整理为纪要、待办和记忆。也可以使用 Mac 麦克风录音、直接导入文件或新建文字记录。

产品从 macOS 开始。界面沿用三个连续入口：**今天回顾全天记录，记录详情查看原文与纪要，问 Koe 跨记录寻找答案。** 底层由 Rust 统一管理数据和处理状态，SwiftUI 负责展示与系统交互。

## 使用流程

1. **留下记录。** 在今天页选择 Mac 麦克风输入并录音，连接 D3200 取回录音，或导入 WAV、UTF-8 TXT、Markdown 和含文字内容的 `.koepack`。新建记录接受你实际输入的文字，空工作区保持为空。
2. **转写并整理。** 选择 Apple 本机识别、下载模型或云端识别，录音豆、Mac 麦克风与文件共享 Rust 管线。全天听记按五分钟片段保存，已完成片段在配置文字服务后增量整理，后续录音继续。文字服务可使用本机兼容接口或云端模型。
3. **确认行动与记忆。** 整理产生的候选项等待确认，可以接受、忽略、编辑或恢复。待办完成状态与记忆保留结果都写入本机工作区。
4. **回到来源。** 纪要、待办、记忆和问答保留记录与原文片段的引用。点击来源打开对应记录，返回后继续刚才的问答。有音频的记录支持播放和拖动进度，记录可以导出为 Markdown。

“今天”汇集当天记录、待确认内容和接下来要做的事，并支持按“全部 / 已归档”筛选。“所有记录”保存完整资料库；每条记录拥有自己的文字、纪要、重点和处理状态，支持逐句修订转写原文、还原原始识别文本、切换或批量合并说话人并在原文变更后提示重算纪要，也可开启归档防误删或移入 30 天“回收站”（支持底部即时撤销、恢复与彻底清除，彻底清除落盘后才删除本机音频）。全局问答可以限制在当前记录，也可以查询整个资料库。

未配置模型时，文字记录、浏览、审核、播放和本地检索仍可使用。“问 Koe”会明确返回原文检索结果；语音转写使用所选本机或云端引擎，生成式整理需要配置文字服务。

Mac 麦克风录音先保存本机 WAV，停止时排空已接收音频；输入设备变化会停止并保存已收到的部分。保存失败可重试，退出会等待保存。系统权限、真实音源切换与回放仍待 [#616](https://github.com/semantic-craft/koe/issues/616) 验收。支持暂停和继续，暂停会排空尾块，继续后接续原录音并排除暂停间隔。系统双路尚未接入；已有记录对应的暂存音频可在重开后恢复。

## 数据与服务边界

- 签名安装版使用 macOS 沙盒，默认工作区为 `~/Library/Containers/com.anker.ankerRecorder/Data/Library/Application Support/KoeWorkspace`。记录、审核结果和问答历史保存在 `product-workspace.json`，音频单独保存在 `audio/`。
- 签名安装版将云端密钥保存在 macOS Keychain，模型和服务地址由 Rust 工作区持久保存。工作区与页面快照不含密钥；清除后不会恢复旧版值。地址留空可重置为默认值，地址不接受账户、密码、查询参数或片段。
- 开发构建、指定工作区或设置了 `KOE_CREDENTIAL_SOURCE` 的运行使用隔离凭据；密钥仅保留当前会话，默认开发工作区为 `KoeWorkspaceDevelopment`。不读取个人 `.env` 或 `.envrc`，不回退到系统凭据。签名安装升级后的真实读取仍待 [#603](https://github.com/semantic-craft/koe/issues/603) 验收。
- 音频默认只留在本机。语音引擎选择和音频上传许可分别保存；本机引擎不可用时不会偷偷切换为云端。Apple 系统识别首次准备语言资源需要联网，下载模型首次获取文件需要联网。文字纪要与问答可使用独立的本机或云端文字服务。此前已经上传的音频无法撤回。
- 发起云端任务前保存请求状态，收到结果并完成本地保存后才显示完成。应用重启会将未完成任务标为中断；重新配置服务后，由用户明确重试，不在后台自动重发付费请求。
- 工作区存储保持单写者。Koe 运行期间在沙盒容器内开放属主私有的 `.koe/koe.sock` 本地桥接，CLI 与 MCP 进程优先经该桥接实时读写同一会话；Koe 未运行时才直接打开工作区文件锁。

## 离线识别与全天听记

在“设置 → 语音识别”选择 Apple 本机识别、下载离线模型或云端识别。下载目录提供 SenseVoice Small（约 253 MB）和 Qwen3 ASR 0.6B（约 850 MB）。模型下载后需要通过完整性校验和实际加载，才显示“使用此模型”。模型文件保存在工作区的 `speech-models/`，再次打开时复用已校验的文件。

下载模型在 Rust 进程内处理音频，不调用外部命令。它们采用分段识别，文字在每段处理完成后出现。Apple 本机识别依赖 macOS 26 及以上的系统能力，就绪后也可处理已有录音文件。

“允许将录音音频上传到云端”独立于识别引擎。切换引擎或下载模型不会打开上传许可。“文字整理服务”单独设置文本模型和完整对话接口地址；本机无认证的 HTTP localhost 服务可留空 API Key。转写可以完全离线，文字整理和问答是否联网取决于所选文字服务。

在“今天”或“录音”选择音源并开始全天听记。需要语音输入时，点击“开始语音输入”，说完后点击“结束语音输入”。这两个按钮圈定发送给外部输入法的文字范围，不停止全天听记。卡片中的“查看演示”展示两者的关系，演示不会启动采集或写入记录。

旧版资料迁移入口已移除。当前工作区及已经保存的记录继续读取，移除入口不会删除用户数据。

## 构建与运行

需要 macOS 14+、Xcode Command Line Tools（Swift 5.10+）、Rust 工具链和 CMake。Opus 从锁定的依赖源码静态构建，无需安装系统 `libopus`；Rust、C 和 Swift 的 macOS 最低版本统一为 14。

```bash
cargo build --package koe-host-api
swift build --package-path platforms/macos
```

安装本机签名版本：

```bash
./scripts/install-macos.sh
```

安装脚本使用已配置的 Developer ID 签名证书，生成 `/Applications/Koe.app`，并运行 `--verify-self` 与 `--smoke-test`。这两个入口使用隔离工作区检查应用流程，真实录音豆与云端长时使用另行验收。

开发检查：

```bash
./scripts/verify-local.sh --quick
./scripts/check
```

`--quick` 运行脚本、界面、进度契约与 Rust 编译/lint；完整入口继续运行 Rust 测试和 macOS 的 Swift 测试。贡献约定见 [CONTRIBUTING.md](CONTRIBUTING.md)。

## CLI 与 MCP

CLI、MCP 与原生应用共用同一 `KoeRuntime` 和本机工作区。Koe 运行时自动连接容器内的 `koe.sock` 实时桥接，未运行时离线直开工作区：

```bash
cargo run --package koe-cli -- status
cargo run --package koe-cli -- search "产品决定"
cargo run --package koe-cli -- ask "接下来要做什么"
cargo run --package koe-cli -- mcp-stdio
cargo run --package koe-cli -- companion-listen
```

`--workspace <目录>` 指定其他资料库；`search` 和 `ask` 支持 `--record <ID>` 限定记录。MCP stdio 暴露 16 项工具（检索、今日简报、记录列表与详情、问答、待办/记忆审核与修订、新建笔记、原文批注、分段修订与说话人管理、归档与软删恢复、设备状态与控制、代次轮询），不暴露彻底清除。设置页与 `companion-listen` 预留 D3200 领口待命与正面双击/快捷键 `16 kHz` `PCM16` 语音流订阅及蓝牙控制权移交，实体硬件验收见 [#641](https://github.com/semantic-craft/koe/issues/641)。通用输入法的定稿文字协议见 [本地文字桥](docs/local-text-bridge.md)。离线直开模式使用隔离凭据，不读取 GUI 的系统密钥。

## 架构

| 层 | 目录 | 责任 |
| --- | --- | --- |
| 领域与协议 | [koe-engine](crates/koe-engine/)、[koe-opus](crates/koe-opus/) | `ProductWorkspace`、每条记录的聚合、审核与来源规则、检索、D3200 协议；独立的 libopus 安全封装 |
| 客户端服务 | [koe-client-base](crates/koe-client-base/)、[core](crates/koe-client-core/)、[providers](crates/koe-client-providers/)、[services](crates/koe-client-services/) | 文件锁与原子保存、资料格式、真实网络传输、音频导入和工作区存储 |
| 运行时与接口 | [koe-runtime](crates/koe-runtime/)、[koe-host-api](crates/koe-host-api/) | 协调设备、异步任务和持久化，生成版本 2 的快照与意图接口 |
| 原生宿主与 CLI | [apple-shared](platforms/apple-shared/)、[macos](platforms/macos/)、[koe-cli](crates/koe-cli/) | SwiftUI 页面、窗口、CoreBluetooth、文件选择与播放；共享运行时的命令行入口 |

架构约束与数据流见 [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)，后续范围见 [ROADMAP.md](ROADMAP.md)。iOS/Android 宿主、屏幕与系统音频采集、翻译、Google 同步、自动备份与 ACP 接入不属于当前已接通的 macOS 产品流程。

## 参考与致谢

D3200 协议建立在 [tacshi/Soundcore](https://github.com/tacshi/Soundcore) 的逆向成果上，协议记录见 [PROTOCOL.md](PROTOCOL.md)。架构与产品设计参考 [metasequoiaime/msime](https://github.com/metasequoiaime/msime) 的原生宿主分层、[BasedHardware/omi](https://github.com/BasedHardware/omi) 的个人记忆流程，以及 [screenpipe/screenpipe](https://github.com/screenpipe/screenpipe) 的时间记录组织。参考版本与检索约定见 [reference-code.md](docs/agents/reference-code.md)。

结构化纪要提示词还参考了 Meetily 与 Ownscribe，来源和许可记录见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。安全问题按 [SECURITY.md](SECURITY.md) 私下报告。

## 许可证

[tacshi/Soundcore](https://github.com/tacshi/Soundcore) 已采用 MIT 许可，Copyright (c) 2026 Rocky Shi。Koe 沿用的协议文档与移植实现保留该署名，完整许可见 [soundcore.txt](assets/licenses/soundcore.txt)，来源版本与采纳范围见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

仓库目前保持私有，暂不公开发布。Cargo 包元数据中的 MIT 字段不替代各第三方组件的许可。macOS 安装包在 `Koe.app/Contents/Resources/Licenses/` 内附带第三方说明与许可正文。
