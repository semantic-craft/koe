# 项目教训

实现、评审或验收前阅读相关条目；用户纠正、返工或漏验暴露可复用教训后补记。
已有教训如下；后续沿用文末模板补记。三条同一教训将按 [AGENTS.md](AGENTS.md) 升级为交付硬规则。

### 系统凭据只允许授权一次，且开发构建不得触达个人凭据

**开发与验证构建默认隔离系统凭据，交付构建用稳定签名交付；验收必须包含真实安装升级后的一次读取。**

- 起因与后果：2026-10-16 用户截图显示安装版因签名标识随构建变化反复索取登录钥匙串密码；同一轮复验还发现 Debug/验证构建缺少启动变量时会回退读取个人 Keychain，用户只看到“又弹窗”，无法判断是开发还是安装问题。实测 kSecUseAuthenticationUIFail 对旧条目的 ACL 弹窗无效（阻塞 ≥8 秒），而 SecKeychainSetUserInteractionAllowed(false) 在同一场景 0.06 秒返回 errSecAuthFailed 且无弹窗。
- 修复与证据：darwin/KeychainStore.swift 增加 isolated/system 模式，macOS Debug 与任何 KOE_CREDENTIAL_SOURCE 取值一律隔离，Release 用 SecCodeCheckValidity 校验团队与 bundle 要求后才走系统存储；scripts/sign-macos.sh 只接受唯一 Developer ID 证书、无 ad-hoc 回退并内外层签名后验证指定要求；scripts/install-macos.sh 复用该签名器并比较升级前后的指定要求，脚本失效时不会静默成功。skills/verify-koe/scripts/check.py 的 native 模式用两个内容不同（SHA-256 不同）的 Developer ID 构建共享一条合成条目、ad-hoc 对照必须在 0.06 秒内失败且不拉起 SecurityAgent；isolated-app 模式跑真实 App 并要求 securityCalls=0。真实升级：原安装 68f30bf6… 换成本次构建 6179d37c…，指定要求不变，安装后启动设置页仍显示“通义 Qwen 使用中”，全程无授权弹窗（证据在 build/verify-koe/）。
- 正确做法（Done right）：新增或改动签名、安装脚本、系统凭据读写时，先跑 check.py doctor 记录指定要求与 CDHash，再跑 native + isolated-app，最后按 skills/verify-koe/features/signed-install-upgrade.md 做真实安装升级读取；签名校验、同一构建重启、模拟通道各自只作证一层。开发与验证构建不得回退到个人凭据，也不得放开交互开关绕过。上层规则见 WORKING_STANDARDS.md“工程与验证”。
- 复发记录：Seen 2x (2026-10-16)；同日两起独立事件：#41 复验发现 ad-hoc 签名的 ACL 绑定旧 CDHash（见 docs/credential-storage-validation.md），随后发现验证程序默认回退个人钥匙串并留下弹窗。

## 记录模板

复制下列模板新增条目，已有同类条目则更新原条。未知的提交、原因或验收结果明确写“待核实”。
同一事件的多次修复、测试重跑不增加复发次数；只统计有独立证据的再次发生。
记录保留可复用的原因与证据定位；凭据、私人资料及完整日志留在各自获准的位置。

```markdown
### <教训标题>

**<一句话说明下次应遵守的规则。>**

- 起因与后果：<触发条件、原因、用户可感知的影响；关联 issue 或引入提交，未知则写待核实。>
- 修复与证据：<修复提交或 PR、回归检查与实际验收证据；区分已验证和未验证的部分。>
- 正确做法（Done right）：<下次的具体做法；链接到防复发代码、检查或所属规范。>
- 复发记录：Seen <N>x (<YYYY-MM-DD, ...>)；<每次独立发生的证据；修复提交数与重试次数不计入。>
```

### 带异步加载的对象要在 runAsync 里构造，不能在 fake zone 建好再等

