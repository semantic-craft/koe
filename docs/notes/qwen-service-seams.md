# Qwen 文件转写服务的接缝（供工单 08 豆包服务同构实现参考）

日期：2026-10-15。基线：`codex/warm-recording-workspace`（ede579e），文件内容与 `feat/qwen-asr`（eebad33）引入版一致。
主文件：`lib/ai/qwen_stt.dart`（约 780 行）；测试：`test/qwen_stt_test.dart`（305 行）。
读法提醒：主 checkout 工作区正被并行修改，核对行号请用 `git show ede579e:lib/ai/qwen_stt.dart`。

## 1. 构造器注入 HTTP client

`lib/ai/qwen_stt.dart:42-48`：

```dart
class QwenSttService {
  QwenSttService({
    http.Client? client,
    this.pollInterval = const Duration(seconds: 2),
    this.taskTimeout = const Duration(minutes: 15),
  }) : _client = client ?? http.Client();

  final http.Client _client;
```

- 唯一可注入依赖是 `package:http` 的 `http.Client`；`pollInterval` 可注入 `Duration.zero` 让测试跳过轮询等待。
- 运行期配置走**公开可变字段**（不是构造参数），由控制器在加载设置时回填（`qwen_stt.dart:62-64`）：

```dart
String? apiKeyOverride;
String? baseUrlOverride;
String? modelOverride;
```

- 解析顺序（`qwen_stt.dart:66-85`）：key = override → `DASHSCOPE_API_KEY` 环境变量 → null；baseUrl = override → `DASHSCOPE_HTTP_BASE_URL` → 默认；model = override → `defaultModel`。`isConfigured => apiKey != null`（:86）。
- 常量（`:53-59`）：`defaultBaseUrl = 'https://dashscope.aliyuncs.com'`、`intlBaseUrl`、`defaultModel = 'qwen-audio-3.1-asr-flash-filetrans'`、`incompatibleFileUrlModel = 'qwen3-asr-flash-filetrans'`、`maxUploadBytes = 1GB`。

## 2. 三段式流程与各步请求形状

入口 `transcribePath(path, {apiKey, baseUrl, model, language, onProgress, isCurrent})`（`:88-116`）→ `_transcribe`（`:118-204`）。每次调用可**逐参覆盖**服务级 override（控制器把录音时的配置快照传进来，见 engine-enum-settings.md 第 4 节）。

阶段进度用 `SttFileStage { preparing, uploading, queued, processing, fetching }`（`lib/ai/stt_types.dart:56` 附近）经 `onProgress(SttFileProgress)` 上报；`isCurrent()` 回调在每步之间被检查，返回 false 即抛"处理已取消，可重试"（`_ensureCurrent`，`:434-438`）。

### 2.1 前置校验（`_transcribe` :118-158）

- 缺 key → `QwenSttException('请在设置中配置通义 Qwen')`。
- 显式模型拒绝：`resolvedModel == incompatibleFileUrlModel` → `'qwen3-asr-flash-filetrans 使用 input.file_url，请改用 qwen-audio-3.1-asr-flash-filetrans'`（`:139-146`）。豆包对应做"不兼容所选模型的调用被显式拒绝"（工单 08 验收项）。
- 本地音频规整 `OggOpus.ensurePlayable(path)`；<64 字节 → `'音频太短或无效，无法转写'`；>1GB → `'音频超过 1 GB，无法上传'`。

### 2.2 上传（`_upload` :207-241 / `_policy` :243-261 / `_postToOss` :263-304）

1. `GET {origin}/api/v1/uploads?action=getPolicy&model={model}`，headers `Authorization: Bearer {key}` + `Content-Type: application/json`，30s 超时；响应经纯函数 `parseQwenUploadPolicy` 解析（policy/signature/upload_dir/upload_host/oss_access_key_id/x_oss_object_acl/x_oss_forbid_overwrite/max_file_size_mb）。
2. multipart `POST {policy.upload_host}`，fields：OSSAccessKeyId/Signature/policy/x-oss-object-acl/x-oss-forbid-overwrite/key=`{uploadDir}/{filename}`/success_action_status=200，file 字段用 `lib/ai/progress_multipart.dart` 的 `multipartFileWithProgress`（256KB 分块流，边发边报 uploadedBytes）。返回 `oss://{key}`。
3. 403 + body 含 'Policy expired' → 抛内部 `QwenPolicyExpired`，`_upload` 捕获后**重取 policy 再传一次**。OSS 失败 → `'通义音频上传失败，请重试'`。

### 2.3 提交任务（`_submit` :306-339）

