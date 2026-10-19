# 语音引擎枚举、设置持久化与转写接线（工单 07 / 09 的落点）

日期：2026-10-15。基线：`codex/warm-recording-workspace`（ede579e）。行号以 `git show ede579e:<path>` 为准。
涉及：`lib/ai/speech_provider.dart`、`lib/state/app_settings_store.dart`、`lib/state/recorder_controller.dart`（4617 行）、`lib/ui/screens/settings_screen.dart`（993 行）、`lib/ui/screens/recording_detail_screen.dart`（1381 行）。

## 1. 引擎枚举与默认优先级

`lib/ai/speech_provider.dart`（全文 37 行）：

```dart
enum SttProvider {
  apple('Apple 设备端'),
  soniox('Soniox'),
  moss('MOSS Pro'),
  qwen('通义 Qwen');
  ...
  /// Transcription starts after the recording is saved. There is no live stream.
  bool get defersTranscription =>
      this == SttProvider.moss || this == SttProvider.qwen;   // :11-12
  static SttProvider? parse(Object? value) { ... }            // 按 name 匹配
}
```

默认选择 `initialSpeechProvider`（`:27-37`）：

```dart
if (saved != null) return saved;                       // 已保存选择优先
if (appleSupported && !sonioxConfigured) return SttProvider.apple;
if (sonioxConfigured || !qwenConfigured) return SttProvider.soniox;
return SttProvider.qwen;                               // Apple 不可用且都未配置 Qwen 时
```

即优先级 Apple → Soniox → Qwen；`qwenConfigured` 是后加的可选参数（默认 false）。**豆包接入（工单 09）**：spec 决定"豆包仅在被显式配置并选择时生效"，即不进 fallback 链，只加枚举值 + `defersTranscription` 覆盖。测试锚点：`test/qwen_stt_test.dart:231-258`。

注意：`feat/ui-redesign` 分支（3d86fce 基底）的该文件**没有** qwen、没有 `defersTranscription`，`initialSpeechProvider` 也没有 `qwenConfigured` 参数 —— 挑回 357a426 设置页时这是必改点（见 ui-redesign-cherry-picks.md）。

## 2. 设置持久化（app_settings.json）

`lib/state/app_settings_store.dart`：

- `AppSettingsStore`（`:12-58`）静态类：文件 = `{ApplicationDocuments}/AnkerRecorder/app_settings.json`（`:15,:18-28`，目录不存在则建）；`save` 用 `JsonEncoder.withIndent('  ')` 序列化，**串行链**（静态 `_pendingSave` 串接防并发写）+ 临时文件 `.tmp` 写后 rename 的原子替换（`:42-58`）；`strict: true` 时失败 rethrow。
- `AppSettings` 值对象（`:60-186`）：字段 `speechProvider`（null=老安装未选过）、`appleSourceLanguage`、`sonioxApiKey`、`mossApiKey`、**云端三件套 `qwenApiKey` / `qwenBaseUrl` / `qwenModel`**（`:66-68,:80-82`）、`autoTranscribe`/`autoRealtime`、`transcriptLanguage`、`sttMode`、翻译/交流语言等。
- 序列化键名（`toJson` `:135-153`）：`'speechProvider'`(enum name)、`'qwenApiKey'`、`'qwenBaseUrl'`、`'qwenModel'`、`'sonioxApiKey'`、`'mossApiKey'`、`'autoTranscribe'`…；空值键整体省略。`fromJson`（`:154-186`）用 `_str`（空串/'null' → null）容错读。
- `copyWith` 带 `clearQwenKey/clearQwenBaseUrl/clearQwenModel/clearSoniox/clearMoss` 布尔旗标实现置空（`:95-134`）——**这是"三字段三 setter"的现状根源**，工单 07 的值对象要替换的就是这层。

**工单 07 目标形状**：把每家云端引擎的 key/服务地址/模型名收拢为一个配置值对象（构造、copyWith、序列化各一份）。Qwen 现状即 `qwenApiKey/qwenBaseUrl/qwenModel` 三字段 + 控制器三个 setter；豆包会带第四字段（火山要 appKey/appId + access key 两种控制台凭证形态，见 doubao-volcano-api.md）。迁移要求：已保存的 `qwenApiKey` 等旧键无损读入新结构。

## 3. 控制器里的三件套 setter 与回填

`lib/state/recorder_controller.dart`：

