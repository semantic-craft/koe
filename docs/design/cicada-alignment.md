# Koe 对齐 Cicada 的会议功能

> 当前范围（2026-11-04）：用户已取消 #513 自然声与本人声音克隆，保留系统普通声音同传。下文 C2/Ming/克隆技术内容仅保留为历史调查，不再实施或验收。#507–#512代码已合并，后续优先#514真实纪要对照，其次#515/#516设备验收。

- Author: semantic-craft
- Status: A1 已交付；A1b/A2 详细契约经 EGM 实施就绪复核；实时与同传阶段仍按各工单收口
- Date: 2026-11-03
- 源码基线：Koe `fc12765102c7a318cf0644a7687f6befac8fec66`；Cicada `38771f1a5ae691c848ea429f4a870defd92d9d26`

## Overview

让录音豆取回的会议、手机麦克风录音与 Mac 会议进入同一套资料和纪要流程。Mac 对齐 Cicada 当前已有功能；三端（macOS、iOS、Android；Android 当前限定 Pixel）共享会后整理、阅读、校正、翻译和导出。实时字幕和同传按平台能稳定取得和输出音频的能力接入，不能为了界面一致绕过系统限制。

用户已授权：从简单、稳定、易维护出发自主选择技术方案；EGM 评审通过后拆工单并实施，不逐节要求用户确认。未要求复制 Cicada 代码。以下设计优先复用 Koe 数据和处理管线。

## The Problem

现有纪要已有总结、议题、决策、待办、未决问题、个人词表、修订、导出和回听，但议题是平面列表；思维导图不表示因果；每场会议没有人名术语解释及误识别变体。停止录音后生成草稿不等于开会期间持续整理。Mac 也缺少独立双语字幕和送入会议软件的翻译语音。

功能数量不证明质量。对齐必须分别检查实现、真实服务效果、设备操作和用户数据保全；不能把编号有效当成原文真的支持结论。

## Goals

1. 会后页面顺序为总结、议题、结论与待办、人名和术语、未决与待确认。议题包含概括、关键点、来源；原文讨论因果时才显示因果图。
2. 正确名称、术语解释和识别变体可追溯到本场原文；机器建议不未经采纳改写用户逐字稿。
3. 实时文字持续更新速记纪要；会后正式转写生成完整版，保留手工编辑和版本历史。
4. Mac 提供实时双语字幕、显示切换、快捷键、语言检测、可选同传与用户自有声音克隆、会议结束收尾。
5. 原始录音、现有资料包、已有纪要、订正、书签、时间码和发言人不因升级损坏。原 v1 资料包不含 AnalysisResult；A1b 以 v2 携带当前纪要与最多10版历史，无纪要包仍写 v1，旧 App 明确拒绝 v2。
6. 三端默认仍用千问和已有兼容接口；已有“只留本机”选择仍约束音频是否可上传。

## Non-Goals

- 不要求手机注入通话音频或读取任意其他应用的声音，不提高现有最低系统版本。
- 不把 Cicada 尚在路线图的跨会声纹记忆、其他平台支持当成当前已具备的基准；Koe 的本地模型暂缓任务不全部自动重启。
- 不扩大到多人协作、外部 AI 交办、公开发行或云端账户系统。
- 不改变原始音频以消除静默；自动收尾只决定停止时间，已录原件保持完整。

## Scope and Delivery Stages

|阶段|用户得到的效果|依赖及结束条件|
|---|---|---|
|A1 会后结构|有层次的议题、可回听关键点、人名术语和因果图数据|新旧格式读写、渲染、全部导出与替换搜索消费者通过回归；真实模型和设备另列验收|
|A1b 纪要资料包交换|将当前纪要和历史随资料包转移，处理导入冲突|v2 白名单携带纪要，保留本机当前版，外来冲突进入历史；契约见下文与资料包格式文档|
|A2 术语采纳与检索|看懂正确名称及误识别形式，确认后统一订正；搜索能定位对应原句|依赖 A1；明确区分候选与已采纳，保留历史且不复活被用户明确删除的旧词|
|A3 会后效果验收|同一录音对照 Cicada；发现漏决定、错负责人、错误因果等可复现问题|依赖 A1/A2；实际音频经授权，记录人工标注与差异，不能只算 JSON 有效率|
|B1 实时整理|录音期间看到持续更新的速记版，停止后有完整版|现有收音源；串行任务、成本边界、断网与重启恢复经过测试|
|B2 双语字幕与收尾|Mac 浮窗/字幕/隐藏切换，手机应用内双语实时文字，会议结束可取消倒计时|依赖 B1 的分段身份；平台桥接与权限拒绝、共享屏幕隐藏、音频反馈实测|
|C0 同传能力验证|明确所选虚拟路由和服务可交付契约|检查官方 API、驱动许可/安装、TTS 音频输出、设备恢复；本阶段自身是工程调查工单|
|C1 Mac 同传|按住说话，翻译并合成声音送进会议应用；可随时取消|C0 文档契约核实后实施；真实路由独立验收，未通过不得标可用；故障不牵连主录音|
|C2 可选自然声与克隆|选择服务自然声；用户录自己的样本创建/删除声音|C0 选定服务能力与数据保留契约后实施；默认普通系统声音|

