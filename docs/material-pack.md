# Koe 资料包格式（`.koepack`）

当前原生宿主通过文件导入读取不含原音频的 `.koepack`。一个包描述一条资料。代码在 [koepack.rs](../crates/koe-engine/src/koepack.rs)（纯字节解码与格式校验）及 [recording_assets.rs](../crates/koe-client-services/src/recording_assets.rs)（导入为工作区记录）。

## 阅读稿与资料包

| | 阅读稿（`.md`） | 资料包（`.koepack`） |
| --- | --- | --- |
| 当前用途 | 导出标准 Markdown 供阅读、分享，也可作为纯文字导入 | 导入现有无音频的包 |
| 导入内容 | 按非空行保存文字 | 资料标题、当前纪要的来源原文与结构化纪要 |
| 原音频 | 无 | 原生解码器拒绝含原音频的包 |

## 文件结构

```text
KOEPACK1\n
<说明的 UTF-8 字节数，十进制>\n
<说明：UTF-8 JSON>
```

说明长度为 1 字节至 32 MiB。可读取以 LF 或 CRLF 结尾的帧头。说明之后必须立即到达文件末尾，任何尾随字节均拒绝。

## 说明（manifest）字段

| 字段 | 当前读取规则 |
| --- | --- |
| `format` | 固定为 `koe-material-pack` |
| `version` | 整数 1 或 2。版本 1 不能带 `minutes` 字段 |
| `exportedAt` | 非空时间字符串 |
| `material` | 需要非空 `title` 与 64 位十六进制 `contentHash`；可读录音豆文件号、来源、录制时间与旧音频扩展名 |
| `audio` | 需要对象，`included: true` 会被拒绝。无音频包写 `{"included": false}` |
| `minutes` | 版本 2 可携带 `current` 与最多 10 项 `history`；格式及证据引用均须通过校验 |

## 导入规则

1. 选择的文件最多 256 MiB。原生宿主把字节交给 Rust，由 `decode_koepack` 只读解析。校验与导入准备成功后，由工作区事务提交记录。
2. 以整个输入文件的 SHA-256 生成稳定导入 ID，重复导入时复用同一记录。包中的 `contentHash` 作为格式中的资料标识校验，写入身份由实际输入字节派生。
3. 导入使用 `minutes.current.sources` 建立无时码的原文分段，再验证结构化纪要。缺少可用文字的包无法生成记录。音频路径、旧转写字段、书签与历史纪要均不写进工作区。

## 纪要白名单与版本演进

纪要解码读取 `text`、`sourceHash`、`model`、`instruction`、`sources`、`createdAt`、可选 `editedAt` / `templateId`，以及 `templateVersion`、`isDraft`。当前纪要和历史都校验结构及来源，提交时导入当前版本。纯解码无文件或网络 I/O。旧版带音频导出、跨库合并、历史恢复与补配原件的说明保留在 git 历史 `03b58d0:docs/material-pack.md`。