**widget 测试里，持有真实文件加载或 Future 队列的 store/controller，连同 load/wait 一起放进同一个 `tester.runAsync` 构造。**

- 起因与后果：2026-10-18 #144 WIP `5d1b63c` 的书签界面测试先在 fake zone 构造 `RecordingBookmarkStore` 与控制器，再 `runAsync` 等加载；加载与保存队列的续体排在假时钟里，云端首次运行 630 秒被沙箱终止，本机首条也卡住。
- 修复与证据：本机 Codex 评审给出探针，store、controller 构造与 `waitForBookmarks` 全部移进同一个 `runAsync` 后整文件约 6 秒跑完；之后的真实文件写入用“反复 runAsync 短等 + pump 直到可见结果出现”同步，不靠固定延时判定完成。
- 正确做法（Done right）：构造即启动异步 I/O 的对象在真实 zone 创建并等加载；需要观察写入中途状态时，用可覆写的写入点挂 Completer，而不是改成更长的延时。
- 复发记录：Seen 1x (2026-10-18)。

### compact 日志里缺文件不等于没跑

**判断哪些测试文件执行过，用 expanded 或 json reporter 的输出，不用终端里 compact reporter 留下的日志。**

- 起因与后果：2026-10-16 PR #61（2e33029）本机全量 `flutter test` 日志里，当时 44 个文件只看得到 20 个，24 个被当成漏跑（#66 按现在的 45 个算，写成 25 个）。实际是显示问题：在终端（pty）里默认用 compact reporter，它每条进度都用 `\r` 原地重画同一行，只有测试 `print` 了内容时当前行才被换行保留；`ios_koe_identity_test.dart` 等不打印的文件，进度行全被后面的行盖掉。最后的 `+314` 是全部文件的累计数，正好等于 json reporter 统计的 44 个文件用例之和（Linux 上 macOS 专属的 2 条为跳过，Helios 上会执行）。
- 修复与证据：未改测试与配置（dart_test.yaml 不存在，pubspec.yaml 无测试配置，文件命名、位置、`main()` 均正常）。在 Linux 沙箱用 Flutter 3.47.7 于 2e33029 复现：`script -qfc "flutter test"` 按终端语义渲染后正好剩 20 个文件，原始字节里 44 个都在；`--reporter expanded` 不用 `\r`，45 个文件（当前 main）逐行可见；json reporter 核对 45 / 45、缺失为空。
- 正确做法（Done right）：需要逐文件证据时用 `flutter test --reporter expanded`；核对执行到的文件集合与 `test/**/*_test.dart` 是否一致，用：
  `flutter test --reporter json > /tmp/koe-test.json; python3 -c "import json,glob,os;s={os.path.relpath(json.loads(l)['suite']['path'],os.getcwd())[5:] for l in open('/tmp/koe-test.json') if '\"type\":\"suite\"' in l};a={p[5:] for p in glob.glob('test/**/*_test.dart',recursive=True)};m=sorted(a-s);print(len(s),'/',len(a),'missing:',m);exit(1 if m else 0)"`
  （缺失时非零退出。）截取日志末尾作证据时，同样只能证明末尾那几个文件。
- 复发记录：Seen 1x (2026-10-16)。

### 逐像素对照才能抓住主题构造形态差异

**重构主题时"字段值相同"不等于"ThemeData 相同"；视觉回归必须逐像素对照。**

- 起因与后果：2026-10-15 挑回 87d5d8c token 层时，把 `const ColorScheme.light(...)` 换成 `ColorScheme.light().copyWith(...)`，抽查字段（surface/primary/onSurface/outline）全等，但无参 `ColorScheme.light()` 在当前 Flutter 版本会留下一批 NULL 字段，设置页文字变纯黑、下拉与分隔线偏色；字节级对比 9/14 张截图全同的假象下 5 张已偏。
- 修复与证据：改回全参构造、经 token 取值；`build/ui-evidence/spec-06/` 下 14 张 before/after 截图逐像素全同（`flutter test --dart-define=RECORDING_PREVIEW_DIR` 抓图 + 逐字节 RGBA 对照）。
- 正确做法（Done right）：主题重构以截图基线先行；对照要像素级而非抽查字段，构造器形态（无参 vs 全参、const 与否）本身是行为面。
- 复发记录：Seen 1x (2026-10-15)。