这张表是全量范围，不以完成 A 阶段宣称全量对齐。平台调查现已给出具体原生 API 与提供方协议（见平台证据）；C1/C2 可按这些契约实现替身测试和原生接线，真实设备/服务验收单列。C0 保留为依赖核对与隔离实验，不拿未执行的实验算作验收。

## Critical User Journeys (CUJs)

### CUJ 1：录音豆的会后纪要

- Given：录音已完整取回，有转写和可验证的分段时间码；未配置整理服务时先明确显示配置入口。
- When：用户选模板生成纪要。
- Then：总结后按讨论顺序显示议题；每个关键点、决定、待办和因果分支能查看原文。仅在原文未过期、原件存在、时码匹配时提供回听；没有可靠时码仍可阅读原文，不显示编造的时间。

### CUJ 2：确认人名或术语

- Given：模型提出本场名称、解释与原文实际出现过的识别变体。
- When：用户查看或采纳。
- Then：查看不改逐字稿。采纳展示受影响范围后调用既有订正流程，更新可读文本与纪要、保留来源编号和历史；可以仅加入个人词表而不替换原文。未采纳候选标注为建议。

### CUJ 3：实时会议及失败恢复

- Given：用户明确开始录音，已选择收音入口与允许的服务。
- When：新确定句段持续出现；随后断网、手工修改速记版、停止或进程异常退出。
- Then：字幕本地保留；整理失败保留上次版本，未知付费请求不自动重发；恢复先读持久任务。停止后的完整版保存在历史，不能覆盖手工编辑。

### CUJ 4：Mac 同声传译

- Given：路由能力验证通过，用户显式启用同传并选定会议输入设备；安装驱动由用户主动触发。
- When：按住快捷键讲话、松开，或中途取消。
- Then：只翻译该次按住的声音；输出有界排队且可打断。取消/退出/路由断开停止声音；只有系统输入仍是 Koe 本次设置的设备时才恢复原输入，不覆盖用户中途的设备选择。会议录音不录入 Koe 自己播放的合成声，避免反馈回路。

## Technical Plan (Architecture)

```text
录音豆 / 手机麦克风 / Mac 麦克风与系统声音
  → 现有录音库和逐字稿（文字、分段、发言人、原件）
  → 现有 AnalysisResult（来源快照、原文指纹、模板版本、历史）
  → MeetingMinutes 扩展（议题 / 术语 / 因果）
  → 同一个阅读模型 → 三端界面 / 搜索 / Markdown、HTML、Word、PDF
实时确定句段 → 有界串行整理调度 → 速记结果 → 正式转写后最终结果
Mac 按住说话 → 独立翻译/合成会话 → 已验证的虚拟音频设备
```

### 共用数据，不另建会议资料库

[MeetingMinutes](../../lib/state/meeting_minutes.dart) 的 `topics: List<MinuteItem>` 保持可读取。第一批采用向后兼容的可选扩展：议题条目保留 `text/sources`，新增 `summary` 和 `points`，可选 `fishbone`；新增 `terms`。旧条目没有扩展字段时按原来的平面条目展示。新内容写入同一 `AnalysisResult.text` JSON，不新增第二份摘要数据库。

确定类型契约：新增 `MinuteTopic extends MinuteItem`，承载 summary/points/fishbone。`MeetingMinutes.topics` 保持 `List<MinuteItem>` 及现有 const 构造兼容；旧调用仍是普通 MinuteItem，新 JSON 解析为 MinuteTopic。新增结构化展示只对 MinuteTopic 展开，旧条目原样展示。MinuteTopic 覆写 toJson，replaceTerm 用类型分派保留扩展，不把子类型压平成 MinuteItem。

规范化形状：

- 议题：`text` 是标题、`sources` 是本议题依据，`summary` 是一句概括，`points` 为 `{text,sources}` 数组。
- 因果：`fishbone: {question, branches:[{text,detail,sources}]}`；仅有一个分支也可显示为原因列表，两项以上才画图。不强制模型凑足分支。
- 术语：`{name,note,heard:[...],sources:[...]}`。`heard` 必须在引用的来源快照实际出现；不接受模型虚构变体。解释只能依据本场信息；无法确定时表述为待确认，不通过外部常识断言身份。
- 来源仍为 `S1` 等局部编号，范围限定在该 `AnalysisResult.sources`。新嵌套项复用与现有条目相同的非空、编号范围和去重校验。
- 格式版本在 JSON 新增 `schemaVersion:2`；缺失按旧格式。未知未来版本由解析器抛出不支持版本错误，现有界面显示不可结构化编辑的提示并保留原始结果与导出原始文字入口；不新造另一套阅读器，不在读回时降级覆盖。