- 构造注入：`RecorderController({..., QwenSttService? qwenSpeech, MossJobStore? mossJobStore, ...})` → `_qwenStt = qwenSpeech ?? QwenSttService()`（`:53-68`）。服务实例是控制器私有 final（`:2371`）。
- 启动回填 `_loadPersistedSettings`（`:326-364`）：`_qwenStt.apiKeyOverride = s.qwenApiKey; _qwenStt.baseUrlOverride = s.qwenBaseUrl; _qwenStt.modelOverride = s.qwenModel;`（`:330-332`）→ `autoTranscribe` 等 → `initialSpeechProvider(saved:…, qwenConfigured: _qwenStt.isConfigured)`（`:351-356`）→ 延迟转写引擎强制 `sttMode = transcription`（`:357-361`）→ 首次（无 saved）补一次持久化。
- 反向 `_persistSettings`（`:366-386`）：从各服务的 `*Override` 字段收集回 `AppSettings` 再 save。
- 三个 setter（`:1695-1722`）：`setQwenApiKey`（trim，空→null）；`setQwenBaseUrl`（**保存时即做 `normalizeDashScopeBaseUrl` 校验**，非法抛 `QwenSttException`，UI 捕获展示）；`setQwenModel`（trim，空→null）。均 `notifyListeners()` + `unawaited(_persistSettings())`。
- 存取 getter（`:1690-1693`）：`qwenApiKeyStored` / `qwenBaseUrlStored` / `qwenModelStored` / `qwenConfigured` 供设置页 TextField 初值。Moss 有单独的验证流 `validateAndSaveMossApiKey`（`:254-267`：先 `validateKey`（GET /models）再保存，失败回滚）。
- 引擎切换 `setSpeechProvider`（`:470-481`）：延迟转写引擎强制 sttMode=transcription，选 Apple 时 `refreshAppleCapabilities()`；`setAutoTranscribe`（`:1620-1628`）。

**工单 07/09 适配点**：新值对象 setter 应是 `setEngineConfig(SttProvider, EngineConfig)` 一类成组入口；豆包 setter 里对 baseUrl 做同样的"保存时归一化+可读错误"。

## 4. "录完自动转写"的接线点

- 配置快照 `_SpeechConfiguration`（类定义 `:4553-4603`）：`_settingsConfiguration` getter（`:491-510`）每次从当前设置组装，**内嵌 `qwenKey/qwenBaseUrl/qwenModel`、`mossKey`、`sonioxKey`** —— 录音开始时被 `_beginNewLiveTranscriptSession`（`:1809-1832`）捕获进 `_RecordingSession`，录完后即使设置已改也用旧快照（测试 `test/recording_processing_test.dart:124-168` 专门验证这点：录中改 key/切引擎，转写仍用 take 开始时的 'qwen-key'/zh/defaultModel/defaultBaseUrl）。
- `_isConfigured(config)`（`:524-529`）按 provider switch：qwen → `config.qwenKey?.isNotEmpty == true`。豆包加一条分支。
- 入队函数 `_enqueueMossRecording(owner, path)`（名字历史遗留，实际是两家延迟引擎共用的入队口，`:269-300`）：守卫（disposed/active/paused/!ended/已在 finalize/!defersTranscription/!enabled/!_isConfigured）→ **qwen 分支**（`:283-289`）把 `(path, owner.configuration)` 放进 `_pendingQwen` 内存队列并 `_pumpQwenJobs()`；**moss 分支**（`:290-299`）`_mossJobs.enqueue(...)` 失败 → `owner.error = '无法保存转写任务…'`。
- 触发点（四处）：
  1. `:1010` 设备端录音线状态 status==0（record wire 停止）；
  2. `:1042-1050` 实时会话结束：先 `_convertExportToWav` 完成后（`_finalizingRecordings` 去重）再入队——**转写要等音频规整完**；
  3. `:1823` 新 live 会话开始时把上一段未处理的 take 补入队；
  4. `:3075` record wire status 回 0 兜底。
- 手动路径：录音详情 `_transcribe` → `controller.transcribeRecording(ref, …)`（`:1890-1914`，路径缺失提示"请先下载录音"）→ `transcribeLocalFile(path, …)`（`:1917-1934`，`await _settingsLoaded` 后用**当前**设置配置，不快照）→ `_runFileTranscription(path, config, {fromQueue})`（`:1937-2051`：busy 守卫/缺配置 `'请在设置中配置 {provider.label}'` 写 `_recordingErrors[key]`；moss 走 `_mossJobs.enqueue(retry: true)`；其余走 `_transcribePath` 分发（`:2147-2178`：apple 转 wav → `_appleSpeech`；**qwen → `_qwenStt.transcribePath(apiKey/baseUrl/model/language/onProgress/isCurrent)`**；默认 soniox）；成功 `rememberTranscript`（`:1085-1112` 写 `_transcriptMetadata[key]` 的 provider/sourceLanguage/revision + transcriptsByPath/ByFileId + `_persistTranscripts`），失败写 `_recordingErrors[key]`）。
- 缺 key 手动触发提示路径（工单 09 故事 9）：即 `_runFileTranscription:1955-1961` 的 `'请在设置中配置 ${config.provider.label}'`；未配置引擎"可见但不可选"要在数据驱动列表层做（工单 07）。