```
POST {origin}/api/v1/services/audio/asr/transcription
Authorization: Bearer {key}
Content-Type: application/json
X-DashScope-Async: enable
X-DashScope-OssResourceResolve: enable     # oss:// URL 需要
body: qwenTranscriptionBody(model:, fileUrl:, language:)
```

请求体由**顶层纯函数**构造（`:568-588`）：

```dart
{
  'model': model,
  'input': {'file_urls': [fileUrl]},   // 复数；parameters 必须存在
  'parameters': {'channel_id': [0],
                 if (qwenDiarizationEnabled(model)) 'diarization_enabled': true,
                 if (hints != null) 'language_hints': hints},
}
```

响应取 `output.task_id`，为空 → `'通义未返回转写任务'`。

### 2.4 轮询（`_wait` :341-389）

`GET {origin}/api/v1/tasks/{urlencoded task_id}`（Bearer），循环 `parseQwenTask`：`SUCCEEDED` 且有 transcription_urls → 返回；`PENDING/RUNNING` → 上报 queued/processing 进度并 `await Future.delayed(pollInterval)`；其他状态或 SUCCEEDED 无结果 → `'通义转写失败：{failureMessage 裁剪}'`；超 deadline（taskTimeout 15min）→ `'通义转写超时，请稍后重试'`。

### 2.5 取回文稿（`_fetchTranscript` :391-400 + `_transcribe` :188-199）

校验 transcription_url 是 https 后 GET，逐份用纯函数 `renderQwenTranscript` 渲染段文本、`qwenDurationSec` 取时长，最后合成 `SttResult(text: normalizeSttText(parts.join('\n')), language: …, durationSec: …)`。`SttResult` 定义在 `lib/ai/stt_types.dart`（text/durationSec/language/sourcePath 四字段）。

## 3. 服务地址归一化（豆包照抄规则形态）

`resolveDashScopeBaseUrl(configured, {environment})`（`:590-597`）+ `normalizeDashScopeBaseUrl(raw)`（`:599-615`）：

- 空值链：configured → env → defaultBaseUrl。
- 规则：trim → 无 `://` 则补 `https://` → 去尾部 `/` → 剥掉已带的 `/api/v1` 后缀 → `Uri.tryParse` 校验 `scheme == 'https' && host.isNotEmpty`，否则抛 `QwenSttException('通义服务地址需要 HTTPS')` → 返回 `uri.origin`（丢 path）。
- 测试锚点（`test/qwen_stt_test.dart:45-54`）：`'dashscope-intl.aliyuncs.com/api/v1/'` → `'https://dashscope-intl.aliyuncs.com'`；`http://…` 抛异常。

## 4. 错误到可读中文的映射

- 专用异常类型：`QwenSttException(message)`（`:443-449`，toString 带 `QwenSttException(` 前缀）、内部信号 `QwenPolicyExpired`。
- HTTP 层 `_decodeObject`（`:402-413`）：非 2xx → `_httpFailure(response)`；JSON 解不开 → `'通义返回无法解析'`。
- `_httpFailure`（`:415-432`）按状态码 switch：401/403 → `'通义 API Key 无效，请在设置中更新'`；429 → `'通义请求过多，请稍后重试'`；其余取 body `message` 字段（裁剪 180 字符，`_clip`）拼 `'通义转写失败：{msg}'`，无 message 则 `'通义转写失败，请重试'`。
- 网络层在 `transcribePath` 包装（`:107-116`）：`TimeoutException` → 超时文案；`SocketException`/`http.ClientException` → `'无法连接通义服务，请检查网络后重试'`；`QwenSttException` 原样 rethrow。
- 控制器侧还有一层 `_speechErrorMessage`（`lib/state/recorder_controller.dart`）把异常转 UI 文案；Moss 用 `MossException(code, {statusCode})` 枚举码 + 中文映射（`lib/ai/moss_stt.dart:11-30`），是另一种风格。

## 5. 纯函数解析入口（全部可离线单测）

| 函数 | 行号 | 作用 |
| --- | --- | --- |
| `qwenTranscriptionBody({model, fileUrl, language})` | :568 | 构造提交请求体（含 diarization/language_hints 条件字段） |
| `resolveDashScopeBaseUrl` / `normalizeDashScopeBaseUrl` | :590/:599 | 地址归一化 + https 校验 |
| `parseQwenUploadPolicy(json) → QwenUploadPolicy` | :617-653 | 上传凭证（校验 upload_host https、max_file_size_mb 容错 num/String） |
| `parseQwenTask(json) → QwenTaskStatus` | :655-700 | task_status、results[]（subtask_status+transcription_url/code/message）、usage.duration → 聚合 failureMessage |
| `renderQwenTranscript(json) → String` | :702-738 | transcripts[].sentences[] {text, speaker_id} → `'说话人 N：'` 换行标注段落；无 sentences 回退 transcript.text |
| `qwenDurationSec(json)` | :740-746 | `properties.original_duration_in_milliseconds / 1000` |
| `qwenLanguageHints({model, language})` | :531-549 | 语言白名单（qwenAudio3LanguageCodes 29 语种 / paraformerV2 8 语种），'auto' 或不在白名单 → null（自动检测） |