### 并排工作区需要独立的导航语义边界

**嵌套 Navigator 与可交互侧栏并排时，必须验证路由外的控件仍在语义树中。**

- 起因与后果：2026-10-15 将录音列表和详情并排后，视觉与点击正常，但详情路由会遮掉左侧语义；单纯布局测试没有覆盖这一点。
- 修复与证据：为 Navigator 增加独立 Semantics 容器，录音行标注 button；`test/recording_detail_test.dart` 的桌面回归检查导航语义仍可见。后续定位剩余桥接错误为 Slider 浮层孤立节点（见下条），原生回归已 0 错误；完整 VoiceOver 尚未人工验收，见 `docs/ui-workspace-validation.md`。
- 正确做法（Done right）：同时验证宽/窄窗口、真实可达导航与 Semantics；widgets 语义通过不等于原生读屏验收。
- 复发记录：Seen 1x (2026-10-15)。

### 第二个同类引擎落地时应收拢机制，而不是再复制一份

**接入与现有引擎同形的新引擎时，先收拢共享机制再接线；复制现有实现的成本（含随后的统一返工）总是被低估。**

- 起因与后果：2026-10-15 接豆包（00be6ef）时按 Qwen 现状复制了一份内存队列（`_pendingDoubao`/`_doubaoStarted`/`_pumpDoubaoJobs`）和一份约 130 行的 `_DoubaoSettings` 表单，当时认为"照抄最快"；22 分钟后 c486ea6 就不得不把两条并行队列（连同 Moss 路径）收拢成单一 `DeferredFileJobs`，两轴评审又以 7 处 provider 分支与重复表单立案，复制体被付费两次。
- 修复与证据：c486ea6 统一延迟文件任务机制（既有用例零修改通过）；本分支 3dd27d2 将控制器 provider 分支收进 per-provider 引擎适配记录、3df423a 把两份云端表单并为一个数据参数化组件，`engine_lineup` 等既有测试零修改全绿。
- 正确做法（Done right）：当第二份同形实现（队列、表单、凭据读写）即将出现时，先抽共享机制/数据参数化，再接新引擎——"新增引擎是数据项而非新界面"应在接入提交里就成立，而不是留给下一次重构；估期时把"复制 + 日后收拢"记为双倍成本。
- 复发记录：Seen 1x (2026-10-15)。

### 孤立语义节点只能靠逐帧更新流回归抓住

**判断原生 AXTree 健康不能只看 settle 后的语义树；必须检查逐帧发送引擎的序列化更新批次。**

- 起因与后果：2026-10-15 录音工作台切路由时 macOS 报 `Failed to update ui::AXTree`（上游 flutter/flutter#190357，Material Slider 数值气泡浮层经全局 Overlay 送出孤立节点）。settle 后的语义树检查通过，问题只存在于过渡帧的更新批次。
- 修复与证据：`lib/ui/widgets/inline_player.dart` 用 `Overlay.wrap` 把滑块浮层限制在自身子树，导航与动画保留。`test/macos_accessibility_update_test.dart` 重载 `createSemanticsUpdateBuilder` 记录每批 updateNode 边并做根可达检查：撤销修复时失败（孤儿 id 60/84/108），恢复后通过；`scripts/check-macos-accessibility.py` 实测 9 步 0 错误（`build/ui-evidence/ax-native.log`）。
- 正确做法（Done right）：涉语义的改动至少覆盖宽/窄窗口、settle 树、逐帧序列化更新与原生读屏四层；前两层通过不代表后两层通过。
- 复发记录：Seen 1x (2026-10-15)。

