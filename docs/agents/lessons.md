# 教训台账（内部）

只给 agent 用：记每条教训的出处、修复、验证点和复发次数（Seen N×）；验证点写明之后怎么核对这条已改到位（看哪个文件、跑什么命令、查什么结果）。对外的十条规则在 [CONTRIBUTING](../../CONTRIBUTING.md)；同一条教训在 3 个不同日子出现，就升为 [AGENTS.md](../../AGENTS.md) 交付规则，能写成测试或检查的写成测试或检查。
#286 开源准备时根目录 `lessons.md` 并入了 CONTRIBUTING，Seen 计数随归档一起删了；本文件从 2026-10-19 起接着记，旧条目原文在 git 历史 `ae0cfa5^:lessons.md`（#286 删除前的最后一版）。

### 流回调的 await 必须绑定请求代际

- 出处：2026-10-22 PR #389 的 2B 复审 B1：下载暂停后立即继续，旧 onData 等待 Wi-Fi 的结果可写已关闭 sink，或取消新请求。
- 修复：每个 HTTP 下载分配代际；取消与资源关闭前使代际失效，Wi-Fi 检查返回后先核对；继续下载等待暂停/删除完成订阅取消与 sink 关闭。
- 验证：`test/diarization_model_store_test.dart` 的 `pause then resume ignores stale Wi-Fi result` 用 Completer 控制 true/false 旧结果，并覆盖等待暂停与立即继续；改前空 sink 异常、新请求失败或超时，修后新文件内容与 SHA 正确且 zone 无异常。
- Seen 1x (2026-10-22)

### 本机区分验收必须覆盖生产默认输入与真实时间轴

- 出处：2026-10-22 PR #389 评审：测试显式开 SHA 校验、假 Apple 服务带精确时间戳，遮住了正式默认配置不校验和真实 Apple 仅返回全文的问题；48 kHz 样本直接交给只接收模型采样率样本的分段器，产生错误时间轴。
- 修复：默认校验缓存和下载；无识别时间戳时保留全文、跳过句子归属；在后台 isolate 内读 WAV、重采样到模型采样率并完成 native 对象生命周期。
- 验证：`test/diarization_model_store_test.dart` 默认构造拒绝损坏缓存；`test/local_speaker_diarization_test.dart` 用真实 AppleSpeechService 解码无分段响应；`tool/diarization_regression.dart` 用同一中文音频验证主 isolate 心跳与 48/16 kHz 时间轴。默认并发失败先在 main 运行同一命令建立基线，不能把低并发通过当默认命令通过。
- Seen 1x (2026-10-22)

### 异步测试要等真实 I/O 结束的确定状态，不拿中间状态当完成信号

- 出事：2026-10-19 一天里三处同根因的偶发失败，都在本机负载下拖红 CI：#205（20ca963）重启恢复用例在日志读完前取 `jobs.single`、在最后一次落盘前结束；#213（1100aac）未等待的保存落进临时目录、用一次 `pumpEventQueue` 当落盘完成；#305（992af84）保存后 `pumpAndSettle` 只推进假时钟，对话框遮罩还在，点「译文」落到遮罩上。
- 修复：20ca963、992af84 只改测试，加确定的同步点或等到对话框真正关闭；1100aac 把 `pumpEventQueue` 改为轮询读回，并改了存储层：固定 `.tmp` 改为每次写入用独立临时文件（`lib/state/atomic_file.dart`）。
- Done right: #305 在测试控制器里注入 300ms 真实 I/O 延迟，改前稳定复现 CI 失败、改后在 18 核满载下连跑 40 次全过；#205 注入 40ms 读写延迟复现两处缺口。
- 再出现（2026-10-22，真机场景）：#366（2a416f5）新加的 `microphone_refused_test` 看到「录音已停」就去读停下原因；Koe 被拒后先停录音、清录音状态，再把这段录音收进录音库（要读写文件），最后才写原因，场景读到 null。#366 合并时 Pixel 锁着、场景没在真机跑过（按硬规则 7 先合），第一次真跑（main da19d28）就失败，#380（e6c0595）返工。
- 修复（2026-10-22）：#380 只改场景，等 Koe 写出原因后再比对文字；同一台 Pixel 上改前（da19d28）`microphone_refused_test.dart:130` 读到 null 失败，改后（33e2d62）通过。
- 验证点：`rg -n '异步测试要覆盖真实时序' CONTRIBUTING.md` 有第 7 条；`rg -n '_sequence' lib/state/atomic_file.dart` 显示每次写入用独立临时文件名；`rg -n '^9\. \*\*异步' AGENTS.md` 有硬规则 9。
- Seen 3x (2026-10-16, 2026-10-19, 2026-10-22)；10-19 同日三起只算一次。已在 CONTRIBUTING 第 7 条；2026-10-22 第 3 个不同日子出现，已升为 AGENTS.md 硬规则 9（真机场景同样适用）。

