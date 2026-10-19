# Koe 资料包格式（`.koepack`）

资料详情「更多 → 导出…」生成，「新记录 → 导入资料包」恢复（#145）。一个包只装一条资料。代码在 [lib/state/material_pack.dart](../lib/state/material_pack.dart)（格式、读写、校验）和 [lib/state/recorder/material_pack.dart](../lib/state/recorder/material_pack.dart)（导出内容、导入去重与合并）。

## 两种导出

| | 阅读稿（`.md`） | 可恢复资料包（`.koepack`） |
| --- | --- | --- |
| 给谁 | 人读、粘贴到别处 | 另一台设备、重装后的 Koe |
| 内容 | 标题、时间、地点、主题、带时码和发言人姓名的正文、书签 | 下文全部字段 |
| 原音频 | 从不包含 | 用户打开「包含原音频」才包含，默认不含 |
| 能否导入 | 不能 | 能 |

## 文件结构

```
KOEPACK1\n
<说明的字节数，十进制>\n
<说明：UTF-8 JSON>
<原音频的原始字节，仅在 audio.included = true 时存在>
```

不压缩、不分块；原音频按原件字节原样放在说明之后，导出和导入都按块流式读写，不把整段音频读进内存。导出先写 `<名字>.koepack.part`，写完才改名，取消或失败时删除，不会留下看似完成的文件。

## 说明（manifest）字段

```jsonc
{
  "format": "koe-material-pack",
  "version": 1,
  "exportedAt": "2026-10-19T10:00:00.000",
  "material": {
    "contentHash": "<原音频 SHA-256，64 位小写十六进制>", // 资料身份
    "title": "周会",
    "source": "device | localImport | phone",
    "deviceFileId": 1792377669,        // 只有录音豆录音有
    "recordedAt": "2026-10-12T09:30:00.000",
    "place": {"label": "杭州市西湖区", "source": "manual", "capturedAt": "…"},
    "audioExtension": ".wav"
  },
  "transcript": {
    "text": "<转写服务原文>",
    "manual": "<用户校订后的正文，没改过就没有>",
    "segments": [{"text": "…", "startMs": 0, "endMs": 4000, "speaker": "1"}],
    "segmentSpeakers": {"2": "2"},     // 片段序号 → 改正后的发言人
    "speakerAliases": {"1": "王老师"}, // 发言人 → 用户起的名字
    "provider": "qwen", "sourceLanguage": "zh", "revision": 2,
    "translation": { /* 与 transcripts.json 中的译文同构 */ }
  },
  "bookmarks": [ /* RecordingBookmark 去掉 recordingKey */ ],
  "topic": {"title": "年度预算", "kind": "general"},
  "audio": {"included": true, "extension": ".wav", "bytes": 8044, "sha256": "<同 contentHash>"}
  // 或 "audio": {"included": false}
}
```

**刻意不写入：** 任何文件路径（本机或原导入来源的 `originalPath`）、本机 recording key（`path:…` / `file:…`）、API Key、录音豆配对或加密信息、Mac 归档配对。重装后容器路径会变（PR #239），所以资料身份只用内容摘要和录音豆文件号。

## 导入规则

1. **校验先于写入。** 魔数、说明长度、JSON、必填字段、原音频字节数和 SHA-256 任何一项不符，都直接报「资料包已损坏 / 不完整：…」，资料库、文件和书签都不改动。来自更高版本格式的包提示先更新 App。
2. **找同一份资料：** 先按 `deviceFileId` 找本机的录音豆录音，再按 `contentHash` 找资料库原件。都没有且包里有原音频时，走普通的「导入本地音频」保存原件（同内容复用、不记录来源路径），再恢复其余内容。
3. **只补缺，不覆盖：**
   - 本机没有正文：恢复原文、校订、片段时码、发言人改正、发言人姓名、译文。
   - 本机正文与包相同：只补本机没有的发言人姓名和译文。
   - 本机正文不同（同身份不同手改版本）：本机正文不动，包里的正文放进「待比较版本」，详情页提示「导入的资料包带来另一个版本的正文」，用户自己选择采用或保留。
   - 书签：位置、备注、原句都相同的跳过；id 已被占用的换新 id，不替换本机书签。
   - 地点：本机没有才补。主题：本机未归类（或待归类）时放进同名主题，没有同名主题就新建。
4. **重复导入：** 第二次导入同一个包什么都不新增，提示「这份资料已在资料库中，未重复导入」。导入不排队转写或整理任务。
5. **包里没有原音频、本机也没有这条资料：** 作为文字资料导入（资料 → 文字资料），注明缺原音频和书签回听；正文与时码可读。「补配原音频」时必须是同一份原音频（SHA-256 一致），配上后按第 3 条完整恢复到这条录音，文字资料记录随之移除。再次导入同一个包不会再建第二条文字资料。

## 版本演进

新增可选字段不升 `version`；改变既有字段含义或文件结构时升版本，旧 App 遇到更高版本会拒绝导入而不是猜。