豆包对应物：`doubaoTranscriptionBody` / `parseDoubaoQueryResult`（含 utterances→说话人段落渲染）/ `normalizeDoubaoBaseUrl` / `doubaoLanguageCode`（注意火山用 BCP-47 风格 `zh-CN`，不是 ISO `zh`，需要映射，见 doubao-volcano-api.md）。

## 6. 测试结构（test/qwen_stt_test.dart）

- **假 client**：`_ScriptedClient extends http.BaseClient`（`:283-305`）——内部 `requests` 列表记录每个 `http.BaseRequest`，`enqueue(int status, Object body)`（Map 自动 jsonEncode）把 `http.StreamedResponse(Stream.value(utf8.encode(...)), status)` 排进队列；`send()` 弹出下一个，队列空则 `StateError('unexpected {method} {url}')`。multipart 请求也走同一通道，测试里用 `client.requests[1] as http.MultipartRequest` 断言 fields。
- **脚本化端到端**（`:125-229`）：临时目录写 80 字节假 ogg（前 4 字节 'OggS'）→ 按序 enqueue：policy(200) → OSS 上传(200,'') → PENDING → PENDING → SUCCEEDED(带 transcription_url) → 结果 JSON。`QwenSttService(client: client, pollInterval: Duration.zero)`。断言覆盖：6 个请求的 method/path/query/headers（`authorization: Bearer test-key`、`x-dashscope-async`、`x-dashscope-ossresourceresolve`）、multipart 的 key/OSSAccessKeyId fields、submit body 的 model/input.file_urls/parameters.language_hints、轮询路径 `/api/v1/tasks/task-1`、结果取回 URL、最终 SttResult 字段。
- **纯函数组**：默认请求体（`:16-43`）、地址归一化（`:45-54`）、不兼容模型拒绝（`:56-73`）、task/文稿解析（`:75-123`，PENDING/SUCCEEDED 混合 results、speaker_id 渲染成 `'说话人 0：你好\n说话人 1：世界'`）。
- **跨层用例**：默认引擎优先级 `initialSpeechProvider`（`:231-258`，引用 `lib/ai/speech_provider.dart`）；设置页 widget 测试（`:260-280`）断言三个 ValueKey：`apikey-qwen` / `qwen-base-url` / `qwen-model`（工单 07 改数据驱动列表后这些 key 是回归锚点）。
- 控制器层的假法不同：`test/recording_processing_test.dart:736-762` 直接 `class _Qwen extends QwenSttService` 覆写 `transcribePath` 记录 seenKey/seenModel/seenBase/seenLanguage（服务级注入见 recorder_controller 构造参数 `qwenSpeech`）。

## 7. 给工单 08 的同构清单

1. 新文件 `lib/ai/doubao_stt.dart`：`DoubaoSttService({http.Client? client, pollInterval, taskTimeout})` + `apiKeyOverride`（或 appKey+accessToken 两字段）/`baseUrlOverride`/`modelOverride` 公开字段 + `isConfigured`。
2. 顶层异常 `DoubaoSttException(message)`；`resolveDoubaoBaseUrl`/`normalizeDoubaoBaseUrl`（https 强制、去尾 `/`、剥 API path 后缀）；请求体/解析全部顶层纯函数。
3. 流程映射：上传（火山标准版**没有**服务端托管上传，只有 audio.url；极速版 flash 支持 base64 audio.data —— 选型与推荐见 doubao-volcano-api.md）→ submit/query（标准版）或单发 flash → 取回 `result.text` + `utterances[]`（speaker 分离）。
4. 错误映射照抄形态：鉴权失败/限流/参数错/任务失败/超时各一条中文；状态码语义见 doubao-volcano-api.md 错误码表（20000000 成功、20000001 处理中、20000002 排队）。
5. `test/doubao_stt_test.dart`：复制 `_ScriptedClient` + 零 pollInterval + 纯函数组 + 脚本化全流程（注意豆包把状态放 **header `X-Api-Status-Code`**，假 client 需要能构造带自定义 header 的 StreamedResponse）。
