# 实时纪要、双语字幕与会议收尾（#510 / #511）

状态：EGM 三路详细设计复审通过，代码已实现，check静态分析/1076项测试、Mac原生构建及八个性能场景通过；真实环境验收另见 #515。上层产品边界见 [Cicada 对齐设计](cicada-alignment.md)。此文收口 B1/B2；不实施同传、声音克隆或新识别模型。技术选择由 agent 按简单、稳定、易维护原则负责。

## 用户行为与范围

- 每场录音显式开启实时整理或字幕；默认关闭，不因升级产生新的付费请求。设置沿用已有文字分析提供方、模型、源语种及翻译目标语种。首版使用本场开关，避免持久开关意外启用下一场；这是上层 settings 开关方案的具体化。
- Mac 双路录音使用本机识别确定段。手机和 BLE 使用现有实时转写/纯文字记录入口；普通仅写音频文件的麦克风录音不假装提供实时转写，界面说明可用入口。不增加第二条麦克风采集链。
- 录音时显示原文/译文与速记；半句只供现有实时文字显示，不送入纪要。停止后保存速记及出处，正式文件转写仍走原有流程。
- 点击编辑即暂停机器更新；保存的手改保留为活动版。用户恢复后机器产物仅作为候选，明确选择才替换活动版。停止后的正式纪要也保留手改。
- Mac 有纪要窗口、字幕条、隐藏三态和全局快捷键。字幕条穿透鼠标，悬停降低不透明度；一键隐藏可用，不承诺共享屏幕不可见。
- 自动结束每场默认关闭，仅可绑定当前唯一已检测到的 Mac 会议应用。30秒连续不用麦克风后开始60秒倒计时，可取消；使用恢复、检测失败、设备变化、多应用冲突均取消倒计时。没有可靠 VAD 时不启用静默触发器，不用文字为空或音量小替代人声检测。

## Detailed Implementation Plan

### 1. 句段身份与输入适配

新增 `lib/state/live_segments.dart`：不可变 `LiveSegment(id,text,revision,sourceLanguage,translation,targetLanguage,provider)`；ID 为会话/lane/requestId，列表顺序为首次接受顺序。同一ID文字更改递增revision；重复事件无变化。原始完整句段本机保留，提交时按最多12000字符块划分来源，块ID分配后永不重编号。单次过长确定段可按字符边界分块，而非丢弃尾部。

Mac 原生 `DualLiveSpeech` 每次recognition request生成UUID，通过 `DualRecordingBridge` 输出会话ID、lane、requestId、offset、final。Dart `MacDualRecorder.start` 生成并传入会话ID；只有当前会话事件可更新文字/文件；final集保留首次接受顺序，旧请求的final仍可在同会话内收尾。partial只更新现有显示；final之后的partial不得降级；final修订显式触发过期而非沿用旧证据。保持 `.dual.txt` 导出和回声抑制的现行功能。

云/Apple `SttStreamEvent` 是累积快照：只在speechFinal或done接受；若新快照以前一确定全文为前缀，只追加后缀；若修订已确认部分，标过期并暂停增量。重连使用采集会话ID，不能以新网络连接隐式创建新会议；字幕已有final译文按sourceText精确匹配复用，未匹配则不冒充对应句。纯文字记录的分段完成事件走相同适配；全天监听不自动开启本功能。

### 2. 有界实时纪要

新增 `lib/state/live_minutes.dart` 和 `live_minutes_store.dart`。一个会话一个调度器，最多一个活跃请求，输入快照只维护最新版本。首次新增200字符或首次确定段后30秒可发送；后续新增至少200字符且距离上次请求开始30秒。请求时钟/定时器可注入，生产Timer只负责唤醒，决策按真实当前时间。结束不会绕过门槛发出额外付费请求；剩余内容留给会后完整版。

