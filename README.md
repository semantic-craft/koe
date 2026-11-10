<h1 align="center">Koe</h1>

<p align="center"><strong>以 Rust 管理录音与个人记忆，以原生 macOS 界面回顾每一天。</strong></p>

<p align="center">
  <img alt="Rust" src="https://img.shields.io/badge/Rust-2021-000000?style=flat-square&logo=rust&logoColor=white">
  <img alt="SwiftUI" src="https://img.shields.io/badge/SwiftUI-5.10%2B-F05138?style=flat-square&logo=swift&logoColor=white">
  <img alt="macOS 14+" src="https://img.shields.io/badge/macOS-14%2B-000000?style=flat-square&logo=apple&logoColor=white">
  <a href="https://github.com/semantic-craft/koe/actions/workflows/ci.yml"><img alt="CI" src="https://img.shields.io/github/actions/workflow/status/semantic-craft/koe/ci.yml?branch=main&style=flat-square&label=CI"></a>
  <img alt="License pending" src="https://img.shields.io/badge/License-pending-lightgrey?style=flat-square">
</p>

<p align="center"><strong>简体中文</strong> · <a href="README.en.md">English</a></p>

Koe 让安克 soundcore Work（D3200）录音豆脱离飞书使用。Mac 通过蓝牙取回录音，在本机保留音频与文字，再将讨论整理为纪要、待办和记忆。也可以直接导入文件或新建文字记录。

产品从 macOS 开始。界面沿用三个连续入口：**今天回顾全天记录，记录详情查看原文与纪要，问 Koe 跨记录寻找答案。** 底层由 Rust 统一管理数据和处理状态，SwiftUI 负责展示与系统交互。

## 使用流程

1. **留下记录。** 连接 D3200 取回录音，或导入 WAV、UTF-8 TXT、Markdown 和含文字内容的 `.koepack`。新建记录接受你实际输入的文字，空工作区保持为空。
2. **转写并整理。** 阿里云百炼 DashScope 负责语音转写，Qwen 负责结构化纪要。录音豆实时音频与已保存录音都通过 Rust 处理管线进入同一条记录；转写完成后继续整理纪要。
3. **确认行动与记忆。** 整理产生的候选项等待确认，可以接受、忽略、编辑或恢复。待办完成状态与记忆保留结果都写入本机工作区。
4. **回到来源。** 纪要、待办、记忆和问答保留记录与原文片段的引用。点击来源打开对应记录，返回后继续刚才的问答。有音频的记录支持播放和拖动进度，记录可以导出为 Markdown。

“今天”汇集当天记录、待确认内容和接下来要做的事。“所有记录”保存完整资料库；每条记录拥有自己的文字、纪要、重点和处理状态。全局问答可以限制在当前记录，也可以查询整个资料库。

未配置模型时，文字记录、浏览、审核、播放和本地检索仍可使用。“问 Koe”会明确返回原文检索结果；语音转写和生成式整理需要配置云端服务。

## 数据与服务边界

