# 参考代码检索（XERJ）

写 BLE、录音、音频编解码、后台播放或「录音 + 记忆 + 待办」类功能前，先用本机 XERJ 检索同类项目和锁定版本依赖的实现，引用 `路径:行号` 后再写代码。检索不到相关内容就说明，然后照常工作。

## 什么时候用

- **用**：录音豆 D3200 BLE 协议、Omi 穿戴设备断线 WAL（`PendantRingCustody`）、TaoSheng 全天候语音记忆与五栏信息架构（日历查表、寻物共乘、`AskEngine` 多轮工具检索与 `[^n]` 引用自愈、CAM++ 声纹识别）、Vecta 扫描线说话人对齐、Cicada 原地润色与 `msime` 四层 Rust FFI 桥接。
- **不用**：Rust / Swift 标准库与常见 API。对模型记得住的公开代码，检索只增加成本（XERJ 的研究里这一类检索反而更差）。

## 命令

```bash
scripts/ref search "reconnect after disconnect restore state" -k 5   # 参考项目
scripts/ref def "AskEngine"                                           # 参考项目里的定义位置
scripts/ref self "PendantRingCustody"                                 # Koe 自身
scripts/ref status                                                    # 节点与索引条数
```

节点没起会自动起（`127.0.0.1:9200`，仅本机、无认证）。默认嵌入是词法（BM25 + 子词重叠），不是语义模型：用代码里会出现的词，不用意译。

## 语料（在 `scripts/ref` 顶部维护）

| 名称 | 内容 | 版本 | 许可 |
| --- | --- | --- | --- |
| `repos/soundcore-upstream` | 上游 tacshi/Soundcore，D3200 协议参考 | 固定 commit `0e100df287ef` | MIT，Copyright (c) 2026 Rocky Shi；正文见 `assets/licenses/soundcore.txt`，移植时保留署名与许可 |
| `repos/omi` | `BasedHardware/omi`（穿戴设备 BLE/WAL、双端导航壳、`knowledge_ledger.v1`、Review 确认卡、Agent/MCP） | 固定 commit `82357c8224ef` | MIT |
| `repos/screenpipe` | `screenpipe/screenpipe`（24/7 本地音画捕获、UTC 时间戳 `BTreeMap` 多模态时间轴、`SubtitleBar`、`pipe.md` 技能） | 固定 commit `2eee9acea418` | MIT |
| `repos/taosheng` | `0xCoach/TaoSheng`（全天候随身语音记忆、21 天日历消歧、寻物共乘、Ask 引用自愈、CAM++ 声纹） | 固定 commit `23907c464158` | 仅架构与交互参考，Rust/SwiftUI 独立实现 |
| `repos/msime` | `metasequoiaime/msime`（纯 Rust 内核 + 全原生 Apple 宿主四层架构） | `main` | MIT / Apache-2.0 |
| `repos/vecta` | `nitishagar/vecta`（扫描线说话人对齐与 20s 断点队列参考） | 固定 commit `5e0c02804731` | MIT |
| `repos/cicada` | `tpn/cicada`（单遍润色与 12 话题预算参考） | 固定 commit `e427a8bc8cb9` | MIT |

默认只借思路自己写。确要照抄 MIT 代码时，在文件头和 [THIRD_PARTY_NOTICES](../../THIRD_PARTY_NOTICES.md) 注明出处。

升级参考仓库 commit 后运行 `scripts/ref sync`；main 有较多新提交后运行 `scripts/ref koe` 刷新自身索引（固定索引主工作区，worktree 里的未合并改动不在其中）。新增语料：在 `REPOS` 里加一行；稀疏路径要写，避免把整仓资产拉下来。

## 放在哪里

都在 `~/Projects` 之外，不进 Git 和 Syncthing，删了可以用 `scripts/ref sync` 重建：

- `~/.cache/xerj-ref/koe/`：克隆和依赖副本（2026-10-19 约 117 MB）。
- `~/.local/share/xerj/`：节点数据、索引日志、`node.pid`、`node.log`（约 280 MB；参考语料约 6.5 万条，首次索引约 12 分钟，节点内存约 2 GB）。
- `xerj` 本体：`~/.local/bin/xerj`（安装：`curl -fsSL https://xerj.org/get | sh`，安装脚本会校验 SHA-256）。

节点内存随索引条数增长；不用时 `scripts/ref stop`，重启后索引还在。只停 `scripts/ref` 起的节点，不 `pkill xerj`。

这些文件不会自动清除。要全部删掉，运行 `scripts/ref clean`：它会停掉节点，删除上面两个目录，保留 `xerj` 本体。之后需要时再运行 `scripts/ref sync` 重建。