每次实际请求最多12000字符新增来源加最多12000字符上次机器纪要，单个provider调用；每滚动小时最多120次。超过前版纪要上限则暂停并说明会后处理；新增来源积压按顺序继续分批，未发部分不丢。运行中新的确定段不取消旧请求；返回可以发布它实际覆盖的watermark，下一次从该watermark继续。已确认源发生修订则取消代际，旧返回不能发布。

`RecordingAnalysis.runLiveRevision`只封装既有AnalysisService的一次generate，不走run分块/合并/自动重试；沿用已有model、apiKey和后台保活。传入固定model及instruction，来源标号按会话全局S序列。返回经validateMinutes完整验证，检查引用只在本批新增编号或上一机器纪要已引用编号中；剥离模型采纳状态。保留本机完整来源快照用于验证，提示词不把全文重复上传。

store使用ContextFile/原子写，保存version、sessionId、recordingRef、sources、watermark、machine/active/candidate结果、编辑保护、revision、模型/模板指纹、请求时间及状态。保存串行、快照在执行时捕获。发请求前持久写pending（包含输入和指纹）且成功才调provider；结果连同watermark落盘成功才更新可见结果。保存失败停止调度并提示，不重发结果未知的请求。重启读取pending为unknown且不可自动续发；已关闭旧会话只读恢复。新会话必须新ID，不复用未知请求键。凭据不入store。

编辑入口先取消代际并持久编辑保护，机器迟到结果不覆盖。编辑中止的请求若传输结果未知，保留未知attempt；明确显示恢复将发起新请求，仅本次编辑可显式恢复，重启仍不续发。恢复生成仅产生candidate；选择candidate是显式操作。停止后把活动速记以AnalysisResult(isDraft:true)写入当前录音minutes槽；使用既有mergeImportedMinutes语义保护现有当前版，手改时间戳保留；正式版升级沿用preserveUserEdit。速记出处不得冒充正式转写时码。

### 3. 字幕翻译

新增 `lib/state/live_captions.dart`，与纪要共用LiveSegment输入。源语种来自提供方已报告值，否则用设置值并显示“所选语种”，不声称自动检测。目标可选择已有语言列表；修改目标取消代际并清旧目标译文。

已有同句/同revision/同目标final译文直接用，不重复请求。其余进入唯一串行翻译调度器，最多保留100条待译最新revision；溢出明确标“字幕翻译跟不上，已暂停”，保留原文，不无限排队。每条最多12000字符，过长提示无法实时翻译。失败显示原因，保留原文；未知请求首版不提供重发，新的记录使用新会话身份。结果按会话、句ID、revision、目标语种核对，迟到不覆盖新句。

文字翻译沿用已有AnalysisService（不新增云SDK），一次generate只翻译本句，明确标签为当前文字服务；已有Apple译文直接使用。关闭文字分析服务则缺失译文显示“文字服务未配置”，不暗中选择新服务。纪要与字幕请求各自串行，开关独立；本地音频约束不变，断网不停止录音。译文作为可重建派生缓存，首版不另建永久翻译库；速记来源/活动结果持久化。

### 4. 控制器与界面

新增 `lib/state/recorder/live_meeting.dart` mixin 统一当前LiveMeeting会话、开关、句段输入、结束和错误隔离；RecorderController持有它并清理listener/timer。接 `live_transcription.dart`、`text_capture.dart`、`phone_recording.dart` 的采集开始/确定事件/正常停止。Mac ValueNotifier listener只转发新final集合；异步结束必须捕获原session，不能把迟到结果写到下一场。关闭/取消录音使代际失效，不阻塞原件落盘。

新增 `lib/ui/widgets/live_meeting_panel.dart`，录音sheet、纯文字sheet和BLE实时页复用：开关、语种说明、双语列表、当前速记、状态、暂停/恢复、编辑/候选切换；展示上次成功结果及错误。编辑用现有结构化分钟模型，首版编辑概览/标题而保留全部其它字段，成功后新editedAt。恢复记录可从资料页打开本次持久会话；未知请求说明明确，不提供自动重发。

