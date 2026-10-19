# 豆包（火山引擎）录音文件识别 API 核实笔记（工单 08 开工前置）

日期：2026-10-15（以下为当日官方文档口径；火山文案/端点随控制台改版变动较快，实现前建议再开一次引用页确认）。
**先分清两类**：豆包语音的"流式/实时"（双向流式 WebSocket、一句话识别）与"录音文件"（HTTP 异步/一次性提交音频文件）。spec 只要后者，本笔记只记录后者。

## 0. 结论速览

- 当前官方推荐的**录音文件识别标准版**（大模型，submit/query 两阶段）：`POST https://openspeech.bytedance.com/api/v3/auc/bigmodel/submit` + `POST …/api/v3/auc/bigmodel/query`。
- 推荐模型（资源 ID）：**`volc.seedasr.auc`（豆包录音文件识别 2.0，官方标注"推荐"）**；`volc.bigasr.auc` 是 1.0 旧版。请求体内 `model_name` 固定为 `"bigmodel"`（唯一合法值）——"模型名可配置"落到**资源 ID**维度而非 body model_name。
- 鉴权：v3 文件 API 走 **X-Api-\* 请求头**，不是 Bearer：新控制台 `X-Api-Key`（一个 API Key）；旧控制台 `X-Api-App-Key`（=APP ID）+ `X-Api-Access-Key`（=Access Token）。**没有 cluster 参数**（cluster 是旧 v1 API 的字段）。
- 关键坑：**标准版只收公网可下载的 `audio.url`，没有官方托管上传接口、不支持 base64**。支持直接上传本地音频（base64 `audio.data`）的是**极速版 flash**（一次性同步返回，≤2h/100MB，二进制建议 ≤20MB）。

## 1. 候选 API 全景（录音文件类）

| 版本 | 端点 | 模式 | 音频输入 | 资源 ID / model_name | 限制 |
| --- | --- | --- | --- | --- | --- |
| 标准版（当前主推） | `/api/v3/auc/bigmodel/submit` + `/api/v3/auc/bigmodel/query` | 异步 submit→query | 仅 `audio.url`（公网可下载） | `volc.seedasr.auc`（2.0，推荐）/ `volc.bigasr.auc`（1.0）；body `model_name: "bigmodel"` | 单文件 ≤512MB、≤5 小时；30 分钟窗口内提交总量默认 500 小时；结果服务端保留 24h |
| 极速版 flash | `/api/v3/auc/bigmodel/recognize/flash` | 同步一次返回 | `audio.url` **或 `audio.data`（base64，二选一）** | `volc.bigasr.auc_turbo`；body `model_name: "bigmodel"` | ≤2 小时；≤100MB；直传二进制/base64 官方建议 20MB 内（受出口带宽） |
| 旧 v1（历史文档） | `/api/v1/auc`… + query（cluster 体系，`Authorization: Bearer; {access_token}`） | 异步 | `audio.url` | cluster（如 `volcengine_auc_common`） | 已归入"历史文档"，不建议新接入 |

另有"闲时版"（`Largemodelrecordingfilerecognitionidleversion`，错误码与标准版几乎一致、无长度/大小限制码），非首选。

## 2. 鉴权细节（标准版/极速版共用，v3 头部制）

提交与查询共用同一组头（来源：任务提交 API 页 + 极速版页）：

```
X-Api-Key: {API Key}                    # 新控制台：API Key 管理里创建，仅需此一个
X-Api-Resource-Id: volc.seedasr.auc     # 或 volc.bigasr.auc / volc.bigasr.auc_turbo
X-Api-Request-Id: {随机 UUID}            # 客户端生成；即 task id，submit 与 query 复用
X-Api-Sequence: "-1"                    # 固定值（仅 submit 需要）
```

旧控制台凭证形态：`X-Api-App-Key: {APP ID}` + `X-Api-Access-Key: {Access Token}` 替代 `X-Api-Key`。
注：`Bearer; {token}`（注意是**分号**分隔）与 HMAC256 是 openspeech 上 v1/异步 TTS 等接口的鉴权风格（Authenticationmethod 页），**不要**照搬到 v3 AUC。
工单 09 的"三件套"映射建议：key = API Key（或旧控制台 App ID+Access Key 两字段）、服务地址 = `https://openspeech.bytedance.com`（可覆盖归一化）、模型 = 资源 ID（默认 `volc.bigasr.auc_turbo`，见 §6 推荐）。