## 5. 录音详情的状态展示与失败重试

- 视图数据 `recordingView(ref)` → `RecordingViewData`（`:582-658`）：`processing` = `_fileJobKey == key || session.finalizing || moss 队列 pending || moss active 对应该 key`（`:644-648`）；`error` = `_recordingErrors[key] ?? moss job error ?? session.error`（`:649-652`）；`progress` = 文件任务 `fileTranscriptionProgress` 或 moss job 的 `SttFileProgress`（`:653-655`）；`provider` 来自 `_transcriptMetadata`（文稿持久化了产出引擎 → 多引擎文稿共存的依据，故事 8/10）。**豆包接入后 `processing/progress` 需把 qwen/doubao 的内存队列状态并进来**（当前 qwen 只有 `_fileJobKey` 单任务位）。
- UI `lib/ui/screens/recording_detail_screen.dart`：
  - 进行中：`_ProcessingStatus`（`:1182-1214`）按 `SttFileStage` 显示"正在准备音频…/正在上传…/等待处理…/正在获取结果…/正在处理…" + `LinearProgressIndicator(value: progress?.fraction)`；挂载点 `:509`（`if (recording.processing)`）。
  - 失败：`:510-514` 错误文本 + `:776-786` `Icons.error_outline_rounded` 通告；底部空态提示 `:829-844`（audioLocked/"自动转写已关闭"/"请先下载录音"/"在设置中准备语音服务后即可转写"）。
  - 重试：菜单项 `:355-379`（`value: 'transcribe'`，"重新转写"）与空态按钮 `:870`（"转写录音"）都汇到 `_transcribe(recording)`（`:109-183`）：busy/audioLocked 直接 return → 已有文本时弹"重新转写？"确认框（Apple 走语言选择表单，其余简单确认"成功后将替换当前文本…失败时保留现有结果"）→ `transcribeRecording(...)`。**工单 09"失败可手动重试一次"复用这条路径**；qwen 失败后 `_recordingErrors[key]` 有值即可再次触发（无次数限制逻辑，重试"一次"语义靠 UI 引导）。
  - Apple 专属表单 `_AppleTranscriptionForm`（`:887-1180`，内部还有自己的 `_error` + "重试"按钮 `:1080-1090`）是 Apple 特有分支，豆包不需要。

## 6. 设置页现状（工单 07 的改造对象）

`lib/ui/screens/settings_screen.dart`（ede579e，993 行）：

- 结构（`:23-114`）：`GradientScaffold > ListView`，两个 `_SettingsGroup`（"传输"/"语音与翻译"）；引擎选择是 `_ProviderSelector`（`:115-131`）——**`DropdownButtonFormField<SttProvider>` 遍历 `SttProvider.values`**，`ValueKey('speech-provider-{name}')`；下方按 `c.speechProvider == SttProvider.xxx` 的 if/else 链展开各引擎专属设置区（soniox → `_ApiKeyField(key: ValueKey('apikey-soniox'))`；moss → `_MossKeyField`；qwen → `_QwenSettings`；apple → `_AppleLanguageSettings`）。
- `_QwenSettings`（`:899-993`）：三个 TextField（key `apikey-qwen`/`qwen-base-url`/`qwen-model`，key 框 `obscureText`，hint 默认值，helper 文案含 intl 站）+ "保存"按钮；`_save()` 顺序 `setQwenBaseUrl → setQwenModel → setQwenApiKey`，`normalizeDashScopeBaseUrl` 抛错时 `setState` 展示 `_error`（AppColors.coral），成功后回写归一化后的 URL。
- 延迟引擎的 UI 影响：`自动转写` 副标题随 `defersTranscription` 切"录音结束后生成文字"（`:54-56`）；延迟引擎不显示 `_SttModeSelector`（`:90`）。
- widget 测试锚点：`test/qwen_stt_test.dart:260-280`（三 key + '通义 Qwen' 文案）。

**工单 07 目标**：换掉 Dropdown + if/else 链为数据驱动引擎卡片列表（原型在 `feat/ui-redesign` 357a426，见 ui-redesign-cherry-picks.md 第 4 节：`_ProviderSelector._metaFor` 按 `provider.name` 出 `{icon, description, statusLabel, statusColor}`，`_EngineOptionCard` 渲染，新引擎零界面代码）；三件套成组呈现为引擎配置卡（豆包落地时验证"新增一家只改数据"）。
