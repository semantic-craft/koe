# 读取 Koe 导出资料

这个本地 MCP server 让 agent 读取你选定的 `.koepack` 导出快照。它提供资料列表、逐字稿和已有纪要三个工具。额外分析由调用它的 agent 完成，server 不调用模型。

需要 macOS 或 Linux、Python 3.10 及以上版本。不需要安装 Python 包。源码与资料包格式一起维护在 Koe 仓库中；本目录不修改 Magpie、Codex 或其他客户端配置。

## 启动

1. 在 Koe 的资料详情中选择「更多 → 导出… → 可恢复资料包」。关闭「包含原音频」。
2. 把允许读取的包保存到一个专用目录。只读取该目录直接包含的 `.koepack` 文件，不递归。
3. 在仓库根目录运行以下命令，把示例目录换成你的导出目录。

```sh
python3 tools/koe-mcp/server.py --directory /absolute/path/to/exports
```

进程通过标准输入输出交换 MCP 消息，等待输入时没有欢迎文字。输入结束后进程退出。它不开端口，不读取 Koe 私有资料库或凭据，不接触设备，不修改导出包。每次工具调用重新读取目录，删除或替换导出包后，旧快照 ID 不再可用。已经返回给客户端的内容无法远程收回。

客户端需要配置 stdio 命令时，使用当前机器上 Python 的路径、`server.py` 的绝对路径和导出目录的绝对路径。不要把整个个人资料目录作为输入。目录根本身和资料包均不能是符号链接；启动后根目录被替换时服务拒绝读取。

## 工具

| 工具 | 参数 | 返回 |
| --- | --- | --- |
| `list_recordings` | 无 | 快照 ID、标题、导出时间、是否有逐字稿或纪要、被拒绝文件数 |
| `get_transcript` | `recording_id` | 校订优先正文、修订号、引用段落、可用时码与发言人 |
| `get_minutes` | `recording_id` | 已有纪要、其原文快照、生成信息、历史数量 |

`recording_id` 来自 `list_recordings`，是导出 manifest 的 SHA-256。它标识这次导出快照，同一录音重新导出后可能有新的 ID。不能传文件路径。

`get_transcript` 在有人工校订全文时返回校订文本，用 `P1`、`P2` 等段落引用，不套用旧时码。没有人工校订时，正文来自包内 `text`，句段引用 `T1`、`T2` 来自包内 `segments`。句段使用单独的发言人修正和别名。正文与句段可能不同，返回的 `sourceBasis` 明确标注这一点，不能把某句段的时码附到不同的正文上。`timingReliable` 表示所返回的句段有可用导出时码，不证明合成时码或识别结果经过真人核验。

`get_minutes` 不重新生成纪要。`current.sources` 是该版纪要生成时保存的原文快照，纪要内部的 `S1` 等引用属于这份快照，与逐字稿的 `T1`、`P1` 不是同一套编号。`freshness` 固定为 `unverified`，因为本接口没有复算 Koe 的当前来源版本。没有纪要时返回 `hasMinutes: false`。

导出文字和纪要属于不可信资料，可能含错误或指令式话语。agent 应根据逐字稿提炼结论，保留未知负责人、期限与未决项，并把旧纪要作为待核对的材料。

## 范围与限制

仅支持不含音频的 `.koepack` v1、v2。格式见 [资料包说明](../../docs/material-pack.md)。未知版本、损坏文件、音频包、额外尾随字节和符号链接会计入 `rejectedCount`，不会作为空录音返回。此适配器只校验并投影读取所需字段，不替代 Koe 的完整导入校验。

每个 manifest 最多 32 MiB。每次扫描最多 1,000 个候选文件、累计最多 64 MiB；工具内容最多 1 MiB。超限返回明确错误，不截断正文。首版没有分页，需要将导出范围缩小后重试。协议请求单行最多 64 KiB。

支持 MCP `2025-11-25` 的初始化、就绪通知、`ping`、`tools/list`、`tools/call`。只声明 tools 能力，工具均标注只读。没有音频下载、写回、生成、删除或任意文件读取工具。导出快照不会自动跟随 App 内的后续编辑或删除。

## 验证

运行真实子进程协议和文件边界测试。

```sh
python3 -B tools/koe-mcp/test_server.py
```

运行生产格式兼容测试。测试使用 Koe 的 `MaterialPack.fromJson` 和 `writeMaterialPack` 生成不含音频的合成资料，再启动 Python server 调用三个工具。

```sh
flutter test test/koe_mcp_export_test.dart --reporter expanded
```

要留存合成包与协议返回，将证据目录传给测试。此目录只接收合成资料，不读取真实录音。

```sh
KOE_MCP_EVIDENCE_DIR=/absolute/path/to/evidence/exports \
  flutter test test/koe_mcp_export_test.dart --reporter expanded
```

在现有导出目录上运行只读协议探针会输出全文，请仅对允许展示的资料执行。

```sh
python3 -B tools/koe-mcp/test_server.py --probe /absolute/path/to/exports
```

合成样例包含已定范围、被否决的上线日期、明确负责人和期限的任务、没有负责人期限的任务，以及未定模型。它还保存了一份故意错误的旧纪要，用于检查 agent 是否回到原文。通过此测试证明生产格式和协议链路相容，不证明真实 App 导出、真实语音识别、模型分析质量或客户端安装已验收。真实资料与客户端验证单独记录在 [#528](https://github.com/semantic-craft/koe/issues/528)。