## 3. 提交任务（标准版 submit）

`POST https://openspeech.bytedance.com/api/v3/auc/bigmodel/submit`，body：

```json
{
  "user":  { "uid": "388808087185088" },
  "audio": {
    "url": "http://xxx.com/obj/sample.mp3",
    "format": "mp3",          // wav/mp3/ogg/spx/amr/aac/m4a（按文档版本略有出入，以引用页为准）
    "codec": "raw",           // raw|opus，默认 raw
    "rate": 16000, "bits": 16, "channel": 1,
    "language": "zh-CN"       // 可选；空=中英+若干方言自动
  },
  "request": {
    "model_name": "bigmodel",          // 唯一合法值
    "enable_itn": true,                 // 默认 true
    "enable_punc": true,                // 默认 true
    "enable_speaker_info": false,       // 说话人分离，需 show_utterances=true；language 空或 zh-CN 才生效
    "show_utterances": false,           // 分句结果
    "enable_ddc": false, "enable_channel_split": false,
    "show_speech_rate": false, "show_volume": false,
    "enable_auto_lang": false, "enable_lid": false,
    "enable_emotion_detection": false, "enable_gender_detection": false,
    "vad_segment": false, "end_window_size": 800,   // 300–5000ms，建议 800–1000
    "ssd_version": "200",               // 200=非会议≤5说话人；300=长会议声纹
    "corpus": { "boosting_table_name": "...", "correct_table_name": "...", "context": "..." }
  },
  "callback": "http://xxx", "callback_data": "…"   // 可选回调
}
```

响应：body 空/极简；状态在响应头 `X-Api-Status-Code`（`"20000000"` 成功）、`X-Api-Message`（`"OK"`）、`X-Tt-Logid`（排障用）；任务 id = body `task_id`（与自带的 `X-Api-Request-Id` 一致）。任务一般 3 小时内完成。

## 4. 查询任务（标准版 query）

`POST https://docs… /api/v3/auc/bigmodel/query`，**请求体为空 JSON `{}`**，头：`X-Api-Key` / `X-Api-Resource-Id` / `X-Api-Request-Id: {task_id}`。
状态在响应头 `X-Api-Status-Code`：`20000000` 成功 / `20000001` 处理中 / `20000002` 排队中；`X-Api-Message != "OK"` 即失败。
成功 body：

```json
{
  "audio_info": { "duration": 6312 },
  "result": {
    "text": "刚刚还在想你怎么还不来找我聊天，你就来了。",
    "utterances": [
      { "additions": { "channel_id": "1", "speaker": "1" },
        "start_time": 480, "end_time": 5880,
        "text": "刚刚还在想你怎么还不来找我聊天，你就来了。",
        "words": [ { "text": "刚", "start_time": 480, "end_time": 600, "confidence": 0 } ] }
    ]
  }
}
```

`utterances[]` 仅当提交 `show_utterances=true` 且成功时返回；`additions.speaker` 为数字字符串（0..9，≤10 说话人）——可同构映射到 Qwen 的 `说话人 N：` 渲染（`renderQwenTranscript` 的句子/speaker 形状几乎一致）。`enable_punc` 默认开，中文直接可用。

## 5. 错误码（`X-Api-Status-Code`，错误码查询页）

| 码 | 含义 | 工单 08 中文映射建议 |
| --- | --- | --- |
| 20000000 | 成功 | — |
| 20000001 / 20000002 | 处理中 / 排队中 | 轮询继续（对应 SttFileStage.processing / queued） |
| 20000003 | 静音/未检测到人声 | 未识别到语音，可重试 |
| 45000001 | 请求参数无效/重复请求 | 参数错误 + X-Api-Message 裁剪 |
| 45000002 | 空音频 | 音频太短或无效，无法转写 |
| 45000131 | 提交总量超限（500h/30min） | 请求过多，请稍后重试 |
| 45000132 | 音频 >512MB | 音频超过大小限制 |
| 45000151 | 音频格式不正确 | 音频格式不支持 |
| 550xxxx | 服务内部错误 | 转写失败，请重试 |
| 55000031 | 服务器繁忙 | 服务繁忙，请稍后重试 |