### 首次配置必须从未配置状态走通

**配置入口不能依赖引擎已启用；组件测试应从没有密钥的用户状态点击进入。**

- 起因与后果：引擎列表阻止选择无密钥服务，而配置表单只显示当前服务，形成首次配置循环（#8）。原测试直接调用控制器选择引擎，绕过了真实入口。
- 修复与证据：未配置卡片打开独立配置窗口；`test/engine_lineup_test.dart` 从空配置点击、填写、保存、启用，再切换另一个引擎。Qwen/豆包入口回归修复前均失败。
- 正确做法（Done right）：覆盖真实导航入口与配置后的启用路径；同类 StatefulWidget 切换实体时使用实体 key，避免表单沿用旧引擎状态。
- 复发记录：Seen 1x (2026-10-15)。

### 内存去重不等于跨进程恢复

**付费任务必须在请求前记录状态，在结果持久保存后再确认完成。**

- 起因与后果：统一 DeferredFileJobs 后 Qwen/豆包的队列与去重集仍仅在内存，重启会丢失任务；设备取回也没有进入同一自动处理入口（#10/#13）。
- 修复与证据：FileJobJournal 保留配置和任务阶段，Qwen 提交编号在查询前落盘；真实临时文件重开、模拟 HTTP、控制器恢复和重复完成通知测试见 `docs/recording-processing-validation.md`。
- 正确做法（Done right）：已知任务编号继续查询；未知提交不自动重做；结果先保存再确认；配置凭据不进入任务文件。单元测试与编译不能替代系统休眠和真实设备验收。
- 复发记录：Seen 1x (2026-10-15)。

### 上传字段测试不能替代真实请求编码验证

**云端文件上传必须检查序列化字节，并至少用授权测试音频完成一次真实服务验收。**

- 起因与后果：2026-10-15，千问单元测试只检查 MultipartRequest 的字段，真实 OSS 却因文件 part 将 Content-Type 放在 Content-Disposition 前而返回 HTTP 400 MalformedPOSTRequest，双端都无法提交任务。
- 修复与证据：专用 OssUploadRequest 调整文件头顺序，保持流式音频和进度；同音频对照仅交换顺序即从 400 变 200。`test/qwen_stt_test.dart` 序列化回归先红后绿；真实双端提交后终止进程、重启、同任务编号完成，见 `docs/recording-processing-validation.md`。
- 正确做法：在实际发送字节层检查文件头、Content-Length 与音频完整性；配置成功、模拟 HTTP 通过与真实上传成功分别验收。不得记录上传凭据或完整请求体。 对长录音还须核对准备阶段与上传阶段是否整份读入内存；流式 multipart 外层不能掩盖先 readAsBytes 的全量缓冲。#23 已改为分块 OGG 封装及磁盘流上传，25 MiB 合成夹具覆盖分块取消，真实短样本验证服务接受。
- 复发记录：Seen 1x (2026-10-15)。

### 手动断开意图不能被一次状态通知消耗

**设备交接必须验证旧端持续离线和新端真实连接，瞬时“已断开”不足以证明释放成功。**

- 起因与后果：2026-10-15，BleService 手动断开重复发送 false，控制器处理第一条后清除意图，第二条触发手机重连，表现为 Mac 扫描找不到设备。
- 修复与证据：源端减少为一次通知，控制器保持会话内断开意图并拦截迟到扫描/定时重连；重复事件回归先红后绿，异常掉线继续重连。同一 Mac 扫描探针从 0 个目标变为 1 个，正式 Mac App 直接取回 30.26 秒录音，见 `docs/recording-processing-validation.md`。
- 正确做法：将用户意图与传输层瞬时状态分别建模；测试重复与迟到事件，并通过两端设备对照验证释放。用户随后明确要求断开意图跨进程保留，因此将意图持久化，覆盖真实文件重开与控制器重建；仅显式连接清除，扫描与快捷录音不得绕过。
- 复发记录：Seen 1x (2026-10-15)。