兼容矩阵：无版本或整数 1 仅允许旧平面形状，输出省略 schemaVersion，编辑仍保持旧形状；整数 2 允许平面条目与结构化 MinuteTopic 混用，输出显式 2，即使扩展为空仍保留 2。非整数、其他版本拒绝。旧构造新增 schemaVersion 默认 1；含 MinuteTopic 或 terms 时 toJson 自动写 2。v1 带新扩展拒绝而非静默丢弃。v2 terms 缺失等同 []；条目出现 summary/points/fishbone 任一键即按 MinuteTopic 解析，summary 必须非空字符串、points 必须数组（可空）、fishbone 可缺失或 null；存在 fishbone 时 question 必须非空，branches 必须非空合法数组。术语 name/note 非空，heard 可缺失等同 []，sources 非空。现有 title/overview/四类数组规则不变。

A1 编辑范围固定：仍编辑原有标题、概览、各条目文字及待办负责人/期限；结构化议题在此界面只编辑标题，summary/points/fishbone 和全部 terms 只读透传。保存必须保留子类型、schemaVersion 和所有嵌套字段/出处；新增字段的逐项编辑不属于 A1，用户可用已有词条替换纠词。未知版本界面提供复制原始结果按钮，不经过结构化解析再编码。

解析 API 确定为 `MeetingMinutes.parse(String text, int sourceCount, {List<String>? sourceTexts})`；旧格式无需 sourceTexts。新格式含非空 heard 时必须提供 sourceTexts 且数量等于 sourceCount，逐项验证变体确实出现在其 sources 指向的文字内，否则 FormatException。`validateMinutes(text, sources)` 始终传 sourceTexts:sources；所有 UI、搜索、导出、替换和恢复解析点已持有 AnalysisResult，统一传入 result.sources，不能仅凭数量验证 heard。

源文本、模型返回、导入文件都视为不可信输入。限制议题 100 项、每议题要点 100 项、每图分支 30 项、术语 200 项；单字段不超过 20,000 字符、heard 不超过 30 项。超限/错误类型拒绝这次新结果并保留旧版，不静默截断成“成功”。这些是应用防护上限，不是要求模型生成的数量。

### 时码和证据

当前 [minutes_panel.dart](../../lib/ui/widgets/minutes_panel.dart) 由 `sourceHash` 一致、`transcriptSegmentsMatchText`、`transcriptSegmentsLocatable` 和 `matchTranscriptSources` 建立回听映射。新议题与因果分支沿用这条验证链；不信任模型返回的秒数。当前映射只有来源开始位置，首批显示最早可靠出处位置及各出处开始时间，不推断议题结束时间；无映射则不显示时间。全局整理不另外引入未经验证的 `sourceAnchors` 字段。

原文发生变更后旧纪要继续可读但标过期，旧时间不再可点击。只有重新生成或既有可靠的同步订正流程建立匹配后恢复跳转。编号合法只证明结构正确；语义支持由质量用例和人工对照验证，不声称解析器能证明忠实性。

### 术语与检索

模型的 terms 是本场候选，不自动修改正文，不自动加入全局词表。术语卡可查看来源、仅加入词表、或明确采纳替换。首批替换复用 `replaceTermInRecording`，但先在内存生成完整候选纪要及候选 sources，剔除失效 heard，完成校验后才改逐字稿。校验失败不写任何正文或纪要。现有多文件持久化不是跨文件原子事务：后续 I/O 失败保留错误和旧纪要，旧 sourceHash 使旧纪要过期、禁用跳转，不能伪报全部成功；用户可按旧版本恢复并重新执行。A2 只在完整写入成功后记录采纳状态。

全库检索仍优先订正后正文，延续“不搜索被覆盖旧词”的契约。新增名称检索可以通过本场候选的来源编号定位仍实际存在的误识别句；界面标明“术语关联命中”，不能冒充正文命中。当前版本的 heard 仅表示当前来源仍存在的变体，不作为历史凭证。用户采纳替换后，移除不再出现于该术语引用来源中的 heard，不把旧错词改写成新的“误识别”；原始 heard 与旧 sources 留在现有不可变版本历史里。术语卡的历史入口打开该旧版，不复制第二份来源库。heard 始终不进入普通全库关键词索引。正确名称没有原文证据时只命中术语卡，不伪造句段跳转。候选与已采纳状态由 A2 的明确用户操作持久化，不从候选展示或模型输出推断。

### 实时任务与费用

B1 使用“确定句段”快照，不把会反复修订的半句话送入整理。首次至少 200 字或 30 秒有效内容后请求；之后至少增加 200 字且距上次开始 30 秒才请求。最多一个正在请求和一个最新待处理快照，旧待处理快照合并，不无限排队。每小时最多 120 次实际提供方增量请求；单次 runLiveRevision 只发一次提供方调用，不走全文分段/合并。会后完整版单独展示预估并走原有完整任务；界面可关闭实时整理。

