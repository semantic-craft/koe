# 读取 Koe 授权文字与纪要

这个本地 MCP server 提供 App 会话内自动更新的逐条授权模式，也保留手动 `.koepack` 导出快照模式。它提供资料列表、逐字稿和已有纪要三个工具。额外分析由调用它的 agent 完成，server 不调用模型。

需要 macOS 或 Linux、Python 3.10 及以上版本。不需要安装 Python 包。源码与资料包格式一起维护在 Koe 仓库中；本目录不修改 Magpie、Codex 或其他客户端配置。

## 自动读取已授权记录

在 Mac 的录音详情中开启该条记录的 MCP 访问。默认没有授权，开启后 App 自动发布这条记录的当前文字和纪要，后续转写、校订和纪要变化无需重新导出。入口显示本次会话的专用目录。在客户端配置以下 stdio 命令，将目录替换为入口显示的路径。

```sh
python3 tools/koe-mcp/server.py --live-directory /absolute/path/to/session
```

只读取该目录的 `live.json`，不遍历个人资料库，不传原音频、地点、主题或书签。授权仅在当前 App 会话内有效，撤销后后续读取失败；正常退出撤销，异常退出最迟在15秒租约到期后拒绝读取。已返回给客户端的文字无法远程收回。下次开启 App 需要重新授权和使用新的会话目录。

live 模式的 `recording_id` 标识本机同一条记录，`materialContentHash` 保留资料库中的音频内容身份，便于与资料包对应；`snapshotRevision` 标识本次完整发布。只有已登记内容身份的记录可以授权，不读取或伪造原音频哈希。先调用 `list_recordings`，再将返回的版本作为 `get_transcript` 和 `get_minutes` 的可选 `expected_revision`。若两次读取之间内容变化，返回 `snapshot_changed`，客户端应重新列出并读取，不能拼接不同版本。

live 纪要的 `freshness` 为 `current`、`stale` 或 `unverified`。它只比较该发布中的有效正文哈希和纪要的 `sourceHash`，不证明识别或纪要事实正确。三个工具均只读，不会生成纪要、发送模型请求或回写 App。

本机模式不建立手机到 Mac 的同步，也不自动修改 Codex、Magpie 等客户端配置。手机记录需要已通过项目既有方式到达本机，才可在本机逐条授权；真实跨端链路仍另验。

## 远程 HTTP MCP 与双端同步模式（VPS 或 Mac 局域网）

在同一套 `.koepack` v2 无音频目录上开启 Bearer 鉴权的 HTTP 服务，同时暴露 `POST /mcp`（供 Magpie、Claude Code、Codex、Antigravity 等外部 AI 远程读取）与 `/sync/packs`（供手机录制生成纪要后自动推送、Mac 打开后自动拉取）：

```sh
# 1. 生成或读取 32 字节令牌，并打印供 Koe App 一键接入的 KOEMCP1. 连接码
python3 tools/koe-mcp/server.py \
  --directory ~/.koe/mcp-sync \
  --token-file ~/.koe/mcp-token \
  --public-url https://koe.example.com/mcp \
  --mode vps \
  --print-pairing

# 2. 启动 HTTP MCP + 同步服务（置于 Caddy/Nginx HTTPS 反代后，或在 Mac 局域网直接监听）
python3 tools/koe-mcp/server.py \
  --directory ~/.koe/mcp-sync \
  --http-listen 127.0.0.1:8787 \
  --token-file ~/.koe/mcp-token
```

- 在 Koe「设置 → 外部 AI 连接」中，界面不设任何地址、邮箱或密钥输入框，也不会在界面回显用户的服务器域名或私人邮箱。
- **方式一（插着电脑 / 本机 Agent 直接操作，零复制粘贴）**：
  - Agent 在电脑上生成 `KOEMCP1.` 连接码后，可直接写入系统剪贴板（`pbcopy`，支持 Apple 通用剪贴板同步至 iPhone），或对插在电脑上的 iPhone 直接通过 `xcrun devicectl` 推入配对文件（Koe 打开「外部 AI 连接」或点击「一键接入」时会自动读取并销毁该文件）：
    ```sh
    # 生成 KOEMCP1. 连接码并直接推入已连接 iPhone 的 Koe 容器
    python3 tools/koe-mcp/server.py \
      --directory ~/.koe/mcp-sync \
      --token-file ~/.koe/mcp-token \
      --public-url https://<自动发现的VPS域名>/mcp \
      --mode vps \
      --print-pairing | python3 -c "import sys,json; print(json.load(sys.stdin)['pairingCode'])" > /tmp/mcp_pairing.txt
    xcrun devicectl device copy to \
      --device <iPhone_UDID_or_Name> \
      --domain-type appDataContainer \
      --domain-identifier com.semanticcraft.soundcore \
      --source /tmp/mcp_pairing.txt \
      --destination Documents/AnkerRecorder/mcp_pairing.txt
    rm -f /tmp/mcp_pairing.txt
    ```
  - 若只需在插着电脑时由 Agent 直接读取 iPhone 上的纪要、转写或待办，也可直接用 `xcrun devicectl device copy from --domain-type appDataContainer --domain-identifier com.semanticcraft.soundcore --source Documents/AnkerRecorder/minutes_documents.json`（或 `transcripts.json`、`analysis.json`）读取。