### 普通配置只要求用户提供账户信息

**服务地址与模型由程序按已批准的方案选择，不把实现参数当作必填配置交给用户。**

- 起因与后果：2026-10-15，云端表单同时展示密钥、服务地址、模型，用户不知道后两项该填什么；首次保存后还需要额外点击完成，设置页的相同表单又造成弹窗没有关闭的误解。
- 修复与证据：豆包仅填写 API Key；千问填写 API Key 和可选 Workspace ID，程序生成专属地址。首次保存自动启用并关闭窗口。`test/engine_lineup_test.dart` 覆盖真实首次入口、字段数量、保存关闭、工作空间地址生成及错误输入不覆盖原配置；真机新版界面验收进行中。
- 正确做法：先确定模型和接口方案，再设计用户必须提供的最少信息。配置成功的反馈和关闭行为应明确；不能依靠用户理解默认 URL、资源 ID 或模型参数。
- 复发记录：Seen 1x (2026-10-15)。

### 暂停不是布尔值，也不是新录音

**设备的停止、录音、暂停三态必须完整传递；续录要验证同一文件的音频增长，而非只验证文字出现。**

- 起因与后果：#22 中设备状态 `2` 被压成 false，控制器又把“开始”当新会话；此前测试甚至将暂停后新建记录当作预期，无法发现真实用户问题。
- 修复与证据：保留 recordingStatus，暂停继续沿用会话、文件和配置；`test/recording_processing_test.dart` 的身份回归先失败后通过。真实 D3200 控制器探针确认同一文件从 38,400 增至 85,440 字节；Mac 千问与 iPhone 豆包双端真实界面均在同一条记录保存两段语音，见 `docs/speech-provider-validation.md`。
- 正确做法：先核对命令、状态通知与文件身份；单元测试不以乐观 UI 状态代替设备语义。停止后新建与暂停后继续分别覆盖。
- 复发记录：Seen 1x (2026-10-15)。

### 只经分支和 PR 交付，只用 squash 合并；不推 main，不把 WIP 带进主线

**所有改动走功能分支 → PR（正文写回退测试、真实使用、没跑到的项目）→ squash 合并；中断的 agent 运行留在分支上，不进 main。**

- 起因与后果：2026-10-15 上午偏离用户「GitHub 只用 squash merge」的规定：#3（7b7c033）和 #17–#20 用 merge commit 合并，把 headless cursor-agent 中断留下的 `c10c5d2 wip(qwen-asr): partial work…` 带进 main 历史；05:24–06:38 的多个本地 `merge:` 提交（2437e61、ccf1147、28da98f、6d1a3b1、b59d365、70f648d 等）和 `ed9ae3f chore` 直接推到 main，没有 PR、评审和验收记录可查。
- 修复与证据：下午 #21、#26、#29 恢复为 squash 合并，PR 正文带 Evidence。历史不改写。同时在 AGENTS.md 加入交付与验收硬规则。
- 正确做法（Done right）：#29（00cdd1b）：功能分支 → PR 列出 261 项全量测试、生产 Qwen3.8-Flash 调用、Mac 与 iPhone 安装版验收和未覆盖项 → squash。
- 复发记录：Seen 1x (2026-10-15)；同日 Remora 出现同类问题，在该仓库单独记录。


### 安全存储迁移要覆盖写后校验失败与读取重试

**原生写入成功不代表整个保存成功；迁移失败必须有可达的重读入口。**