每次持久化会话 ID、输入修订号、来源快照、模型/模板指纹、任务状态和结果指纹后才发请求。返回只更新相同会话且输入修订未被更新结果取代的版本。网络失败展示原因、保留上次版；请求结果未知不自动重发。重启后的历史音频走会后处理，不伪装成继续实时。现有 `RecordingAnalysis.run` 按整段 sourceHash 清 checkpoint，不能直接当作增量任务使用。新增独立 `runLiveRevision` 入口：任务键为 sessionId/revision，持久化不可变来源快照及 watermark；请求只包含上次经验证纪要（上限 12,000 字符）和新增来源（每批上限 12,000 字符），局部编号由会话已接受顺序单调分配且永不重编号。新增过多时按顺序分批，不丢句；上版纪要超过限额时暂停实时整理，明确提示会后生成完整版，不静默裁掉旧结论。来源全集保留本机用于验证返回编号；只有请求内新增来源或上版已引用的来源可进入新版。先前确定句段被识别器修订时标记速记过期并暂停增量，等待会后完整转写，不用新文字冒用旧来源身份。会后正式整理仍走现有完整流程，其 S 编号属于新 AnalysisResult，不与速记混用。

用户开始编辑速记版时即暂停实时整理，取消当前请求代际，迟到结果不替换当前版。手改成为活动版；恢复按钮明确创建新的机器候选版本，机器增量仍以上一机器结果为基线，候选只进入历史，用户主动切换才成为活动版；首版不做自动合并。会后完整版遵守同一保护。音频采集与纪要任务独立。当前只留本机时，字幕转写也不得回退云端音频；文字翻译和纪要继续遵循现有文字服务设置。断网不结束本地录音。

### 字幕、语言与收尾

已有 Apple live session 返回译文时，字幕只适配和呈现，不再发翻译请求；只有未带译文的输入进入共用翻译调度器，该调度器唯一负责其排队、取消与重试。B2 在应用内共用双语句段列表；Mac 原生窗口仅负责呈现和快捷键，不复制识别模型。确定句段异步翻译，保留原文、译文、语种、提供方与修订号，迟到译文不能覆盖新句。系统已报告语种时使用该结果；未报告时先用所选语种，不伪称自动检测。自动语种检测能力必须通过独立服务/本机能力验证后开启。

Mac 字幕有纪要窗口、字幕条、隐藏三个状态；鼠标经过字幕区域降低不透明度并确保不截获底下操作。Apple 官方将 NSWindow.SharingType.none 标为系统不再使用的旧常量；不据此承诺所有共享和截图不可见。保留 best-effort 属性、一键隐藏与按具体会议软件窗口分享排除；真机分别核对窗口分享和全屏分享。快捷键冲突复用现有报告方式。

启用新自动收尾的绑定会话由 meeting_end_watch 唯一负责结束提示与停止，旧 MeetingAppWatch 仅保留开录提示及未启用新收尾时的原行为；共用三态检测，不运行两套结束计时器。自动结束默认关闭，仅适用于用户启用且绑定单一会议应用的当前 Mac 会议，不用于手机或普通录音豆会话。麦克风检测协议扩展为 active/inactive/unavailable，查询失败必须为 unavailable；连续 30 秒 inactive 才触发 60 秒可取消倒计时，设备切换期间重置观察，多个会议应用不推断归属。输入使用结束仅作为结束提示信号，不能宣称精确知道会议已挂断。静默触发器仅在可靠音频活动检测可用时启用：取麦克风与系统路两者人声活动的并集；检测不可用则禁用该触发器，不用无转写结果替代静默。连续十分钟无检测人声触发同样倒计时；用户取消本次倒计时后需新的人声活动再允许静默触发。检测来源不可用时关闭自动结束，不将“没有识别结果”当作“没有声音”。自动结束调用正常停止保存流程，不删除原件尾部；导出可用逻辑结束位置裁掉展示空白。普通录音豆录音不因电脑会议应用状态停止。

### 同传隔离与服务

复用现有 Core Audio process tap；自身 process object 解析失败时禁止向虚拟设备播音，不回落为空排除列表。真实麦克风按 UID 绑定，不跟随系统默认输入切到 BlackHole。BlackHole 2ch 从官方入口由系统 Installer 安装，不打包驱动、不新增特权 helper、不在录音时重启 coreaudiod。默认让会议软件选择输入，显式自动切换开关使用持久设备租约：先记录原/目标 UID，再切换并读回验证；关闭/重启只在仍持有目标时恢复，设备消失则由用户选择真实设备。

C1 默认复用本机/已有授权识别与文字翻译；系统 TTS 使用 AVSpeechSynthesizer.write(_:toBufferCallback:) 取得 PCM，交 AVAudioEngine/AVAudioPlayerNode，输出 AudioUnit 定向到用户选择的虚拟设备，不改默认扬声器。该 API 有官方证据，真实路由仍需签名安装版验证。默认沿用 Carbon 组合键并补 pressed/released 成对事件，不强求右 Option 或 Input Monitoring。按住会话有唯一 generation，松开只完成当前会话，取消使所有迟到结果失效。本批按住同传一次只处理一句，忙时拒绝新句；详细实现以[Mac 同传设计](mac-interpreting.md)为准。

