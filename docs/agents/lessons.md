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
- 验证点：`scripts/perf-check` 运行中隐藏 Koe 测试 app：`osascript -l JavaScript -e "ObjC.import('AppKit'); \$.NSRunningApplication.runningApplicationWithProcessIdentifier($(pgrep -nf Profile/Koe.app/Contents/MacOS/Koe)).hide"`。Koe 刚启动时这条返回 false，要重试到隐藏为止；正在用的 app 不受影响。Koe 启动后约 35 秒，perf-check 以退出码 3 退出，消息含 `no frame drawn for 30 s (app lifecycle: hidden)`。`KOE_PERF_TIMEOUT=25 scripts/perf-check` 以退出码 4 退出后，`ps -axo command | grep -E 'flutter_tools|Profile/Koe.app'` 没有匹配。
- Seen 1x (2026-10-23)

### 修一个页面的布局缺陷，要把同写法的页面一起查

- 出事：2026-10-19 #260 发现资料页上滑后分段控件进了状态栏，#265 只给资料页加了只让顶部的 `SafeArea`。今日页、项目页同样是 `GradientScaffold(child: ListView(...))`，页头自带的状态栏留白随列表滚走；设置页的返回键是叠在列表上的 `Positioned`。同类缺陷一直留到 2026-10-22 在 Pixel 上跑 Artemis 冒烟测试、逐张看截图才发现（#384），Artemis 自己给的结论是 PASS。
- 修复（#384）：今日页、项目页加只让顶部的 `SafeArea`，设置页的返回键移到列表上方单独一行；没滚动时各元素位置不变。
- Done right: 修布局缺陷前先 `rg -n 'GradientScaffold\(' lib/ui` 列出同写法的页面逐个确认（有 AppBar 的、页头固定不随列表滚动的不受影响），回退测试一次覆盖所有同写法的页面。冒烟或探索式测试的 PASS 不看画面，截图要自己逐张看。
- 验证点：`flutter test test/status_bar_scroll_test.dart test/library_screen_scroll_test.dart` 通过（顶部安全区 62pt，上滑后列表顶边 ≥ 62；设置页列表顶边 ≥ 返回键底边）。
- Seen 2x (2026-10-19, 2026-10-22)

### Mac 验收用 System Events 点菜单可能没送达，退出改发给进程的退出事件

- 出事：2026-10-23 #427 评审修复的验收里，用 System Events 点菜单栏「退出 Koe」和主菜单「Quit Koe」，AppKit 日志里都没有 `terminate:`，退出没有发生。
- 修复：给这个进程发退出事件：`NSRunningApplication(processIdentifier:)` 的 `terminate`，和 ⌘Q、菜单「退出 Koe」走同一个 `terminate:`，进到 `macos/Runner/AppDelegate.swift` 的 `applicationShouldTerminate`。不按 bundle id 发，因为用户装的 Koe 和开发版是同一个 bundle id。
- 验证点：验收记录里退出那一步，引用 `/usr/bin/log show --predicate "processID == <pid>"` 里的 `applicationShouldTerminate` 行；`rg -n "func applicationShouldTerminate\(" macos/Runner/AppDelegate.swift` 有结果。
- Seen 1x (2026-10-23)

### `pmset -g assertions` 不显示中文的防睡眠原因

- 出事：#403 验收时，Koe 的防睡眠声明在 `pmset -g assertions` 里原因是空的，原因当时写的是中文。
- 修复：#427 改用英文原因（`lib/ui/mac_menu_bar.dart` 里的 `keepAwake = 'Koe is recording'` 等）。
- 验证点：`rg -n "keepAwake = 'Koe is" lib/ui/mac_menu_bar.dart` 有结果（2026-10-23 核对在第 86 行）；录音时 `pmset -g assertions | grep Koe` 能看到原因。
- Seen 1x (2026-10-23)

### 临时 profile 入口用编译期常量提前结束 main，AOT 构建会崩

- 出事：2026-10-23 #427、#409 的临时验收入口用 `String.fromEnvironment` 选模式。某个模式在 `main` 里 `exit(0)` 或 `return` 后，后面的应用代码在 AOT 看来都是死代码，`flutter run --profile -d macos` 构建时报 `AOT snapshotter exited with code -6`。
- 修复：提前结束的条件里加一个运行时判断（如 `DateTime.now().year > 2000`），AOT 就会保留后面的代码。
- 验证点：临时入口的每个模式都用 `--profile` 构建一次再用。
- Seen 1x (2026-10-23)，同一天出现两次

