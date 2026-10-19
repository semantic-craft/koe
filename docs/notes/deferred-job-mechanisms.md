# Moss 与 Qwen 的延迟文件任务机制（工单 10 收拢前的现状）

日期：2026-10-15。基线：`codex/warm-recording-workspace`（ede579e）。行号以 `git show ede579e:<path>` 为准。
核心事实：**Moss 有独立的持久化任务队列（lib/state/moss_jobs.dart，473 行）；Qwen 没有任务存储，只有 controller 里的内存 Map 队列**。豆包（工单 08/09 第一步）按 spec 决定复用 **Qwen 模式**（内存队列）。

## 1. Moss：持久化任务队列（lib/state/moss_jobs.dart）

### 1.1 数据结构

- `MossJobStage` 枚举（`:14-24`）：`queued, uploadUnknown, uploaded, submissionUnknown, polling, result, cleanup, complete, failed`。两个 `*Unknown` 阶段在**发起非幂等请求之前**先落盘——重启后不知道请求是否被接受，要求显式重试而不是自动重发（防重复计费）。
- `MossJob`（`:26-85`）：`id`（微秒时间戳字符串）、`recordingKey`（`file:{id}` 或 `path:{path}`，与 controller 的 `_recordingKey` 同构）、`path`、`stage`、`fileId`（远端文件）、`taskId`、`text`、`language`、`error`、`discarded`；**不序列化**的瞬态字段：`key`（API key 快照）、`progress`（SttFileProgress）。`pending` getter = 未 discarded 且 stage ∈ {queued, uploaded, polling, result}。`toJson/fromJson` 一一对应。
- `MossJobStore`（`:87-125`）：文件 = `{ApplicationDocuments}/AnkerRecorder/moss_jobs.json`（`:96`），整体 List 快照保存（不是增量日志）；原子写（`.tmp` + rename）；串行写链 `_writing`；`inMemory: true` 供测试/无持久化构造。

### 1.2 队列生命周期 `MossJobQueue`（`:129-473`）

构造依赖（`:130-143`）：`service: MossSttService`、`store`、`apiKey: String? Function()`、`canStart: bool Function()`、`onResult: Future<void> Function(MossJob, SttResult)`、`onChanged: void Function()`（= notifyListeners）。公开 `jobs` 列表、`active`、`busy => active != null`、`forRecording(key)`（找该录音最后一个未 discarded 的 job）。

- **load**（`:157-175`）：启动恢复；corrupt journal → `loadError = '无法读取待处理转写，请重启后重试'`（**不**当作空表，防止重复上传）；恢复出 `*Unknown` 阶段的 job 标记 `error = '上次请求结果未确认；重试会重新提交，可能重复计费'`。
- **enqueue(recordingKey, path, {key, retry})**（`:177-221`）：去重——已有 pending 或 active 的同录音 job 直接返回其 waiter；重试时若已有 `taskId` 且未 complete/cleanup，**不重传音频**，把 stage 拨回 result/polling 继续查询；否则旧 job 标 discarded（有 fileId 且非 submissionUnknown → 转 cleanup 删除远端文件）。新建 job 落盘 → 返回 per-job `Completer` future。
- **wake/_later**（`:223-239`）：`Timer(Duration.zero)` 延迟触发避免 rebuild 重入；轮询退避用 `_later(delay)`。
- **_drain**（`:241-433`）串行状态机（受 `canStart()` 门控）：
  - queued → `service.prepareAudio` → **先写 uploadUnknown 落盘** → `service.upload`（进度回调写 job.progress）→ uploaded；
  - uploaded → **先写 submissionUnknown** → `service.submit(fileId)` 得 taskId → polling；
  - polling → `service.task(taskId)` 返回 `{'status': 'SUCCESS'|'FAILED'|'PENDING'|'PROCESSING', 'retry_after'?}`：SUCCESS → `service.parse` 得 SttResult → result；FAILED → error=failed → cleanup；PENDING/PROCESSING → 进度 queued/processing，`delay = clamp(retry_after ?? 3, 1, 30)s` 后再来；其他 status → 抛 `MossException('response')`；
  - result → `onResult(job, SttResult(...))`（**先交付再清理**，调用方要先把文稿持久化）→ cleanup；
  - cleanup → `service.deleteFile(fileId)` 删远端音频 → complete，完成 waiter。
  - 异常分类（`:380-420`）：cleanup/complete 段失败 → 30s 后重试清理；`*Unknown` 段失败：HTTP 显式拒绝（statusCode < 500）→ failed/清 error message，否则标"结果未确认"；polling 段可重试错误（`error.retryable`）→ 10s 退避；其余 → failed 保留 text 供显式重试。store.save 失败 → `'无法保存转写进度，请检查存储空间后重试'`。
- **rename(oldKey, newKey, path)**（`:437-445`）与 **discard(key)**（`:447-462`）：配合录音重命名/删除；discard 时已提交的任务仍轮询到终态再删远端文件。
- **dispose**（`:464-472`）：取消 timer、完成所有 waiter、`service.dispose()`。

### 1.3 controller 耦合点（recorder_controller.dart）

- 构造（`:193-241`）：`canStart: () => !_disposed && _fileJobKey == null && !_liveProcessing`（**live 录音和手动文件任务优先于队列**）；`onResult` 回调（`:202-222`）：等 `_transcriptsLoaded` → 文件还在才交付 → `rememberTranscript(path, result.text, provider: SttProvider.moss, …)` → `_persistTranscripts(strict: true)` → 清 session.error。
- 启动 `Future.wait([_settingsLoaded, _transcriptsLoaded]).then((_) => _mossJobs.load())`（`:230-234`）。
- UI 状态桥：`recordingView` 的 `processing`/`error`/`progress` 直接读 `_mossJobs.forRecording(key)` / `.active` / job.progress（`:644-655`）；`fileProcessingBusy`（`:684`）= `_fileJobKey != null || _mossJobs.busy || _liveProcessing`；`mossRecoveryError` 暴露 `loadError` 给设置页（`:245`）。
- 入队：自动路径 `_enqueueMossRecording` 的 moss 分支（`:290-299`）；手动/重试路径 `_runFileTranscription`（`:1962-1971`，`retry: true`）。