新增 `lib/platform/mac_captions.dart` + `macos/Runner/CaptionsPanel.swift`，通道仅收当前展示快照(mode,original,translation,minutes)。一个NSPanel按mode切大小，隐藏orderOut；字幕忽略鼠标，定时检查鼠标是否在bounds而非拦截事件，关闭时停timer。Swift不存内容/不调模型。AppDelegate及pbxproj注册；GlobalHotKeys沿用Carbon加 ⌃⌥⌘C 三态切换、⌃⌥⌘H 隐藏，冲突进入已有hotKeysTaken报告。MacMenuBar接通道，控制器停止或dispose隐藏窗口。

### 5. 自动结束

`MicrophoneUsers`发送 {available,users,device}，每2秒采样，即使users不变也作为心跳；任一CoreAudio读取失败/不支持时available=false，不能当空列表。Dart MacApp保留旧list回调适配供既有调用，新增快照回调；旧MeetingAppWatch在unavailable时reset，避免误判inactive。

新增 `lib/state/meeting_end_watch.dart`，可注入now；绑定录音session+单一会议bundleId。每秒tick仅在最近心跳<=5秒且设备未变化时计时。inactive连续30秒→deadline+60秒；取消后该轮inactive不再触发，必须看到active才能重新武装。unavailable、多会议、过期心跳、暂停录音及device变化重置观察并取消倒计时。stop触发一次，调用正常stopPhoneRecording且核对session仍匹配。启用新watch时旧MeetingAppWatch禁止stop提示但可继续start提示；只绑定phone Mac take，永不停止BLE实体录音或全天监听。UI显示倒计时、继续录音、检测不可用原因。无可靠人声检测，静默触发器明确不可用。

### 6. 变更范围、测试及交付

范围：上述新增文件；`recorder_controller.dart`、`recording_analysis.dart`、三个recorder接入文件、`mac_dual_recorder.dart`/`dual_recording_text.dart`、MacApp/MacMenuBar、DualRecordingBridge/MicrophoneUsers/AppDelegate/GlobalHotKeys/pbxproj、三个录音展示入口；docs/design、ROADMAP、CHANGELOG和progress。既有测试夹具只为新事件格式和真实I/O等待调整，不削弱断言。一个文件一个写入者。

先补失败行为测试，再实现：partial不进入整理；旧session迟到/final修订；200字符/30秒/120次/12000上限；单活跃+最新快照不丢句；pending落盘失败不请求、结果保存失败/重启unknown不重发；请求途中编辑与停止不覆盖；已有译文不重发、目标/修订变更拒绝迟到、队列过载及失败保留原文；三态检测/心跳超时/取消/多应用/换设备；widget开关、候选、390宽度；Mac通道三态及快捷键。

全量check、Mac无凭据profile构建和perf-check；有改动的原生代码须实际编译。真实麦克风/双路长会、网络恢复、iPhone/Pixel字幕、快捷键/穿透/共享屏幕及自动收尾独立归 #515，不阻塞已过审代码合并。PR和每个commit记录红绿、真实使用与未跑项。分支+PR squash交付，关闭#510/#511但不关闭#506或#515。

## 参考依据