### `scripts/perf-check` 要在 Mac 空闲、不和 CI 重叠时跑

- 出事：同一份代码，Mac 有人在用时跑出卡顿：#403 第一次 `recording` 291 帧里 41 帧卡顿，重跑 0 帧；#409 第一次改前那轮 `recording` 87 帧里 84 帧卡顿，`playback` 53 帧卡顿。帧数少说明窗口没在前台，帧被节流了。CI 也在这台 Mac 上跑。窗口完全不出帧时，#448 起 perf-check 会以退出码 3 停下（见「已知会卡住的外部条件要直接检测、尽快失败」），但窗口出帧却被节流时，数字照样会出来。
- 修复：先等 Mac 空闲（`ioreg -c IOHIDSystem` 的 `HIDIdleTime` 超过 2 分钟）再跑；跑的时候每 5 秒记一次空闲时间，有人碰过就作废重跑；用 `gh run list` 核对没和 CI 重叠。
- 验证点：PR 里写明 perf-check 那几轮没人碰 Mac、也没和 CI 重叠。
- Seen 1x (2026-10-23)

### 格式化改过的文件前，先看它在 HEAD 上是不是已经格式化好的

- 出事：2026-10-23 #407 给 `test/phone_recording_test.dart` 加测试后跑 `dart format`，整个文件被重排，新测试淹在几百行无关的格式改动里。这个文件在 main 上本来就没格式化好（main bb19383 上单独格式化它，增 282 行、删 309 行）：本机和 CI 同为 Flutter 3.47.7，main bb19383 上 `lib`、`test`、`integration_test` 的 354 个 Dart 文件里有 31 个 `dart format` 后会变；CI 和 `scripts/check` 不查格式。
- 修复：文件恢复成 HEAD，只把新加的块按格式手写进去。
- 验证点：格式化前跑 `dart format -o none --set-exit-if-changed <文件>`，HEAD 上退出码为 0 才整文件格式化，否则只格式化自己加的部分；提交前用 `git diff --stat` 看改动行数和实际改动相符。
- Seen 1x (2026-10-23)

### 认录音豆用经典地址，不用会轮换的 BLE 地址

**全天常驻、绑定与在场判断按厂商数据里的经典蓝牙地址认录音豆；连接才用扫描到的当前 BLE 地址。不要用可解析私有地址当身份，也不要靠系统伴侣在场监听去匹配关联时的 BLE 地址。**

- 哪个 commit/issue 出的事，后果：#422（f065809，2026-10-23 09:05 Asia/Shanghai）合并「全天常驻」：按绑定录音豆的蓝牙地址做 CDM 关联与 `_syncResident`，系统在场监听也按关联时的地址匹配。② 写明「未在真实环境验证 #393 的功能本身」。同日 #345 真机验收发现 D3200 至少每次 Wi‑Fi 导出后换一个可解析私有地址、经典地址不变：全天常驻被悄悄撤销、系统不再唤起 Koe、重连先对旧地址空等约 100 秒（`scanResults` 还回放上次扫描）。
- 修复的 commit：#451（28b1070）按经典地址认设备，用 PendingIntent 厂商数据扫描替换系统在场监听，连接记最新 BLE 地址；回退测试在 main（b6b0ae5）上 `expect(controller.resident, isTrue)` 失败、改后通过。#452 进度页记 #345 第二部分真机：换地址后直接连新地址、常驻与关联仍在。
- Done right: 涉及「是不是同一台录音豆」的逻辑只比经典地址；写回退测试时让录音豆换 BLE 地址再回来，断言常驻仍开、连的是新地址。合并前至少在真机上做一次 Wi‑Fi 导出后再看常驻是否还在（#345 已暴露）。
- Seen 1x (2026-10-23)
- 验证点：`rg -n '经典地址|classicAddress|RecorderScan' android/app/src/main/kotlin lib/ test/android_bound_reconnect_test.dart` 有结果；`rg -n 'a recorder back at another Bluetooth address is the same recorder' test/android_bound_reconnect_test.dart` 有结果；`flutter test test/android_bound_reconnect_test.dart test/ble_scan_test.dart` 通过。

## 删除开发产物前先检查运行引用与应用注册