- 起因与后果：#9 补丁审查发现，写后 readback 在回滚范围外，校验暂时失败会使内存和 Keychain 不一致；一次读取失败的保护标志又会拒绝后续保存，界面缺少重新读取入口。
- 修复与证据：写入与读回校验同属回滚边界；设置页增加“重试读取安全配置”。test/credential_storage_test.dart 覆盖写成功、下一次读失败再回滚；test/engine_lineup_test.dart 覆盖失败提示、重读和清除。双端旧配置迁移及真实短录音调用见 docs/credential-storage-validation.md。
- 正确做法：先确认系统存储再更新内存/成功反馈；空值标记阻止旧 JSON 复活已清 Key；无法确认回滚时报告状态未确认，不能声称原状态不变。
- 复发记录：Seen 1x (2026-10-16)。

### Keychain 必须跨不同签名构建验证升级

**同一构建重启读回成功不足以验证升级后密钥可用；Mac 安装必须保持稳定的签名身份。**

- 起因与后果：#41 的 ad-hoc 安装在同构建重启正常，下一次构建 CDHash 变化后 Keychain ACL 拒绝读取，界面要求重读。未发生 Key 丢失或明文回退。
- 修复与证据：改用现有 Developer ID 签名；用户本人完成系统“始终允许”后配置恢复。scripts/install-macos.sh 固定团队和 bundle 验证，禁止找不到证书时回退临时签名；后续用不同构建验证覆盖安装。
- 正确做法：密钥迁移验收同时覆盖“重启”和“新构建升级”；密码及系统授权由用户完成，不绕过 SecurityAgent。
- 复发记录：Seen 1x (2026-10-16)。

### 阻塞项要追根因并清障，真机验收不得闸住已过审合并

**「不动等用户真机验收的项」= 不替用户做真机步骤，但必须另寻路径推进；派工回来是阻塞态时，图灵立即追链、清障或改派，不得只把阻塞交回用户、也不得让执行人空闲。**

- 起因与后果：2026-10-16 Koe #50（P1）因 #13 阻塞被搁置；#13 又卡在 PR #44——代码已过审，却等用户真机 A4/A5。图灵数小时知晓整条链，只把阻塞交回用户，未提议「合并 #44、把真机拆成独立 needs-device-test 工单」，也未改派其他未阻塞的 Koe 活；Perplexity 在 Koe 上空闲。根因：(1) 把「不动等真机」当成停工而非另寻路径；(2) 没有阻塞所有权步骤——卡住时无人追根因并清掉；(3) 允许真机验收闸住已过审代码的合并。
- 修复与证据：用户要求根因总结并记入错题本／台帐（2026-10-16 19:35）。本条升为 AGENTS.md「阻塞链所有权」硬规则（过程归属类，不按 Seen 3 日门槛等待）。后续同形事件用本条核对。
- 正确做法（Done right）：任何已派工单项回来是阻塞态，图灵立即做三件事——(a) 追溯到根阻塞；(b) 自己清掉或派人清掉：代码评审已通过则先合并，把真机步骤拆成独立「需要真机」／needs-device-test 工单，不让真机闸住整条依赖链；(c) 两者都做不到时，只向亚里士多德报告「解开最多阻塞的那一个动作」。同时检查是否有其他未阻塞工单可派，不让 Perplexity 等执行人空闲。真机步骤仍只列在 `## 需要真机`，不进 `## 本机待办`。
- 复发记录：Seen 1x (2026-10-16)；证据：#50←#13←PR #44（A4/A5 真机），见 status/zcode-queue-20261016.md、status/perplexity-handoff-koe-sonori-20261016.md、status/koe-batch/13.md。已升为 AGENTS.md 硬规则。

### 破坏性脚本的路径保护要查包含关系，不能只查相等