- 本仓 `DualRecordingBridge.swift` 的DualSpeechRequest已用result.isFinal；Dart丢掉该标志是当前缺口。
- `scripts/ref search "transcript final isFinal translation realtime" -k 3`：`repos/omi/app/lib/backend/schema/transcript_segment.dart:189` 保留可定位分段序列，借鉴思路不复制代码。
- [Apple isFinal](https://developer.apple.com/documentation/speech/sfspeechrecognitionresult/isfinal)：只将final结果视为确定识别。
- [Apple window sharing](https://developer.apple.com/documentation/appkit/nswindow/sharingtype-swift.enum)：none是已不再使用的旧常量，不能承诺屏幕共享隐身。

### 评审收口：费用、收尾与资料身份

1. 字幕单独限额：滚动小时最多120次实际翻译调用（与纪要各自独立），失败及显式重试也计数；达到上限暂停翻译，原文继续积累，用户在额度窗口移出后显式恢复。翻译也持久化pending/unknown任务、session/id/revision/target和请求时间，发前落盘；不会因关开字幕或重新打开资料重发未知任务。字幕原文、已成功译文和错误状态与会话一同本地保存；历史会话只读，不重建翻译队列。
2. 所有本批实时会话使用单一 `LiveMinutesStore`（ContextFile('live_meetings.json')）根结构 `{version:1,sessions:{id:session}}`。store提供read(id)、all、write(id,snapshot)，写入串行，成功后才改变已提交内存视图。会话快照含不可变sources、字幕成功结果、请求journal和恢复身份；不含凭据。主控制器读写只经store，不复制第二套永久字幕库。单会话来源总量上限2,000,000字符，达到即暂停并说明会后整理，原录音仍保存，不静默裁剪。
3. 资料身份为 `{kind:audio|document,key:path|documentId}`，不是强制RecordingReference。开始BLE时暂存session，取得path后绑定audio；Mac take开始即path；纯文字开始即documentId。保留原声转成audio资料后绑定新path；没有原声则仍documentId。音频结束发布到existing analysisKey(ref)/minutes；纯文字资料页新增只读 `SavedLiveMeetingPanel(documentId:...)` 从同一store显示已存速记/出处/字幕。音频详情页也提供按path读取的恢复面板，pending显示“上次请求结果未知，未自动重发”，无自动重发按钮。
4. 正常停止顺序：先同步设置会话closing禁止新的纪要/翻译调用，现有ASR stop/finish有界等待末尾final（沿用现有native 2秒/stream 20秒超时），继续接受属于原session的final并落盘；ASR收尾完成后end取消请求代际、持久closed及最后来源，然后原件正常保存和速记移交。正在执行的整理/翻译未完成时记unknown，不等模型阻塞录音保存。下一场新session的listener隔离旧事件。取消/丢弃直接取消代际，不请求新生成。
5. `phone_recording.dart::_saveTakeNotes` 不再自行启动generateDraftMinutes；无论正常停止或崩溃恢复都只保存识别文字/笔记。这是移除重复自动生成所有权；会后完整纪要仍由明确操作及现有formal升级路径负责。实时会话的stop移交只保存已成功结果，绝不付费补尾。测试覆盖未启用实时功能的停止也不新增后台草稿请求。
6. 实施分三阶段：A句段/调度/store独立模型及失败测试，保持旧UI可构建；B控制器/三个实时入口/保存资料页接线及widget行为，完整check；C原生浮窗/三态检测和自动结束，原生编译+通道回归+check/perf。各阶段不另建持久服务或依赖。
7. 补全写入名单：`lib/state/live_segments.dart`、`live_minutes.dart`、`live_minutes_store.dart`、`live_captions.dart`、`meeting_end_watch.dart`、`recorder/live_meeting.dart`；`lib/ui/widgets/live_meeting_panel.dart`、`saved_live_meeting_panel.dart`；`lib/ui/screens/new_recording_sheet.dart`、`text_capture_sheet.dart`、`minutes_document_screen.dart`、`recording_detail_screen.dart`、`lib/ui/widgets/transcript_panel.dart`；前述明确平台/控制器文件。新增测试 `test/live_minutes_test.dart`、`live_captions_test.dart`、`live_segments_test.dart`、`live_meeting_test.dart`、`meeting_end_watch_test.dart`、`mac_captions_test.dart`；既有回归范围 `test/mac_dual_recorder_test.dart`、`mac_menu_bar_test.dart`、`phone_recording_test.dart`、`text_capture_test.dart`。不修改其它产品域。
8. 提供方能力：千问sentence_end与Apple speechFinal有确定事件；当前豆包adapter只在done确定全文，首版显示“此服务不提供实时确定句段，请用千问/Apple或会后整理”，禁用其实时纪要/字幕，既有普通实时转写不变，不把partial猜作final。Mac将冻结源语种locale传入start/可用性探测/每次新request；auto时明确采用zh-CN并在事件报告sourceLanguage=zh，unsupported只停识别、原件继续保存。
9. `LiveSegmentCollector.acceptCumulative(connectionId,text)` 每连接只维护confirmedText；同connection若非前缀扩展则stale，前缀扩展仅新增后缀。同采集会话换connection时以前连接confirmed为边界，新连接文本独立追加，绝不读取 `_streamTranscriptPrefix` 或 `_textCommitted` 中可能含partial的值。BLE监听闭包绑定sttLifecycleRevision、纯文字监听绑定_textGeneration，将这两个token传入collector。纯文字重连重发从现有final mark开始；BLE重连保守标过期暂停纪要。超过maxResendBytes或存在未确认缺口时主动标过期暂停纪要，不把漏掉的partial标已确认。测试final A/partial B→新connection final B再BC，确认A/B/C只出现一次。
10. Mac采样启用条件为旧会议提示开启，或当前Mac phone take存在（供用户选择绑定）；不会因为旧提示关闭而停检测。结束/关闭功能后若旧提示关闭则释放采样；MacMenuBar仅在当前take能绑定时展示开关。绑定前必须有新鲜available快照且listed会议app恰好一个。新watch启用时旧watch的stopAsk分支禁用，unavailable重置旧watch。
11. device不是推测绑定输入。原生对process list每个运行输入进程读取 `kAudioProcessPropertyDevices` 并将设备对象解析为 `kAudioDevicePropertyDeviceUID`，排序去重后组成全快照device fingerprint；另读取系统默认输入设备UID，合并到fingerprint。任何查询失败使available=false；系统不报告设备时为unavailable。此保守全局fingerprint任一设备变化都会重置观察，允许多物理设备但不允许多个listed会议应用自动推断归属。查询属性依据本机macOS SDK `AudioHardware.h:1953`，不引入私有API。
12. 配置指纹包含backend、endpoint、model、模板及语种（不含密钥）。开启时冻结；每次pending落盘之后、provider调用之前同步比较当前指纹；不同立即暂停，不调用。provider构造请求同步读取endpoint/backend，调用后再次比较，配置改变则结果只留未知/过期状态而不发布。密钥仅内存获取，不复制到journal。测试pending写入期间改变backend/endpoint不发请求。若用户改配置，须结束本场实时功能；本场不混用新提供方恢复机器基线。

## 上游代码对照（实施复核）

固定版本 `38771f1a5ae691c848ea429f4a870defd92d9d26`，直接查代码后沿用其职责划分，不复制源码：

- `Sources/LiveSubs/Notes.swift:105–114,188–225`：单一 inFlight、增量 covered 水位、定时调度与待处理请求；Koe 对应 LiveMinutes 单活跃请求/来源水位，额外接已有编辑保护和本地原子保存。上游 finish 自动全文补生成（143–149），Koe 按本次已收口的费用边界只移交已成功速记，完整版保留明确操作。
- `Sources/LiveSubs/Notes.swift:254–263`：返回后核对语种，过期产物不发布；Koe 对应会话、配置和修订核对。
- `Sources/LiveSubs/Overlay.swift:56,139–152,175–197`：穿透鼠标、统一窗口显示状态、hover timer 在显示/隐藏时管理；Koe 原生 CaptionsPanel 采用同样分工，不在 Swift 中复制翻译或纪要状态。
- `Sources/LiveSubs/NotesWindow.swift:62,110`：共享可见性使用 sharingType；此 API 的局限仍按 Apple 文档和 #515 实测，不把设置属性当作隐身验收。
- `Sources/LiveSubs/MeetingEnd.swift:71–94`：会议恢复即撤销结束倒计时；Koe 保留这一语义，并接既有录音所有权和不可用心跳保护。

后续本系列遇到调度、翻译、窗口或自动结束异常，先定位以上上游实现和测试，再判断 Koe 的平台接入差异。