### 全局主题改动要在真实界面逐类组件看一遍

- 出事：`lib/theme/app_theme.dart` 一直用 `base.copyWith(textTheme: TextTheme(...))` 拿一个全新的 TextTheme 覆盖基础主题（首个提交 43befb5 就这样写，10-19 UI 规范系列 #259 f467144 外面又包了一层 `_tabular`）。`headlineSmall` 等没定制的样式因此没有颜色，所有 AlertDialog 标题在 iPhone 和 Mac 上都是空白。这个写法在 1.2.2 之前的发布版（1.1.0、1.2.0、1.2.1）里都有，到 10-19 1.2.1 真机复测才发现（#306）。哪个版本、哪个提交开始真正显示空白，待核实。
- 修复：3046034（#309，在基础 textTheme 上 `copyWith`，随 1.2.2 发布）；#308 在 1.2.2 上用 iPhone 和 Mac 安装版复测，对话框标题可见。
- Done right: #309 加了 iOS/macOS × 浅色/深色 4 条回退测试（改前标题颜色为 null），#308 再用 `scripts/mac-ax` 和 iPhone 截图在真实界面确认标题。以后改主题时，把对话框、菜单、输入框等每类组件都在真实界面截一遍图再合。
- 验证点：`flutter test test/dialog_title_visible_test.dart` 通过（iOS/macOS × 浅色/深色对话框标题颜色非空）。
- Seen 1x (2026-10-19)

### 验收记录只写有证据的操作，不替用户补全没看到的步骤

- 出事：#255（c9fd4f3）把 #231 复测写成「没人按键、录音豆自己结束文件」，实际是用户 13:55 左右按录音豆实体键结束了录音；结论因此把「补取成功」错归给了自动结束。
- 修复：57b9a5b（#256，依据用户确认的操作和当时的 BLE 日志更正；补取成功那次日志为 `head … size=1195200`）。
- Done right: 验收结论里每一步用户或设备操作都要指向日志、截图或用户原话；看不到的写「待核实」，先问再写。
- 验证点：
- Seen 1x (2026-10-19)

### 本机跑测试前清掉 shell 里的云端密钥环境变量

- 出事：2026-10-21 #337 在本机跑 `check`，干净 main 也红 5 条（`engine_lineup_test`、`recording_processing_test`、`context_export_test`）：agent 的 shell 带着 `DASHSCOPE_API_KEY` 等变量，`lib/ai/cloud_stt_service.dart` 会读它们，「未配置」的用例因此看到已配置。CI 运行机没有这些变量，所以只在本机红。
- 修复：只改跑法：`env -u DASHSCOPE_API_KEY -u ARK_API_KEY -u DOUBAO_TTS_API_KEY check`，main 与分支都全绿。没有读取或打印变量值。
- 反过来也会漏：2026-10-22 #344 新加的冷启动用例在本机单跑 `flutter test` 时全过，靠的是 shell 里的密钥；去掉变量跑 `check` 才红：读回已保存设置时 Qwen 的 key 被换成保存的空值。修复在测试保存的设置里带上替身 key。
- Done right: 本机 `check` 出现与改动无关的「已配置」类失败，先在干净 worktree 用同样去掉密钥变量的命令复跑一遍对照，再判断是不是回归。单跑 `flutter test <文件>` 也加同样的 `env -u …` 前缀。
- 验证点：`rg -n "EngineConfig\(apiKey: 'test-key'\)" test/text_capture_test.dart` 应有结果；`env -u DASHSCOPE_API_KEY -u ARK_API_KEY -u DOUBAO_API_KEY -u DOUBAO_TTS_API_KEY flutter test test/engine_lineup_test.dart test/text_capture_test.dart --reporter expanded` 应全绿。2026-10-23 本机实跑：rg 命中第 327 行，两文件 37 条测试通过。`scripts/check` 在启动 Flutter 前 unset 这四个变量（`DASHSCOPE_API_KEY`、`ARK_API_KEY`、`DOUBAO_API_KEY`、`DOUBAO_TTS_API_KEY`）；入口隔离可用 `env DASHSCOPE_API_KEY=test-key ARK_API_KEY=test-key DOUBAO_API_KEY=test-key DOUBAO_TTS_API_KEY=test-key scripts/check` 验证，值仅为测试替身；2026-10-23 本机实跑静态分析无问题、920 条测试全绿。
- Seen 2x (2026-10-21, 2026-10-22)