C2 选择可选 Ming 无状态 reference TTS，不新增 voice ID/训练任务。POST /v1/audio/speech，模型 Ming-3.0-tts-0.5B，PCM 24000 Hz；普通声传 voice，克隆传 references（WAV data URI 与参考文本，编码音频不超过 10 MB）。SSE speech.audio.delta 的 Base64 音频必须跨网络块缓冲解析，speech.audio.done 才完成；奇数字节 PCM 留待后块。用户本人 8–30 秒样本明确启用后上传，每次请求前落盘状态；未知付费请求不重发。样本不进资料包、归档、日志或备份，删除立即停用。云合成尚未播放字节时可退回系统 TTS，播放一半失败只提示不从头重读；未配置云服务不阻塞普通声音。

## Alternatives Considered

- 三端强制相同音频入口：界面一致，但手机系统不支持任意应用录音/路由，维护和可靠性代价过高。按用户批准的边界不采用。
- 复制 Cicada 的 Swift 应用到 Koe：Mac 起步快，但形成第二份记录与纪要实现，手机难以共享。选择复用 Koe Flutter 数据与服务，只新增必要原生桥接。
- 立即重建全套离线识别和声纹：能减少云端依赖，但扩大模型、下载、内存和许可验证范围。保留已有本地能力及既有暂缓安排；为 C0 确认的具体缺口单独排期。
- 让模型直接纠正文稿：少一次点击，但会把猜测变成用户原文并破坏来源。采用候选、采纳和可恢复变更。
- 实时每句请求完整历史：实现直观，但请求与费用无界、旧结果易覆盖新结果。采用有界调度与现有分段整理。

## Non-Functional Requirements

- 原件和手改内容优先于派生结果；格式失败不清空旧版。新增字段在所有导出、复制、编辑、替换、搜索、历史恢复中保持含义，不仅在主界面可见。
- 真实 API 只使用已授权测试音频和既有安全配置；开发测试隔离凭据，不读个人 Keychain，不打印秘密。
- 同传开启/取消和字幕更新不能阻塞录音保存。新增音频链路需跑项目性能场景，报告目标版本数字。
- 新功能可关闭；不迁移或重写整个资料库。旧程序读取新格式可能丢弃扩展字段，因此降级安装前保留完整资料备份并禁止旧程序编辑新纪要；不能宣称任意旧版本无损往返。
- 质量评估至少包括中文两人会议、四人会议、抢话、专有名词、没有决定的讨论和纯文字导入六类。记录决定/待办遗漏、负责人/期限误写、错误因果、来源可定位率及耗时；没有同音频对照前不宣称优于 Cicada。

## Open Questions and Investigation Gates

产品边界已确定，无需用户再选择。以下由工程调查解决，并各有明确后续出口：

1. C0：虚拟路由、系统 TTS PCM、无回声采集和输入恢复实测；不能验证则 C1 真实可用状态保持未验收，继续 A/B，不伪报同传完成。
2. C2：Ming 官方接口已有证据，需实测模型可用性、SSE 音频、声音质量和收费；无可用凭据时保留系统声音，将真实服务验收标未执行。
3. B2：系统语种检测和共享屏幕排除的版本差异；能力检测返回具体原因，最低系统仍可用会后功能。
4. A3：真实会议基准需可用且已授权的音频；无授权数据时先用公开许可样例，私人录音不自行上传。

### Additional Resources