- 起因与后果：#56 审查遗留 #59。#60（51a01c6）只拒绝旧包与安装目标「同路径」；复核发现安装目标在旧包内部，或旧包在安装目标内部（如目标指向 `/Applications`）时，退役脚本仍会归档并 `rm -rf` 旧包，连带删掉刚装好的新包。同一工单当天要第二个 PR 才补上。
- 修复与证据：#68（93c0506）把同路径检查升级为双向包含检查 `path_within`（解析符号链接、最近已存在上级目录、大小写不敏感卷），在任何改动前、`--check-running` 分支和 `rm -rf` 前各跑一次；4 个新用例在旧脚本上 3 个失败、新脚本通过（Linux 沙箱 Dart 3.13.5，大小写用例在 Linux 跳过）。真实 Mac 覆盖安装未跑。
- 正确做法（Done right）：给 `rm -rf`、覆盖、移动类操作加保护时，一次列全「相等、A 在 B 内、B 在 A 内、符号链接、大小写」五种关系，各写一个先红后绿用例；评审只看到其中一种时当场要求补齐，不拆成两个 PR。
- 复发记录：Seen 1x (2026-10-16)。

### 一个工单同一时间只有一个在做的 PR

- 起因与后果：2026-10-16 #13 被两路同时实现：#63（基于 #44 分支）和 #65，#63 跑完本机验证才发现重复而关闭，只把 `BleFilePull.isIncomplete` 并入 #65；同日 #40 与 #42 都做 #35 品牌统一，#40 在 #41 改主线后被 #42 整合替代；#74（#36）与 #75（#39）同时改 README 里同一行 DMG 文件名。另外 #61 漏写 `Closes #37`，#37 一直开着，后来又补了 #79。每起都多花一轮实现和本机验证。
- 修复与证据：#63 关闭、内容并入 #65；#40 关闭、由 #42 squash 合并；#74/#75 先后合并、内容一致；#79 关闭 #37。没有加防重复的机制，未验证。
- 正确做法（Done right）：派单或开 PR 前先查 `gh pr list -R semantic-craft/koe --state open --search "#<工单号>"`，已有开着的 PR 就在它上面续做或在工单里写明接管；PR 正文必须写 `Closes #N`（或「关联 #N，不关闭」并说明原因），让后来的人查得到。
- 复发记录：Seen 1x (2026-10-16)；同日三起。

### 模拟重启的测试要等前一个实例的写入全部结束

- 起因与后果：#55（c7be5ad）补的文件任务重启恢复回归里，测试一看到 `error != null` 就新建第二个 `FileJobJournal` 模拟重启，而首个控制器 catch 里的日志写入还没 await 完；两个实例共用 `file_jobs.json.tmp`，并发或磁盘慢时偶发 `PathNotFoundException`，用例不稳定（#64）。
- 修复与证据：#70（dba52a8）只改测试，加确定的同步点 `failedRunEnded(c)`（错误已设置且 `fileProcessingBusy` 为 false），同文件另一条同根因用例一并改；给首个写入注入 0–40 ms 延迟的 82 个变体，修前每轮 3–4 个失败，修后连续 3 轮 82/82 通过。生产代码未改。
- 正确做法（Done right）：测试里模拟重启或第二个进程之前，先等「前一个实例所有写入都已结束」的确定状态，不拿中间状态当完成信号；新增恢复类测试时跑一轮注入延迟的变体，确认不是靠时序碰巧通过。
- 复发记录：Seen 1x (2026-10-16)。

### 并发与重试回归要覆盖真实异步窗口，不用内部标记代替用户入口

**并发用 Completer 控制加载中/请求中的真实交错；重试从控制器或 UI 的确认入口断言请求序列；完成事件按实际订阅顺序发送，并核对持久化读取。**