- 起因与后果：2026-10-23 本机盘点发现多个项目已删除的构建／验收 App 仍有 LaunchServices 注册；删除目录不会自动注销。历史引入提交未确定。
- 修复：本次清理入口改为精确目录注销，包含嵌套辅助 App、已失效路径和同路径多条记录；注销失败或目录内有运行中的可执行文件就保留产物。删除后再核对注册。
- Done right：只处理调用方拥有的临时目录，不停止进程、不重建数据库；正式安装与其他工作区不在清理范围。
- Verify (验证点)：运行 cleanup_app_registrations 的回归，检查运行中副本、符号链接、注销失败及嵌套／重复记录；真实隔离 App 验证另记 PR，模拟测试不替代本机证据。
- Seen 1x (2026-10-23)。

### 静音识别失败不能按音频帧热重试

- 出事：#464 第三批正式安装 GUI 无中文实时文字；退出 Sonori 后仍复现。麦克风 1110 无语音错误后，每个输入帧都创建新的 Speech 请求，双路识别受到影响。
- 修复：#469 按 lane 在无语音后等待 3 秒且有声才重试，其他错误等暂停/继续；请求编号隔离旧 final 的状态清理，仍保存其末句。WAV 写入不依赖识别成功。
- 验证点：30 秒静音帧重放在旧行为失败、生产 gate 通过；最终签名 GUI 公共中文样例出现文字，暂停/继续后恢复且双路原件保存。短样例不替代真实会议。
- Seen 1x (2026-10-24)。

### Mac 权限验收必须用应用身份启动，日历编辑须真正提交

- 出事：2026-10-24 #453，工具直接 Popen 安装包二进制，EventKit 报未授权；同时把 Calendar 重开后恢复的编辑浮层当成已提交事件，误判会议命名失败。
- 修复：开发启动入口通过 NSWorkspace 启动安装包，保留环境凭据隔离；已有进程时拒绝启动。Calendar 点击空白格关闭编辑后再测试。
- 证据：同一安装包直接启动 authorized=0、系统启动 authorized=1；提交事件前后 matches=0/1。去掉临时诊断重新签名安装，12:45录音会议命名及重启保留通过。见 [验收记录](../acceptance/calendar-453-2026-10-24.md)。
- 正确做法：系统设置开关、进程实际权限、编辑提交、真实录音结果分层核对；重开恢复编辑不算数据库写入证据。
- 验证点：`scripts/run-with-secrets.py macos` 在已有Koe时返回失败；退出后经LaunchServices启动，并通过真实日历事件录音复验。
- Seen 1x (2026-10-24)。

### 系统授权请求未返回时不能显示空闲

- 出事：2026-10-24 #453，提醒事项导出停在原生授权请求，界面仍显示“未导出”且允许重复点击；把这一状态直接解释成“用户未授权”，使用户反复寻找不存在于设置列表中的开关。
- 修复：导出状态由 TodoSystemSync 持有，授权与写入分阶段通知界面；挂起期间禁用重复导出，结束后恢复。
- 证据：`test/todos_test.dart` 的 pending system authorization 行为测试改前失败、改后通过；TCC 的 AUTHREQ_PROMPTING 只证明系统发起提示，不证明用户可见或已授权。
- 验证点：先核对安装版、系统请求结果与用户可见界面；remindctl 的权限归属与 Koe 分开，不把 CLI 诊断或模拟通道通过写成真实导出验收。首次记录 2026-10-24，独立复发次数 1。

### MCP 工具发现不等于内容读写和多宿主授权验收