### 真机场景不能假设 Pixel 停在解锁的桌面：充电时会进屏保，锁屏要 PIN

- 出事：2026-10-22 #344 快捷方式场景头一次真正在 Pixel 上跑（#347 到 #354 的场景提交时 Pixel 都离线；#345 的记录里，之后只有 credentials_test 在真机上跑通过），接连失败。`moveTaskToBack` 后 Koe 的生命周期一直是 resumed：手机充电，息屏 30 秒就进时钟屏保（`com.google.assistant.hubui` 的 `EverydayClockDreamService`），Koe 留在屏保后面，只收到 `wm_on_top_resumed_lost_called`。改按 Home 键后，屏保一退就露出锁屏；锁屏要 PIN，`wm dismiss-keyguard` 解不开。点快捷方式时 Koe 只在锁屏后面恢复一下又暂停（`wm_pause_activity … sleep`、`wm_set_keyguard_occluded [0,0,0]`），麦克风前台服务被拒：logcat 里服务本身获准启动（`ACTIVITY_VISIBILITY_GRACE_PERIOD`），但 uidState 是 `TPSL`（置顶但在睡眠）、`allowWiu:-1`，接着报 `can not have location/camera/microphone access`，`startForeground` 抛 SecurityException。
- 修复：`KOE_ADB: home` 先 `wake-screen` 再按 Home，场景等 Koe 真进了后台。原生状态加 `deviceLocked`（`KeyguardManager.isDeviceLocked`）；手机锁着时场景打印 `KOE_ADB: skip <原因>` 并跳过，`scripts/android-check` 以 77 退出：记为跳过，不算通过也不算失败。试过离屏 8 秒后再点快捷方式，锁着时照样被拒。手机解锁后同一场景通过，logcat 里是 `uidState: TOP`、`code:PROC_STATE_TOP`、`allowWiu:12`。
- 跨运行也一样（同日）：#360 让一次运行里的锁屏场景排最后，但锁屏场景一关屏手机就要 PIN，一次解锁只够一个锁屏场景跑通。10:31–10:39 在 main cd25be1 上整套跑，最后的手机录音锁屏场景 10:36:53 关屏；10:38:37 `dumpsys trust` 已是 `deviceLocked=1`，当时 `settings get secure lock_screen_lock_after_timeout` 为 null（默认）。紧接着拿到设备的另一次运行（#366 的两个新场景）开头就打印「手机锁着」，构建完被停下；不停的话两个场景都会跳过。
- Done right: 写需要 Koe 在屏幕上的场景前，先用 `adb shell dumpsys power`（`mWakefulness`、`mDreamsActivateOnSleepSetting`）和 `dumpsys trust`（`deviceLocked`）看设备实际状态；失败时看 `adb logcat -b events` 里 `wm_pause_activity` 的原因，和 `ActivityManager` 对前台服务的判定（`uidState`、`allowWiu`）。没人值守解不开 PIN 锁屏：要 Koe 在屏幕上的场景，手机锁着时跳过。排队等设备的运行先读 `dumpsys trust`，`deviceLocked=0` 才开跑；要在一次解锁里跑完，就把不锁屏的场景和至多一个锁屏场景放进同一次运行。
- 验证点：`rg -n 'deviceLocked' android/app/src/main/kotlin integration_test/android/background_support.dart` 有结果（原生状态带 `isDeviceLocked`，`skipIfLocked` 锁着时打印 `KOE_ADB: skip`）；`rg -n 'skipped=77' scripts/android-check` 有结果。
- Seen 1x (2026-10-22)；同日跨运行又遇到一次，只算一次。

### 几个会话共用 Pixel：停掉的运行要放回设备锁，取证不清 logcat