- 起因与后果：PR #94 `bc770c6` 的并发测试用 20ms 延时、确认重试直接清内部未确认标记、云端 done 测试在完成流程结束后才发事件。独立复审发现加载中或请求中的第二次触发仍可能发起付费调用、校验失败的 final/merge 检查点会被复用、订阅中的短 done 会覆盖长实时稿；旧 head 的 390/390 与 analyze 0 issue 都没覆盖这些真实路径。
- 修复与证据：新回归从控制器和 `RecordingAnalysis.run` 两个入口覆盖加载与请求窗口，经 `generateTopicSummary(...confirmedRetry/overwrite)` 断言只重跑失败节点并复用成功片段，在订阅仍有效时发送短 done 后核对长稿与持久化读取，转写或音频变化的笔记在 UI 禁用生成，首次保存失败后释放忙碌并可重试。同一批 9 条回归在 `bc770c6` 上 9/9 失败，在修复提交上通过；全量 53/53 个测试文件、397 条用例通过。
- 正确做法（Done right）：需要证明并发或重试时，用可控 Completer/事件流制造目标窗口，从用户实际触发的控制器或 UI 入口调用，断言模型请求序列、结果和持久化内容；不直接清内部标记，不以固定短延时、内部 claim/checkpoint 状态或流程结束后的迟到事件代替真实顺序。
- 2026-10-18 再现：#148 Mac 原件归档中，索引写盘前发布内存状态会让第二条连接提前确认副本；恢复写入资料库期间，真实删除、改名与失败改名也会产生迟到写入或误删元数据。修正以串行事务的持久化成功作为确认点，用 Completer 挂住真实 library 写入，再从 RecorderController 的删除、改名入口触发交错，检查 exportedPaths、资料库及重新加载结果；取消恢复时只撤销自己的对象，并保留恢复前已有元数据。
- 复发记录：Seen 2x (2026-10-17, 2026-10-18)；证据：PR #94 复审（issuecomment-6232346316），旧 head `bc770c6` 新回归 8/8 红；#148 的 `mac_archive_commit_test.dart`、`mac_archive_store_concurrency_test.dart` 与 `mac_archive_restore_race_test.dart`。

### 改名要在同一个 PR 里查完文档中的旧产物名

- 起因与后果：#56（75749ac）把 macOS 应用和 `scripts/build-dmg.sh` 的输出改成 Koe，但 README 仍写 `dist/soundcore-manager-<version>-macos.dmg`、主标题仍是旧名，之后又开了 #74、#75 两个文档 PR 来补。
- 修复与证据：#74（5ae5b1c）改 DMG 文件名；#75（fa2cd26）统一安装说明，新增 `test/readme_install_identity_test.dart`（修前失败、修后通过），并核对了 macOS/iOS 构建产物；未覆盖安装、未启动 GUI。
- 正确做法（Done right）：改名或改产物路径的 PR 附一次 `rg -n '<旧名>'` 结果，逐条说明保留（兼容标识、协议、上游署名、历史记录）还是改掉；用户入口文档和脚本输出放在同一个 PR 里改。
- 复发记录：Seen 1x (2026-10-16)。

### 原生库要同时核对平台切片和打包格式

**同为 arm64 不代表真机库可用于模拟器；替换原生依赖必须复验已有平台。**

- 起因与后果：2026-10-18 #88 的 flutter_opus 静态库含 arm64，却标记为 iOS 真机，模拟器链接失败。替换成 opus_codec 3.0.5 后又暴露 SPM 相对路径与 macOS framework 扁平目录问题，不能只检查架构名称或 Dart 分析。
- 修复与证据：使用带模拟器切片的 XCFramework，项目级禁用 SPM；macOS 仅整理 CocoaPods 构建副本，在嵌入签名前形成 Versions/A 布局。相同模拟器构建先失败后通过，iOS 真机目标无签名与 macOS Debug 构建通过；真实编码的合成 Opus 包通过 16/48 kHz、PCM 小端和 reset 验证。未安装、未验证真实录音或听感。
- 正确做法：用目标平台构建重放故障，检查 Mach-O 的平台标记而不只看 lipo 架构；更换共享原生库时检查已有 Apple 目标及实际解码。SPM 旧生成缓存按 README 的 clean/pub get 步骤清理；不得修改共享 pub 缓存或排除 arm64 假通过。独立发生 1 次：2026-10-18。