- 出处：2026-11-03 QwenNote 接入会话；Magpie / 本机 Codex OAuth 登录后列出 27 个工具，但授权页包含读写且当次未能选择只读，新会话及其他 agent 尚需验证。记录来自会话交接，本文未重新调用服务。
- 修复方向：未来 Koe MCP 先按指定记录只读，分开核对上游授权、下游客户端身份和宿主权限；不复制令牌，持久连接不等于逐次操作同意，工具发现与内容读取、写入后读回、新会话、撤销分别验收。当前只落文档，未实现权限控制。
- 验证点：按 [复盘与规划验收矩阵](../design/qwennote-mcp-lessons-and-plan.md#开发时使用的验收矩阵) 使用授权测试记录核对；每个客户端有独立结果，过期/撤销和越权明确失败，不将工具数量视为数据操作通过。
- Seen 1x (2026-11-03)。

### msmtp 要求含密码配置文件的属主必须为当前运行用户且发信需显式指定发件人

- 出处：2026-11-06 阿里云 VPS 部署 `koe-mcp.service` 发送 OTP 邮件；直接读取宿主共享 `/etc/vpsops-monitoring/msmtprc` 时，msmtp 因属主非当前进程用户退出码 78 并拒绝发信，且 `koe@localhost` 默认发件人被 QQ SMTP 拒绝。
- 修复：将发信配置部署为专属属主文件 `/etc/koe-mcp/msmtprc`（0600 `koe-mcp:koe-mcp`），发信时自动提取真实发件人并通过 `--read-envelope-from --read-recipients` 投递；本地测试与无公共 URL 场景下保留 `dev_code` 供自动化验收。
- 验证点：公网 `POST https://<vps-domain>/pair/request` 实际投递至授权邮箱返回 `delivered: true`，且 `flutter test test/koe_mcp_export_test.dart test/mcp_sync_test.dart` 全绿。
- Seen 1x (2026-11-06)。

### 外部 AI 接入界面严禁写死或回显个人 VPS 域名与邮箱，且不设人工输入框

- 出处：2026-11-07 用户在准备桌面端与 iPhone 端实机验收时发现，「设置 → 外部 AI 连接」弹窗中不仅要求手动填写 VPS 地址、邮箱与验证码，还直接在 `hintText` 和已连接卡片上显示了用户的真实个人 VPS 域名与私人邮箱，造成隐私泄露风险与多余填写负担。
- 修复：移除 `_ExternalAiDialog` 中全部 `TextField` 手动输入框及所有写死域名/邮箱，`McpSyncConfig.redactedLabel` 仅显示脱敏连接模式（`VPS 云端已连接` / `Mac 局域网已连接`），绝不在界面回显 URL 或邮箱；新增 `mcp_pairing.txt` 自动投递绑定机制与面向仓库 `tools/koe-mcp/README.md` 的通用 Agent 提示词，支持插电脑 AI 直读/直写或一键剪贴板粘贴。
- 验证点：全仓检索无个人真实域名与私人邮箱字面量；`flutter test test/mcp_sync_test.dart --reporter expanded` 断言弹窗内 `find.byType(TextField)` 为 0 且不显示 `baseUrl`/`email`。
- Seen 1x (2026-11-07)。


### iOS 验收必须保留截图元数据并驱动真实页面入口

- 出处：2026-11-05 Slice B，iOS 业务断言通过但验收脚本因缺少截图返回失败；测试写入 reportData 时覆盖了 takeScreenshot 的元数据，直接挂载纪要页也未覆盖生产导航。
- 修复：合并已有 reportData，从 RecordingDetailScreen 经摘要与分析进入结构化纪要；独立驱动器同时保存截图与行为证明，入口缺任一证据均非零退出。
- 验证点：运行 `scripts/verify-minutes-flow ios`，核对回执、两张截图及持久读回/章节/重开证明；`test/support/minutes_flow_scenario.dart` 同时用于离线回归。截图存在不能替代断言。
- Seen 1x (2026-11-05)。

### 自动整理等待录音和 ASR 收尾

- 出处：2026-11-05 Slice C，录音过程中已登记的路径提前进入自动整理，部分文字未落盘时待办提取失败；重复停止或下一场开始还会提前清除旧场收尾状态。
- 修复：完整整理等待录制、暂停、ASR 与音频转换结束；同场共享一次收尾，旧场末句仅保存到旧记录。Apple 收尾失败且已有部分文字时，明确重试会重新转写完整音频。
- 验证点：`test/device_live_minutes_test.dart` 用受控异步时序验证阶段摘要、末句、重复停止、跨场隔离、只留本机撤销、失败恢复与磁盘重读。真实进程重启和实体按键另验，不能用对象重建代替。
- Seen 1x (2026-11-05)。

### 自动发布验收必须由生产写入触发，不能由测试代发通知

- 出处：2026-11-05 Slice D，持续 MCP 客户端测试若手动调用 notifyListeners，会遮住 rememberTranscript 不通知导致的旧文字；授权等待中关闭还会恢复计时器。
- 修复：生产转写写入显式调度发布，授权每个 await 后复核关闭状态，撤销清空发布及旧内容错误。
- 验证：test/mcp_live_publication_test.dart 直接调用生产续写/校订/纪要动作，以持续 stdio 客户端读回；改前失败证据在 .scratch/pstack-relay/slice-d-auto-update-before.log、slice-d-dispose-before.log 和 slice-d-revoke-error-before.log。
- Seen 1x (2026-11-05)。