- [当前纪要模型](../../lib/state/meeting_minutes.dart)
- [分析服务与结果](../../lib/state/recording_analysis.dart)
- [纪要界面与回听验证](../../lib/ui/widgets/minutes_panel.dart)
- [Mac 双路录音适配](../../lib/platform/mac_dual_recorder.dart)
- [既有产品决定](../../docs/adr/0002-meeting-notes-decisions.md)
- [平台 API 与服务协议证据](本节列明的官方协议与源码调查)
- [Cicada 固定版本说明](https://github.com/wquguru/cicada/blob/38771f1a5ae691c848ea429f4a870defd92d9d26/README.md)
- [Cicada 纪要模型](https://github.com/wquguru/cicada/blob/38771f1a5ae691c848ea429f4a870defd92d9d26/Sources/LiveSubs/Notes.swift)
- [Cicada 纪要界面](https://github.com/wquguru/cicada/blob/38771f1a5ae691c848ea429f4a870defd92d9d26/Sources/LiveSubs/NotesViews.swift)

### 资料包交换与术语采纳（A1b/A2）

资料包的版本、白名单与冲突规则以 [material-pack](../material-pack.md) 为准。没有音频时，纪要和历史仅存在 `MinutesDocument.restore`，界面只读显示；补配同 SHA-256 原件并成功恢复后才移除占位文档。仅有纪要而无完整逐字稿时，把来源明确标为“纪要原文快照”，不据此恢复按句回听。

资料包合并不覆盖本机当前纪要。历史按规范化内容去重，稳定排序并裁剪，给不同的外来当前版保留一个候选位置；同包连续导入及重启再导入不轮换历史。包内历史上限10，本机上限沿用30。缺失原件只以不覆盖目标的原子发布方式补回，不覆盖并行出现的新文件。

`MinuteTerm.adoption` 保存 `kind`（`vocabulary` / `replaced`）、`at`、`previousVersion`。凭证摘要由规范化纪要正文、sources 和 sourceHash 共同生成，换设备后仍可找到采纳前的历史；历史被裁掉则明确说明，不拿当前正文冒充。模型输出和生成缓存进入保存前剥离 adoption，本地编辑及资料包保留该记录。

术语卡提供“仅加入词表”和“订正本场原文”。确认框列出名称、识别写法与实际命中次数，范围只限本场；多种写法长词优先、单次映射，替换结果不再递归替换，发言人姓名同步处理。词表名称须为1–40字；新增/删除意图在同一设置队列轮到执行时合并最近成功保存的词表，不丢失其它录音同时采纳的词。

纪要更新使用带所有者 token 的占槽，跨异步步骤验证所有权；移入回收站会撤销旧 token，旧任务收尾不能释放后来新任务的槽。整个 analysis store 的候选构造、保存和回滚串行，普通保存也在执行时才抓取整库快照，避免其它录音保存失败结果。术语采纳在队列轮到执行以及纪要落盘后再次核对当前原文摘要；期间原文变化则回滚采纳状态并纠正磁盘，不误报成功。正文采用写前核对和失败条件回滚，出现并行新编辑时保留新正文。正文、词表、纪要仍非跨文件原子事务：后续失败提示未完成或部分已保存，不伪报全部成功。

正确名称先查当前正文；没有直接命中时，只有当前纪要原文指纹吻合才关联仍存在的识别写法，明确显示“术语关联”。历史错词不加入普通索引；原件或时码不可靠时不提供跳转。真实分享、导入、安装升级、三端回听和内容质量仍由 #514 验收。

## Detailed Implementation Plan

### A1：可独立交付的会后纪要结构

修改以下文件，不改采集、云端凭据和原始音频：

1. `lib/state/meeting_minutes.dart`：新增 `MinuteTopic extends MinuteItem`、`MinuteFishbone/MinuteCause`、`MinuteTerm` 值类型；解析旧形状、验证新形状、完整编码；新字段进入 replaceTerm、searchableLines、export；修改提示词构造和回答修订提示词以保留扩展。采用上述确定的子类型契约，保留 topics 的旧 List<MinuteItem> 入参和 const 构造；普通条目不携带议题字段。所有 parse 调用对新格式传 sourceTexts，validateMinutes 始终作实际来源校验。
2. `lib/state/recording_analysis.dart`：五种内置会议提示词同步使用新结构，提升内置模板版本；保留旧模板及用户自定义模板的原始内容。验证回调仍在结果持久成功前运行，会议 minutes slot 的每个片段、每轮合并、最终结果都产出完整 v2 JSON（空类别用空数组），取消此路径的固定1500字要求；其他分析任务保留原行为。每个 node 在写 checkpoint 前调用同一 validateResult，并检查嵌套 sources 仅引用当前输入允许的全局 S 编号；叶片允许自己的 S 编号，合并允许参与子结果已引用编号的并集，绝不重编号。heard 保持引用原文实际形式。缓存节点也重新校验，不复用不合法节点；校验失败保留既有完成纪要。新增 test/minutes_chunk_merge_test.dart 用至少4段触发两层合并，验证嵌套要点/术语/原因及编号传到后层、非法中间JSON/跨片段编号被拒且不覆盖旧版。
3. `lib/ui/widgets/minutes_panel.dart`：议题层次、术语候选、原因分支只读展示；复用 sourceMatches 回听；编辑器保存新字段，旧版编辑不凭空补造结构。拆出的展示组件放在新增 `lib/ui/widgets/minutes_topic_card.dart`、`lib/ui/widgets/minutes_terms.dart`，主文件负责控制器接线。
4. 新增 `lib/ui/widgets/minutes_fishbone.dart`：小屏为原因列表，宽屏为因果图；同一数据、相同出处按钮，读屏按问题、原因顺序。
5. `lib/state/minutes_export.dart`：HTML/Word/PDF 保留议题概括、要点、原因和术语；图无法渲染时输出结构化文本，不能静默丢分支。所有模型文本 HTML/XML 转义。
6. `lib/ui/widgets/minutes_mind_map.dart`：保留现有章节图；议题下纳入关键点，因果图独立且不把归类关系画成因果。
7. `lib/state/recorder_controller.dart`：替换前内存构造并校验候选，过滤不再有当前来源的 heard；失败不写正文，I/O 部分失败按过期纪要显示，不返回全部成功。所有 MeetingMinutes 构造/替换/检索调用使用新模型；不新增第二套存储。原有 sourceHash 和版本保护不变。
8. `test/meeting_minutes_test.dart`、`test/meeting_templates_and_backends_test.dart`、`test/minutes_export_and_subtitles_test.dart`、`test/minutes_mind_map_test.dart`：先加改前失败的嵌套信息完整往返、非法编号、导出不漏内容和旧格式用例，再实现；避免断言提示词源码字符串。
9. 新增 `test/minutes_structure_test.dart` 验证兼容矩阵、验证失败保留旧结果和当前/历史版本往返；扩展 `test/search_and_global_replace_test.dart` 验证替换前候选校验失败时逐字稿/纪要/词表不变，纪要持久化失败时正文新值保留但旧纪要过期、操作抛错，heard 过滤而旧历史完整。现有资料包测试只作不改行为回归，新纪要包往返由 A1b 负责。新增 `test/minutes_topic_panel_test.dart`：真实 widget 行为验证嵌套展示、出处点击、过期来源不可回听、小屏无溢出；打开 v2 仅改标题保存再打开，summary/points/fishbone/terms/schemaVersion/出处不变，旧版编辑仍保持旧形状。
10. `ROADMAP.md`、`progress/progress.json` 与生成的 `progress/index.html`：只按本次真实完成状态登记 A1，不能将全量目标标完成；正式设计落到 `docs/design/cicada-alignment.md`，草稿报告留 `.scratch`。

A1 完成条件：旧纪要阅读和编辑不丢原字段；新结果读取、显示、复制、四种纪要导出、替换、本机历史恢复均保留扩展；格式拒绝仍保留旧结果。现有 `lib/state/recorder/material_pack.dart` / `lib/state/material_pack.dart` 不保存分析结果，A1 不修改其格式且回归已有资料包测试，不宣称纪要可经资料包转移。A1b 是独立后续工单，在新格式、导入去重/冲突、本机分析键重映射及历史范围设计完成后才实现。

### A1b：资料包携带纪要（后续设计工单）

修改 lib/state/material_pack.dart、lib/state/recorder/material_pack.dart、lib/state/recording_analysis.dart、docs/material-pack.md 和 test/material_pack_test.dart。先明确新 manifest 版本、当前纪要与最多10版历史的白名单字段、导入源 hash 对齐、同音频不同正文冲突、重复导入去重、不带音频时的阅读与配对恢复。实现遵循上文 A1b/A2 契约，控制器导出再导入、无音频只读阅读和配对恢复均有行为回归；跨端真实文件交换在 #514 独立验收。

### A2：术语候选采纳与来源检索

依赖 A1。修改 `lib/state/meeting_minutes.dart` 加候选状态和来源定位规则；`lib/state/recorder_controller.dart` 接入现有 `replaceTermInRecording`，仅通过用户动作采纳；`lib/ui/widgets/minutes_terms.dart` 加查看影响、仅入词表与采纳动作；`lib/ui/transcript_layout.dart` 为 TranscriptSearchHit 增加命中类别和术语来源目标，`lib/ui/screens/files_screen.dart` 使用类别显示“术语关联命中”，`lib/ui/screens/recording_detail_screen.dart` 接对应来源跳转。新增 `test/minutes_terms_test.dart`，扩展 `test/search_and_global_replace_test.dart` 和 `test/minutes_quality_and_glossary_test.dart`：正确名称找到未采纳错写原句，采纳后旧词不重新命中普通搜索，撤销和重启保留状态，来源变更禁用旧定位。

### B1：有界实时纪要

新增 `lib/state/live_minutes.dart`（调度、修订与状态机）和 `lib/state/recorder/live_minutes.dart`（控制器 mixin）；新增 `lib/state/live_minutes_store.dart` 用现有 atomic_file 写会话 revision/watermark/付费请求状态，不复制原件；修改 `lib/state/recorder_controller.dart` 的 part/构造/清理接线、`lib/state/recorder/live_transcription.dart` 与 `lib/state/recorder/phone_recording.dart` 的确定句段/停止事件；修改 `lib/state/recording_analysis.dart` 增加上述 runLiveRevision 有界请求入口并复用提供方调用，不复用整 sourceHash 的清理决策；`lib/state/app_settings_store.dart`、`lib/state/recorder/settings.dart`、`lib/ui/screens/settings_screen.dart` 加实时整理开关。新增 `test/live_minutes_test.dart`，用可控时钟和 Completer 验证有界队列、迟到结果、手改保护、重启未知请求不重发；扩展既有 recording_analysis_recovery 与 phone_recording 用例。新增实时显示组件 `lib/ui/widgets/live_minutes_panel.dart`，在现有录音界面接线。Mac 当前 `MacDualRecorder` 丢弃 native final 标志且只输出扁平 text：修改 `macos/Runner/DualRecordingBridge.swift` 为事件带 session/lane/requestId/offset/final，修改 `lib/platform/mac_dual_recorder.dart` 和 `lib/platform/dual_recording_text.dart` 保留确定段集合并暴露只读流，部分结果只显示不进入整理。稳定键为会话+lane+requestId，不以文本哈希或单独 offset 识别同一句。新增 `test/dual_recording_final_segments_test.dart` 验证部分到最终、迟到旧会话、双路顺序和 final 修订，已有 `.dual.txt` 仍是可读导出，实时恢复状态使用独立上述 store。

### B2：字幕与收尾

新增 `lib/state/live_captions.dart`（确定句段翻译、语言能力与修订）、`lib/ui/widgets/live_captions_panel.dart`（三端应用内列表）、`lib/platform/mac_captions.dart`（Mac 方法通道）、`macos/Runner/CaptionsPanel.swift`（原生浮窗）；修改 `lib/ui/mac_menu_bar.dart`、`macos/Runner/AppDelegate.swift`、`macos/Runner/GlobalHotKeys.swift`、`macos/Runner.xcodeproj/project.pbxproj` 以注册窗口和快捷键。修改 `macos/Runner/MicrophoneUsers.swift` 区分 unavailable 和 inactive，`lib/state/meeting_apps.dart` 与 `lib/platform/mac_app.dart` 的 microphoneUsers 通道解码承载三态检测、绑定应用和 30 秒观察窗；新增 `lib/state/meeting_end_watch.dart` 明确人声活动、倒计时、取消和正常停止；收尾接 `lib/state/recorder/phone_recording.dart`，不触碰录音豆实体录制。翻译调用复用 `lib/ai/apple_speech.dart` 和现有分析服务；需新能力时先做平台能力调查并更新工单，不猜测 API。新增 captions/end_watch 行为测试，扩展 mac_menu_bar 测试。系统版本能力、真实分享隐藏和麦克风冲突单独设备工单。

### C1/C2：按已核实接口实施，真实路由独立验收

C0/C1/C2 统一交付门槛：C0 的文档与协议调查已经有 本节列明的官方协议与源码调查 支撑；C1/C2 代码接线和替身测试可推进，实际音频路由、声音品质及真实服务成功由独立设备工单验收，不反向闸住代码合并，也不把合并等同实测通过。

隔离音频实验属于后续设备验收，不作为开始编写原生接线和替身测试的阻塞条件。

C0 的官方文档调查已形成平台证据；剩下可重放隔离实验：普通 TTS 音频进入虚拟输入、会议应用接收到、无自身反馈、取消静音和设备选择恢复。报告放 `.scratch`，稳定结论进入正式设计/工单。调查不安装驱动或改变当前设备，实际安装与路由在对应设备验收执行。

C1 的文件、通道、采集/TTS格式、单句策略与测试由[Mac 同传详细设计](mac-interpreting.md)替代本段旧契约。采集复用16kHz Float32，系统TTS在原生侧保留实际格式，Dart不传PCM。C2云TTS的24kHz契约不改变。

C2 新增 `lib/ai/ming_tts.dart`（请求与 SSE）、`lib/state/voice_sample_store.dart`（样本元数据与独立文件）、`lib/ui/widgets/voice_sample_settings.dart`、`test/ming_tts_test.dart`、`test/voice_sample_store_test.dart`；修改 `lib/state/app_settings_store.dart` 仅存非秘密选择，密钥用既有 credential_store 入口，settings_screen 接线。样本存应用私人目录下 voice-samples，平台标记不备份，资料包/归档白名单不得包含；删样本前先停止当前克隆并取消关联队列，文件删除失败显示原因且不重新启用。测试覆盖切片 SSE、超限请求、取消迟到音频、零字节回退、部分播音不重读、删除/重启和秘密不进设置。真实服务与设备工单独立。

### Verification and Delivery

- 每项新增行为测试必须在实现前失败；运行受影响测试后执行 `check`，保存提交、退出码、测试数量与未覆盖项。不改源码的设计工单只核对链接与一致性。
- A1/A2 检索或 JSON 存储变化按项目要求跑一次 `scripts/perf-check`；无窗口/设备时明确跳过，不宣称通过。
- 真实验收独立建工单：三端新纪要显示与导出；真实千问新结构；同音频与 Cicada 对照；实时长会议/断网/终止；Mac 同传回路/设备恢复/克隆生命周期。代码过审先合并，不用尚未执行的真机项冒充完成。
- 一个子工单一个 PR；共享模型和导出不并行写。A1 合并后才接 A2/B1；B1 与 C0 可并行调查，但不同时改相同文件。
- 每次提交和 PR 写回退测试、真实使用、未跑项。progress 同源 render/check；合并前核对远端事实，保留全量目标剩余项。

*Drafted with EGM*

## 平台协议来源

- [Apple 合成 PCM](https://developer.apple.com/documentation/avfaudio/avspeechsynthesizer/write(_:tobuffercallback:))
- [Apple 窗口共享标记限制](https://developer.apple.com/documentation/appkit/nswindow/sharingtype-swift.enum)
- [BlackHole 官方安装](https://github.com/ExistentialAudio/BlackHole/wiki/Installation)
- [Ming TTS 官方协议](https://developer.ant-ling.com/en/docs/api-reference/audio/tts)