鉴权失败的具体码未在错误码页单列（参数类 45000001 或 X-Api-Message 文本），实现时按"非 2000xxxx 前缀 + message 含 key/token 字样"归到"凭证无效，请在设置中更新"。

## 6. 推荐与理由（工单 08 选型）

**推荐默认：极速版 flash（`volc.bigasr.auc_turbo` + `audio.data` base64 直传）。**

理由：
1. 本地录音无公网 URL。标准版只收 `audio.url` 且**官方无托管上传接口**，走标准版必须让用户自备对象存储（TOS/OSS 预签名上传，见下）——与"填个 token 就能用"的私人工具定位冲突，且需要额外一套存储凭证。
2. flash 是唯一支持直接上传音频内容的录音文件 API（`audio.url 与 audio.data 二选一`，官方 demo 有 `file_to_base64`）；"上传→提交→取回"三段式中"上传"即 flash 请求本身，"提交/轮询"退化为单次同步调用——服务层仍可保留与 Qwen 同形的 `transcribePath` 外观（内部无轮询循环），离线测试接缝完全一致。
3. 限制可接受：≤2 小时（超过才需标准版）、≤100MB 硬限、直传建议 ≤20MB。App 录音为 Opus/Ogg，小时级录音远小于 100MB，但 base64 有 +33% 体积放大，**实现要加"超过 20MB 提示走 URL/标准版"的前置校验**（对应 Qwen 的 maxUploadBytes 检查）。
4. 说话人分离：flash 支持 `enable_speaker_info`（demo 参数含此项），分句 words 时间戳也返回。

**升级路径（做成配置而非默认）**：标准版 `volc.seedasr.auc` submit/query（真轮询、≤5h、支持 ssd_version 300 长会议声纹），音频 URL 由用户自备 TOS（官方文档：PostObject 上传 https://www.volcengine.com/docs/6349/129228、STS 临时凭证 127695）。"模型名可配置"字段即资源 ID（`volc.bigasr.auc_turbo` / `volc.bigasr.auc` / `volc.seedasr.auc`），body `model_name` 恒为 `"bigmodel"`——校验层可对未知资源 ID 放行、对把 body model_name 填成资源 ID 之类的混用给可读拒绝（工单 08 验收"不兼容所选模型的调用被显式拒绝"）。
**语言参数**：火山用 BCP-47 风格（`zh-CN`/`en-US`/`yue-CN`…约 26 种），App 现有 `transcriptLanguage` 是 ISO 短码（`zh`/`en`/`auto`）——需要 `zh→zh-CN` 映射，`auto` 对应 flash 的 `enable_auto_lang` 或不传 language。

## 7. 引用来源（2026-10-15 抓取）

- 标准版-任务提交：https://docs.volcengine.com/docs/DoubaoVoice/task-submission-http-1
- 标准版-结果查询：https://docs.volcengine.com/docs/DoubaoVoice/result-query-http-1
- 标准版-概览（v1 历史端点、512MB/5h、24h 保留）：https://docs.volcengine.com/docs/DoubaoVoice/AudioFileRecognitionStandardEdition
- 标准版 HTTP（旧控制台 X-Api-App-Key/Access-Key、错误码表）：https://docs.volcengine.com/docs/DoubaoVoice/LargemodelrecordingfilerecognitionstandardversionAPI
- 极速版（flash、audio.data base64、20MB 建议）：https://docs.volcengine.com/docs/DoubaoVoice/LargemodelrecordingfileLiterecognitionAPI
- 错误码查询：https://docs.volcengine.com/docs/DoubaoVoice/error-code-query
- 鉴权方法（Bearer;/HMAC256，v1/异步 TTS 体系）：https://docs.volcengine.com/docs/DoubaoVoice/Authenticationmethod
- 产品页：https://www.volcengine.com/product/asr
- 社区实践（Seed-ASR 2.0 转写调用样例）：https://github.com/vahnxu/doubao-asr