- 签名安装版使用 macOS 沙盒，默认工作区为 `~/Library/Containers/com.anker.ankerRecorder/Data/Library/Application Support/KoeWorkspace`。记录、审核结果和问答历史保存在 `product-workspace.json`，音频单独保存在 `audio/`。
- 签名安装版将云端密钥保存在 macOS Keychain，模型和服务地址由 Rust 工作区持久保存。工作区与页面快照不含密钥；清除后不会恢复旧版值。地址留空可重置为默认值，地址不接受账户、密码、查询参数或片段。
- 开发构建、指定工作区或设置了 `KOE_CREDENTIAL_SOURCE` 的运行使用隔离凭据；密钥仅保留当前会话，默认开发工作区为 `KoeWorkspaceDevelopment`。不读取个人 `.env` 或 `.envrc`，不回退到系统凭据。签名安装升级后的真实读取仍待 [#603](https://github.com/semantic-craft/koe/issues/603) 验收。
- 发起云端任务前保存请求状态，收到结果并完成本地保存后才显示完成。应用重启会将未完成任务标为中断；重新配置服务后，由用户明确重试，不在后台自动重发付费请求。
- 工作区采用单写锁。同一资料库同时由一个 GUI、CLI 或 MCP 进程打开。关闭窗口会保留应用进程；使用 CLI 前请通过“退出 Koe”或 `⌘Q` 退出 GUI。

## 导入旧 Flutter 资料

在设置的“旧版资料迁移”中点击“选择旧版资料目录”，选择旧版 Documents 下的 `AnkerRecorder` 目录。Rust 校验后将基础录音、可见原文、说话人与现有纪要一次写入当前工作区，原目录不改写。WAV、`.opus` 中的 Ogg Opus 和设备裸 Opus 可恢复播放；其他音频原件保全并明确标为暂不可播放。

重复导入相同快照不增加记录，也不覆盖之后的编辑。已迁记录对应的旧库内容发生变化时拒绝覆盖；本轮不支持增量合并。整批读取上限为 256 MB，超过时明确拒绝并保留原库。

旧纪要标为“未验证来源”，不伪造新版引用。人工修订或失效时码的原文显示“无时码”。纪要历史、待采纳原文及项目、主题、待办等尚未还原的领域数据保全到 `legacy-imports/`，设置中的持久清单区分保全副本与仍在原目录的未知文件、归档录音。此入口不表示旧版资料已完整迁移。签名安装版导入、重启读回与播放仍待 [#598](https://github.com/semantic-craft/koe/issues/598) 验收。

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

CLI 与原生应用使用同一个 `KoeRuntime` 和本机工作区。退出 GUI 后可运行：

```bash
cargo run --package koe-cli -- status
cargo run --package koe-cli -- search "产品决定"
cargo run --package koe-cli -- ask "接下来要做什么"
cargo run --package koe-cli -- mcp-stdio
```

`--workspace <目录>` 指定其他资料库；`search` 和 `ask` 支持 `--record <ID>` 限定记录。MCP stdio 暴露 `search`、`get_record`、`ask` 三个工具，其中 `ask` 会保留问答历史。独立 CLI/MCP 进程使用隔离凭据，不读取 GUI 的系统密钥，当前使用本地来源检索。停止 MCP 进程后，GUI 才能重新打开同一工作区。

## 架构

| 层 | 目录 | 责任 |
| --- | --- | --- |
| 领域与协议 | [koe-engine](crates/koe-engine/)、[koe-opus](crates/koe-opus/) | `ProductWorkspace`、每条记录的聚合、审核与来源规则、检索、D3200 协议；独立的 libopus 安全封装 |
| 客户端服务 | [koe-client-base](crates/koe-client-base/)、[core](crates/koe-client-core/)、[providers](crates/koe-client-providers/)、[services](crates/koe-client-services/) | 文件锁与原子保存、资料格式、真实网络传输、音频导入和工作区存储 |
| 运行时与接口 | [koe-runtime](crates/koe-runtime/)、[koe-host-api](crates/koe-host-api/) | 协调设备、异步任务和持久化，生成版本 2 的快照与意图接口 |
| 原生宿主与 CLI | [apple-shared](platforms/apple-shared/)、[macos](platforms/macos/)、[koe-cli](crates/koe-cli/) | SwiftUI 页面、窗口、CoreBluetooth、文件选择与播放；共享运行时的命令行入口 |

架构约束与数据流见 [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)，后续范围见 [ROADMAP.md](ROADMAP.md)。iOS/Android 宿主、屏幕或麦克风采集、翻译、Google 同步、自动备份与 ACP 接入不属于当前已接通的 macOS 产品流程。

## 参考与致谢

D3200 协议建立在 [tacshi/Soundcore](https://github.com/tacshi/Soundcore) 的逆向成果上，协议记录见 [PROTOCOL.md](PROTOCOL.md)。架构与产品设计参考 [metasequoiaime/msime](https://github.com/metasequoiaime/msime) 的原生宿主分层、[BasedHardware/omi](https://github.com/BasedHardware/omi) 的个人记忆流程，以及 [screenpipe/screenpipe](https://github.com/screenpipe/screenpipe) 的时间记录组织。参考版本与检索约定见 [reference-code.md](docs/agents/reference-code.md)。

结构化纪要提示词还参考了 Meetily 与 Ownscribe，来源和许可记录见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。安全问题按 [SECURITY.md](SECURITY.md) 私下报告。

## 许可证

本仓库沿用**许可证待定、在确认上游授权前不公开发布**的约定。上游相关代码权利归原作者所有；在完成授权确认前仅供个人使用，不作二次分发。Cargo 包元数据中的许可字段不替代上游代码的授权确认。