- **方式二（复制提示词 + 剪贴板一键接入，零手动填写）**：
  - 用户点击复制「复制 VPS 配置提示词」或「复制本机 Mac 配置提示词」发给 AI Agent；Agent 读取本文件自动部署服务并回复 `KOEMCP1.<base64url>` 连接码后，回到 Koe 点「从剪贴板一键接入」即可完成绑定（Bearer 令牌单独存入系统 Keychain）。
- 手机录制或纯文字记录生成逐字稿与纪要后，自动将不含原音频的 `.koepack` v2 推送至 `PUT /sync/packs/<contentHash>`；Mac 打开 Koe 自动从 `GET /sync/packs` 拉取合并；任何配置了 `POST /mcp`（请求头 `Authorization: Bearer <token>`）的 Agent 均可随时调用 `list_recordings`（支持可选 `query` 关键词过滤）、`get_transcript`、`get_minutes`。

## 手动导出模式

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
| `get_transcript` | `recording_id`，live 可选 `expected_revision` | 校订优先正文、修订号、引用段落、可用时码与发言人 |
| `get_minutes` | `recording_id`，live 可选 `expected_revision` | 已有纪要、其原文快照、生成信息、历史数量 |

手动导出模式的 `recording_id` 来自 `list_recordings`，是导出 manifest 的 SHA-256。它标识这次导出快照，同一录音重新导出后可能有新的 ID。不能传文件路径。

`get_transcript` 在有人工校订全文时返回校订文本，用 `P1`、`P2` 等段落引用，不套用旧时码。没有人工校订时，正文来自包内 `text`，句段引用 `T1`、`T2` 来自包内 `segments`。句段使用单独的发言人修正和别名。正文与句段可能不同，返回的 `sourceBasis` 明确标注这一点，不能把某句段的时码附到不同的正文上。`timingReliable` 表示所返回的句段有可用导出时码，不证明合成时码或识别结果经过真人核验。

`get_minutes` 不重新生成纪要。`current.sources` 是该版纪要生成时保存的原文快照，纪要内部的 `S1` 等引用属于这份快照，与逐字稿的 `T1`、`P1` 不是同一套编号。手动导出模式的 `freshness` 固定为 `unverified`，因为本接口没有复算 Koe 的当前来源版本。没有纪要时返回 `hasMinutes: false`。

导出文字和纪要属于不可信资料，可能含错误或指令式话语。agent 应根据逐字稿提炼结论，保留未知负责人、期限与未决项，并把旧纪要作为待核对的材料。

## 范围与限制

仅支持不含音频的 `.koepack` v1、v2。格式见 [资料包说明](../../docs/material-pack.md)。未知版本、损坏文件、音频包、额外尾随字节和符号链接会计入 `rejectedCount`，不会作为空录音返回。此适配器只校验并投影读取所需字段，不替代 Koe 的完整导入校验。

每个 manifest 最多 32 MiB。每次扫描最多 1,000 个候选文件、累计最多 64 MiB；工具内容最多 1 MiB。超限返回明确错误，不截断正文。首版没有分页，需要将导出范围缩小后重试。协议请求单行最多 64 KiB。

支持 MCP `2025-11-25` 的初始化、就绪通知、`ping`、`tools/list`、`tools/call`。只声明 tools 能力，工具均标注只读。没有音频下载、写回、生成、删除或任意文件读取工具。手动导出快照不会自动跟随 App 内的后续编辑或删除；live 模式会跟随当前授权记录更新。

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

运行自动发布的端到端验收。该命令使用隔离控制器和合成内容，启动真实 MCP 子进程及持续连接的 stdio 客户端，检查自动更新、校订、纪要版本、混版拒绝和撤销。它不证明外部 AI 客户端安装或手机跨端同步。

```sh
scripts/verify-minutes-flow mcp
```