## 2. Qwen：无任务存储的内存队列（recorder_controller.dart 内嵌）

状态字段（`:2395-2399`）：

```dart
final Map<String, ({String path, _SpeechConfiguration config})> _pendingQwen = {};
final Set<String> _qwenStarted = {};
bool _qwenPumping = false;
```

- key = `_recordingKey(path)`（`file:{id}` / `path:{path}`，`:556-559`）；value 是录音 take 的配置快照（含 qwenKey/qwenBaseUrl/qwenModel）。
- 入队（`_enqueueMossRecording` 的 qwen 分支，`:283-289`）：同一 key 已在 `_qwenStarted`（曾跑过）则跳过；否则塞 Map（覆盖同 key）并 `_pumpQwenJobs()`。注释明说：**"Qwen has no durable job store. Wait until the live take is idle, then run the file transcription captured with that take's settings."**
- 泵 `_pumpQwenJobs`（`:302-324`）：互斥 `_qwenPumping`；门控 `_liveProcessing || _fileJobKey != null || _mossJobs.busy` 时直接返回（**不消费队列，下轮再试**）；取 `entries.first`（FIFO）→ `_runFileTranscription(path, config, fromQueue: true)`；返回 `accepted`（false 表示"应等待重试"——即 `_runFileTranscription` 开头 busy 守卫对 fromQueue 返回 `!fromQueue`=false，`:1945-1952`）→ accepted 才 `remove` + `_qwenStarted.add`，并连锁泵下一个。
- 执行体 `_runFileTranscription`（`:1937-2051`）：单任务位 `_fileJobKey`/`_fileJobProvider`/`_fileJobRevision`（代际号防旧任务写回）；进度写 `fileTranscriptionProgress`；成功 `rememberTranscript`，失败 `_recordingErrors[key] = _speechErrorMessage(error)`；结束清单任务位。**重启即丢**：app 重启后未跑的 pending 无从恢复（Moss 则会从 journal 续跑）。
- 取消：`isCurrent: () => !_disposed && revision == _fileJobRevision` 贯穿服务调用；录音暂停会作废进行中的文件任务（`:1837-1844`，`'处理因录音暂停，可在录音结束后重试'`）。

## 3. 两者形状差异对照

| 维度 | Moss | Qwen |
| --- | --- | --- |
| 代码位置 | 独立文件 `lib/state/moss_jobs.dart`（可单测） | controller 私有字段+方法，无独立类型 |
| 持久化 | `moss_jobs.json` journal，9 阶段落盘，重启续跑 | 无；进程内 Map/Set |
| 去重键 | recordingKey + per-job Completer waiter | `_pendingQwen` Map + `_qwenStarted` Set（完成后永不重入） |
| 并发 | 串行 drain，`active`/`busy` | 串行 `_qwenPumping` + `_fileJobKey` 单任务位 |
| 与 live/手动任务互斥 | `canStart()` 回调（constructor 注入） | pump 里的 if 守卫 + `_runFileTranscription` busy 检查 |
| 非幂等保护 | `*Unknown` 阶段先落盘，"结果未确认"文案 | 无（重试 = 整个重传重提） |
| 重试语义 | `enqueue(retry: true)` 复用 taskId 不重传 | 详情页"重新转写"走 `transcribeLocalFile`（用**当前设置**而非 take 快照），队列不管 |
| 进度/错误暴露 | job.progress / job.error → recordingView | `fileTranscriptionProgress` / `_recordingErrors[key]` → recordingView |
| 交付 | `onResult` 回调（先持久化再 ack） | `_runFileTranscription` 内直接 `rememberTranscript` |

**工单 10 方向**：收拢为单一"延迟文件任务"机制时，形状上 Moss 队列是超集（持久化 + 状态机 + waiter）；Qwen 模式的最小集是（key → {path, config 快照}）+ 单并发泵 + `_qwenStarted` 完成集。豆包第一步接入 Qwen 模式（spec Implementation Decisions 第 6 条），注意：若照 `_qwenStarted` 语义，豆包失败后**自动**重试不会发生，只能手动重试（与故事 7 一致）。

## 4. 测试接缝（收拢后要保绿的三组）

- `test/moss_jobs_test.dart`（queue 级）：`FakeMoss extends MossSttService`（`test/support/moss_fakes.dart:6-63`，覆写 prepareAudio/upload/submit/task/deleteFile + 计数器 + pendingUpload/pendingTask Completer 挂起点）；`MossJobStore(inMemory: true)`；`settleUntil(condition)` 轮询 5ms×100（moss_fakes.dart:65-72）。用例覆盖：串行去重且快照 key 生效、恢复已知 taskId 不重传、`*Unknown` 恢复不自动重发、结果先持久化再 cleanup 等。
- `test/recording_processing_test.dart`（controller 级，Qwen 模式的直接参照）：`_Qwen extends QwenSttService` 覆写 `transcribePath` 记录入参（`:736-762`）；用例 `'Qwen file transcription starts after stop and keeps the take settings'`（`:124-168`）驱动 `handleRealtimeStateForTesting` 停止后 `settleUntil(() => qwen.calls == 1)`。
- `test/stt_progress_test.dart` / `test/recording_detail_test.dart`：进度阶段与详情 UI 状态（收拢后状态语义不能变，工单 10 验收第 2、3 条）。