- 出事：2026-10-22 几个会话按约定共用 Pixel：用前 `mkdir ~/.cache/koe-pixel.lock`，用完 `rmdir`。10:39:30 排队的 #366 场景运行在上一轮跑完后拿到锁、开始构建。手机这时 PIN 锁着，两个场景只会跳过，于是用 TaskStop 停掉了它。进程被杀，没走到 `rmdir`，锁目录留了下来，别的会话就拿不到设备。约 10:41 发现，确认没有残留进程后删掉。同一天还写过一条先 `adb logcat -c` 再取证的命令；它会把另一个会话还要看的记录一起清掉，在拿到设备锁之前停下了。
- 修复：排队脚本用 `trap` 在退出和收到 TERM 时放回自己拿的锁。取证改用 `adb logcat -d -T '<开始时间>'`，只读这一轮开始以后的日志。
- Done right: 停掉真机运行后先看 `ls -ld ~/.cache/koe-pixel.lock`，是自己拿的就放回。手机上大家共用的状态（logcat 缓冲、系统设置）不清不改，只读自己这一轮的部分。
- 验证点：没有运行在用 Pixel 时，`ls -ld ~/.cache/koe-pixel.lock` 报不存在。
- Seen 1x (2026-10-22)

### 已知会卡住的外部条件要直接检测、尽快失败；停后台命令要停它的整个进程组

- 出事：2026-10-23 为 #422 跑 `scripts/perf-check`，4 次里 3 次空等满 480 秒才以退出码 3 结束，共白等约 24 分钟。原因是 Mac 正被使用，Koe profile 窗口不在屏幕上，macOS 不出帧，场景里的 pump 一直等。#240 起就知道这种情况会卡住，当时只加了总超时。超时后脚本只杀了 `flutter drive` 本身，它起的子进程继续往日志里写，盖掉了调用方追加在末尾的退出码行。
- 修复（#448）：`integration_test/perf/perf_scenarios_test.dart` 的 `_stopWhenNoFrames` 发现一帧该出却 30 秒没画出时，经驱动结束运行；驱动写 `build/perf/no_frames.txt`，`perf-check` 以退出码 3 和「窗口不在屏幕上，不是性能超标」退出。总超时改成退出码 4。`flutter drive` 自成进程组（Koe 和驱动都在组里），超时、中断时停整组。
- Done right: 已知会让运行卡住的外部条件（窗口、设备、锁屏）要在出现时直接检测，几十秒内带着原因失败，退出码和真实的失败分开；总超时只兜底未知的卡住。后台起的命令放进它自己的进程组，停的时候停整组，组里没进程了再退出。
- 验证点：`scripts/perf-check` 运行中隐藏 Koe 测试 app，Koe 启动后约 35 秒以退出码 3 退出，消息含 `no frame drawn for 30 s (app lifecycle: hidden)`。`KOE_PERF_TIMEOUT=25 scripts/perf-check` 以退出码 4 退出后，`ps -axo command | grep -E 'flutter_tools|Profile/Koe.app'` 没有匹配。
- Seen 1x (2026-10-23)

### 修一个页面的布局缺陷，要把同写法的页面一起查

- 出事：2026-10-19 #260 发现资料页上滑后分段控件进了状态栏，#265 只给资料页加了只让顶部的 `SafeArea`。今日页、项目页同样是 `GradientScaffold(child: ListView(...))`，页头自带的状态栏留白随列表滚走；设置页的返回键是叠在列表上的 `Positioned`。同类缺陷一直留到 2026-10-22 在 Pixel 上跑 Artemis 冒烟测试、逐张看截图才发现（#384），Artemis 自己给的结论是 PASS。
- 修复（#384）：今日页、项目页加只让顶部的 `SafeArea`，设置页的返回键移到列表上方单独一行；没滚动时各元素位置不变。
- Done right: 修布局缺陷前先 `rg -n 'GradientScaffold\(' lib/ui` 列出同写法的页面逐个确认（有 AppBar 的、页头固定不随列表滚动的不受影响），回退测试一次覆盖所有同写法的页面。冒烟或探索式测试的 PASS 不看画面，截图要自己逐张看。
- 验证点：`flutter test test/status_bar_scroll_test.dart test/library_screen_scroll_test.dart` 通过（顶部安全区 62pt，上滑后列表顶边 ≥ 62；设置页列表顶边 ≥ 返回键底边）。
- Seen 2x (2026-10-19, 2026-10-22)
