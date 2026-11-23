# 教训台账（内部）

只给 agent 用：记每条教训的出处、修复、验证点和复发次数（Seen N×）；验证点写明之后怎么核对这条已改到位（看哪个文件、跑什么命令、查什么结果）。对外的十条规则在 [CONTRIBUTING](../../CONTRIBUTING.md)；同一条教训在 3 个不同日子出现，就升为 [AGENTS.md](../../AGENTS.md) 交付规则，能写成测试或检查的写成测试或检查。
#286 开源准备时根目录 `lessons.md` 并入了 CONTRIBUTING，Seen 计数随归档一起删了；本文件从 2026-10-19 起接着记，旧条目原文在 git 历史 `ae0cfa5^:lessons.md`（#286 删除前的最后一版）。

纯 Flutter/Dart 的构建、旧性能驱动与已退役的远程配对实现保留在 git 历史 `03b58d0:docs/agents/lessons.md`。

### Rust crate 同时产出 `cdylib` 与 `staticlib` 时，SwiftPM 必须显式链接 `.a` 路径并用 `otool -L` 拦截动态依赖

- 出处：2026-11-21 在 `main`（`00322b9`）执行 `./scripts/release-macos.sh` 时，Developer ID + Hardened Runtime 签名后的 `Koe` 启动立即被 `dyld` 中止（`mapping process and mapped file (non-platform) have different Team IDs`）。根因是 PR #774 为 Android 在 `crates/koe-host-api/Cargo.toml` 增加了 `"cdylib"`，导致 macOS `cargo build` 同时在 `target/{debug,release}/` 生成 `libkoe_host_api.dylib` 与 `libkoe_host_api.a`；SwiftPM 仍用 `-L<root>/target/{debug,release}` 加 `.linkedLibrary("koe_host_api")`，Apple `ld` 同目录优先选 `.dylib`，把未签名构建目录路径写进了 `LC_LOAD_DYLIB`。
- 修复：`platforms/macos/Package.swift`（`Koe`、`KoeMacHostTests`）与 `platforms/apple-shared/Package.swift`（`KoeAppleCoreTests`、`KoeMacUITests`）去掉 `-L.../target/{debug,release}` 与 `.linkedLibrary("koe_host_api")`，改为按配置显式传入 `\(repoRoot)/target/{debug,release}/libkoe_host_api.a`；`scripts/install-macos.sh` 在 `swift build` 后及签名前运行 `otool -L`，只要 `LC_LOAD_DYLIB` 命中 `libkoe_host_api` 或仓库 `target/` 目录即刻失败。
- 验证点：`python3 scripts/test_install_macos.py` 的 `test_static_host_api_link_guard_rejects_dylib_and_accepts_static_macho` 与 `test_apple_swiftpm_manifests_link_static_host_api_archive` 改前失败、改后全绿；`otool -L platforms/macos/.build/release/Koe` 仅含 `/System/Library/...` 与 `/usr/lib/...` 系统库；`./scripts/release-macos.sh --dry-run` 通过 Hardened Runtime 签名、`--verify-self` 与 `--smoke-test`。
- Seen 1x（2026-11-21）。

### Dock 图标要核对不透明轮廓，启动时保留系统处理

- 出处：2026-11-10 用户发现 Koe 与 Micro Input 在 Dock 中比相邻图标大一圈；两者的图案占画布 90%，启动时直接加载原始 ICNS。
- 修复：保留原图，将打包轮廓改为 1024 画布中的 824 像素，并按原比例缩放圆角；启动时经 `NSWorkspace.icon(forFile:)` 获取系统图标。
- 验证点：`swift scripts/verify-app-icon.swift build/macos/AppIcon.iconset` 比较 128/256/512/1024 四档轮廓与系统 Mail 图标，改前四档失败、改后通过；安装包 ICNS 再读回确认边界为 (100,100)–(924,924)。GUI 能启动不代表已截图核对 Dock。
- Seen 1x（2026-11-10）。

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
- 验证点：用 [移动端 E2E 验证器](../../scripts/verify_mobile_e2e.py) 核对编辑器关闭、目标页面和持久化结果。硬规则 9 保留等待最终 I/O 的要求；旧 Dart 实例见归档。
- Seen 3x (2026-10-16, 2026-10-19, 2026-10-22)；10-19 同日三起只算一次。2026-10-22 第 3 个不同日子出现，已升为 AGENTS.md 硬规则 9（真机场景同样适用）。

### 全局主题改动要在真实界面逐类组件看一遍

- 出事：`lib/theme/app_theme.dart` 一直用 `base.copyWith(textTheme: TextTheme(...))` 拿一个全新的 TextTheme 覆盖基础主题（首个提交 43befb5 就这样写，10-19 UI 规范系列 #259 f467144 外面又包了一层 `_tabular`）。`headlineSmall` 等没定制的样式因此没有颜色，所有 AlertDialog 标题在 iPhone 和 Mac 上都是空白。这个写法在 1.2.2 之前的发布版（1.1.0、1.2.0、1.2.1）里都有，到 10-19 1.2.1 真机复测才发现（#306）。哪个版本、哪个提交开始真正显示空白，待核实。
- 修复：3046034（#309，在基础 textTheme 上 `copyWith`，随 1.2.2 发布）；#308 在 1.2.2 上用 iPhone 和 Mac 安装版复测，对话框标题可见。
- Done right: #309 加了 iOS/macOS × 浅色/深色 4 条回退测试（改前标题颜色为 null），#308 再用 `scripts/mac-ax` 和 iPhone 截图在真实界面确认标题。以后改主题时，把对话框、菜单、输入框等每类组件都在真实界面截一遍图再合。
- 验证点：原生改动按受影响的宿主在真实对话框、菜单和输入框取证，核对标题、颜色与可访问性。Flutter 的四组合测试见归档。
- Seen 1x (2026-10-19)

### 验收记录只写有证据的操作，不替用户补全没看到的步骤

- 出事：#255（c9fd4f3）把 #231 复测写成「没人按键、录音豆自己结束文件」，实际是用户 13:55 左右按录音豆实体键结束了录音；结论因此把「补取成功」错归给了自动结束。
- 修复：57b9a5b（#256，依据用户确认的操作和当时的 BLE 日志更正；补取成功那次日志为 `head … size=1195200`）。
- Done right: 验收结论里每一步用户或设备操作都要指向日志、截图或用户原话；看不到的写「待核实」，先问再写。
- 验证点：
- Seen 1x (2026-10-19)

### 本机跑测试前清掉 shell 里的云端密钥环境变量

- 出事：2026-10-21 #337 本机五条「未配置」回归受 shell 中的云端凭据影响而失败，CI 正常。2026-10-22 #344 反向暴露问题，凭据掩盖了冷启动读回空值。
- 修复：在隔离环境复跑，给配置读取测试显式提供替身。未读取或打印凭据值。
- 验证点：`scripts/verify-local.sh` 在启动契约与编译验证前清理云端凭据变量。涉及凭据的 Rust 回归使用隔离适配器，签装读回单独验收。
- Seen 2x (2026-10-21, 2026-10-22)

### 真机场景不能假设 Pixel 停在解锁的桌面：充电时会进屏保，锁屏要 PIN

- 出事：2026-10-22 #344 快捷方式场景头一次真正在 Pixel 上跑（#347 到 #354 的场景提交时 Pixel 都离线；#345 的记录里，之后只有 credentials_test 在真机上跑通过），接连失败。`moveTaskToBack` 后 Koe 的生命周期一直是 resumed：手机充电，息屏 30 秒就进时钟屏保（`com.google.assistant.hubui` 的 `EverydayClockDreamService`），Koe 留在屏保后面，只收到 `wm_on_top_resumed_lost_called`。改按 Home 键后，屏保一退就露出锁屏；锁屏要 PIN，`wm dismiss-keyguard` 解不开。点快捷方式时 Koe 只在锁屏后面恢复一下又暂停（`wm_pause_activity … sleep`、`wm_set_keyguard_occluded [0,0,0]`），麦克风前台服务被拒：logcat 里服务本身获准启动（`ACTIVITY_VISIBILITY_GRACE_PERIOD`），但 uidState 是 `TPSL`（置顶但在睡眠）、`allowWiu:-1`，接着报 `can not have location/camera/microphone access`，`startForeground` 抛 SecurityException。
- 修复：`KOE_ADB: home` 先 `wake-screen` 再按 Home，场景等 Koe 真进了后台。原生状态加 `deviceLocked`（`KeyguardManager.isDeviceLocked`）；手机锁着时场景打印 `KOE_ADB: skip <原因>` 并跳过，`scripts/android-check` 以 77 退出：记为跳过，不算通过也不算失败。试过离屏 8 秒后再点快捷方式，锁着时照样被拒。手机解锁后同一场景通过，logcat 里是 `uidState: TOP`、`code:PROC_STATE_TOP`、`allowWiu:12`。
- 跨运行也一样（同日）：#360 让一次运行里的锁屏场景排最后，但锁屏场景一关屏手机就要 PIN，一次解锁只够一个锁屏场景跑通。10:31–10:39 在 main cd25be1 上整套跑，最后的手机录音锁屏场景 10:36:53 关屏；10:38:37 `dumpsys trust` 已是 `deviceLocked=1`，当时 `settings get secure lock_screen_lock_after_timeout` 为 null（默认）。紧接着拿到设备的另一次运行（#366 的两个新场景）开头就打印「手机锁着」，构建完被停下；不停的话两个场景都会跳过。
- Done right: 写需要 Koe 在屏幕上的场景前，先用 `adb shell dumpsys power`（`mWakefulness`、`mDreamsActivateOnSleepSetting`）和 `dumpsys trust`（`deviceLocked`）看设备实际状态；失败时看 `adb logcat -b events` 里 `wm_pause_activity` 的原因，和 `ActivityManager` 对前台服务的判定（`uidState`、`allowWiu`）。没人值守解不开 PIN 锁屏：要 Koe 在屏幕上的场景，手机锁着时跳过。排队等设备的运行先读 `dumpsys trust`，`deviceLocked=0` 才开跑；要在一次解锁里跑完，就把不锁屏的场景和至多一个锁屏场景放进同一次运行。
- 验证点：开始 Android 物理测试前观察设备确实处于场景要求的解锁状态，并分别记录可执行项目和等待解锁的项目。旧测试入口见归档。
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
- 验证点：运行 [移动端 E2E 脚本契约测试](../../scripts/test_run_mobile_e2e.py) 核对当前入口；真机和 GUI 场景以无帧、锁屏或运行失败的实际证据区分原因。旧 Flutter 性能驱动见归档。
- Seen 1x (2026-10-23)

### 修一个页面的布局缺陷，要把同写法的页面一起查

- 出事：2026-10-19 #260 发现资料页上滑后分段控件进了状态栏，#265 只给资料页加了只让顶部的 `SafeArea`。今日页、项目页同样是 `GradientScaffold(child: ListView(...))`，页头自带的状态栏留白随列表滚走；设置页的返回键是叠在列表上的 `Positioned`。同类缺陷一直留到 2026-10-22 在 Pixel 上跑 Artemis 冒烟测试、逐张看截图才发现（#384），Artemis 自己给的结论是 PASS。
- 修复（#384）：今日页、项目页加只让顶部的 `SafeArea`，设置页的返回键移到列表上方单独一行；没滚动时各元素位置不变。
- Done right: 修布局缺陷前先 `rg -n 'GradientScaffold\(' lib/ui` 列出同写法的页面逐个确认（有 AppBar 的、页头固定不随列表滚动的不受影响），回退测试一次覆盖所有同写法的页面。冒烟或探索式测试的 PASS 不看画面，截图要自己逐张看。
- 验证点：在受影响的原生页面分别检查安全区、滚动位置与弹窗。窄屏和横屏取证见本台账最后的移动端操作条目；旧 Flutter 断言见归档。
- Seen 2x (2026-10-19, 2026-10-22)

### Mac 验收用 System Events 点菜单可能没送达，退出改发给进程的退出事件

- 出事：2026-10-23 #427 评审修复的验收里，用 System Events 点菜单栏「退出 Koe」和主菜单「Quit Koe」，AppKit 日志里都没有 `terminate:`，退出没有发生。
- 修复：给这个进程发退出事件：`NSRunningApplication(processIdentifier:)` 的 `terminate`，和 ⌘Q、菜单「退出 Koe」走同一个 `terminate:`，进到 `macos/Runner/AppDelegate.swift` 的 `applicationShouldTerminate`。不按 bundle id 发，因为用户装的 Koe 和开发版是同一个 bundle id。
- 验证点：核对目标进程的退出事件与 `platforms/macos/Sources/Koe/KoeMacApp.swift` 的 `applicationShouldTerminate`，并等到进程退出或报告保存阻塞。
- Seen 1x (2026-10-23)

### `pmset -g assertions` 不显示中文的防睡眠原因

- 出事：#403 验收时，Koe 的防睡眠声明在 `pmset -g assertions` 里原因是空的，原因当时写的是中文。
- 修复：#427 改用英文原因（`lib/ui/mac_menu_bar.dart` 里的 `keepAwake = 'Koe is recording'` 等）。
- 验证点：当前原因在 `platforms/macos/Sources/Koe/NativeActivity.swift`。签名版录音时用 `pmset -g assertions` 核对该进程的防睡眠条目。
- Seen 1x (2026-10-23)

### 格式化改过的文件前，先看它在 HEAD 上是不是已经格式化好的

- 出事：2026-10-23 #407 给 `test/phone_recording_test.dart` 加测试后跑 `dart format`，整个文件被重排，新测试淹在几百行无关的格式改动里。这个文件在 main 上本来就没格式化好（main bb19383 上单独格式化它，增 282 行、删 309 行）：本机和 CI 同为 Flutter 3.47.7，main bb19383 上 `lib`、`test`、`integration_test` 的 354 个 Dart 文件里有 31 个 `dart format` 后会变；CI 和 `scripts/check` 不查格式。
- 修复：文件恢复成 HEAD，只把新加的块按格式手写进去。
- 验证点：先核对 HEAD 对应文件，再用 `git diff --stat` 检查是否混入无关格式变更。Dart 命令与当时的基线数据见归档。
- Seen 1x (2026-10-23)

### 认录音豆用经典地址，不用会轮换的 BLE 地址

**全天常驻、绑定与在场判断按厂商数据里的经典蓝牙地址认录音豆；连接才用扫描到的当前 BLE 地址。不要用可解析私有地址当身份，也不要靠系统伴侣在场监听去匹配关联时的 BLE 地址。**

- 哪个 commit/issue 出的事，后果：#422（f065809，2026-10-23 09:05 Asia/Shanghai）合并「全天常驻」：按绑定录音豆的蓝牙地址做 CDM 关联与 `_syncResident`，系统在场监听也按关联时的地址匹配。② 写明「未在真实环境验证 #393 的功能本身」。同日 #345 真机验收发现 D3200 至少每次 Wi‑Fi 导出后换一个可解析私有地址、经典地址不变：全天常驻被悄悄撤销、系统不再唤起 Koe、重连先对旧地址空等约 100 秒（`scanResults` 还回放上次扫描）。
- 修复的 commit：#451（28b1070）按经典地址认设备，用 PendingIntent 厂商数据扫描替换系统在场监听，连接记最新 BLE 地址；回退测试在 main（b6b0ae5）上 `expect(controller.resident, isTrue)` 失败、改后通过。#452 进度页记 #345 第二部分真机：换地址后直接连新地址、常驻与关联仍在。
- Done right: 涉及「是不是同一台录音豆」的逻辑只比经典地址；写回退测试时让录音豆换 BLE 地址再回来，断言常驻仍开、连的是新地址。合并前至少在真机上做一次 Wi‑Fi 导出后再看常驻是否还在（#345 已暴露）。
- Seen 1x (2026-10-23)
- 验证点：旧 Android 常驻实现和地址轮换回归保留在归档。当前改动涉及设备识别时，真机分别核对设备身份与重连地址，参考 Android 物理验收 #777。

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
- 证据：同一安装包直接启动 authorized=0、系统启动 authorized=1；提交事件前后 matches=0/1。去掉临时诊断重新签名安装，12:45录音会议命名及重启保留通过。见 #453 验收记录。
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
- 验证点：按 #475 复盘与规划 使用授权测试记录核对；每个客户端有独立结果，过期/撤销和越权明确失败，不将工具数量视为数据操作通过。
- Seen 1x (2026-11-03)。

### 外部 AI 接入界面严禁写死或回显个人 VPS 域名与邮箱，且不设人工输入框

- 出处：2026-11-07 用户在准备桌面端与 iPhone 端实机验收时发现，「设置 → 外部 AI 连接」弹窗中不仅要求手动填写 VPS 地址、邮箱与验证码，还直接在 `hintText` 和已连接卡片上显示了用户的真实个人 VPS 域名与私人邮箱，造成隐私泄露风险与多余填写负担。
- 修复：移除 `_ExternalAiDialog` 中全部 `TextField` 手动输入框及所有写死域名/邮箱，`McpSyncConfig.redactedLabel` 仅显示脱敏连接模式（`VPS 云端已连接` / `Mac 局域网已连接`），绝不在界面回显 URL 或邮箱；新增 `mcp_pairing.txt` 自动投递绑定机制与面向仓库 `tools/koe-mcp/README.md` 的通用 Agent 提示词，支持插电脑 AI 直读/直写或一键剪贴板粘贴。
- 验证点：旧远程配对、界面入口和 Flutter 验证已归档。现有本地 MCP 及诊断导出应继续核对私有信息的输出边界。
- Seen 1x (2026-11-07)。


### iOS 验收必须保留截图元数据并驱动真实页面入口

- 出处：2026-11-05 Slice B，iOS 业务断言通过但验收脚本因缺少截图返回失败；测试写入 reportData 时覆盖了 takeScreenshot 的元数据，直接挂载纪要页也未覆盖生产导航。
- 修复：合并已有 reportData，从 RecordingDetailScreen 经摘要与分析进入结构化纪要；独立驱动器同时保存截图与行为证明，入口缺任一证据均非零退出。
- 验证点：使用 [iOS 模拟器验证脚本](../../platforms/ios/verify-simulator.sh) 的活体与失败取证，核对导航入口、截图和行为断言。Flutter 验收脚本已归档。
- Seen 1x (2026-11-05)。

### 自动整理等待录音和 ASR 收尾

- 出处：2026-11-05 Slice C，录音过程中已登记的路径提前进入自动整理，部分文字未落盘时待办提取失败；重复停止或下一场开始还会提前清除旧场收尾状态。
- 修复：完整整理等待录制、暂停、ASR 与音频转换结束；同场共享一次收尾，旧场末句仅保存到旧记录。Apple 收尾失败且已有部分文字时，明确重试会重新转写完整音频。
- 验证点：当前 Rust 路径参考 [实时纪要集成测试](../../crates/koe-runtime/tests/continuous_live_minutes.rs)。Flutter 异步场景已归档；真实重启与实体按键分别验收。
- Seen 1x (2026-11-05)。

### 自动发布验收必须由生产写入触发，不能由测试代发通知

- 出处：2026-11-05 Slice D，持续 MCP 客户端测试若手动调用 notifyListeners，会遮住 rememberTranscript 不通知导致的旧文字；授权等待中关闭还会恢复计时器。
- 修复：生产转写写入显式调度发布，授权每个 await 后复核关闭状态，撤销清空发布及旧内容错误。
- 验证点：当前 MCP 回归经 [CLI 集成测试](../../crates/koe-cli/tests/commands.rs) 核对 stdio 与本地 RPC 的实际读回。旧发布场景与失败记录已归档。
- Seen 1x (2026-11-05)。


### macOS SwiftUI `.buttonStyle(.plain)` 必须显式指定 `.contentShape(Rectangle())` 且安装包必须打包 `AppIcon.icns` 与 `applicationDockMenu`

- 出处：2026-11-09 用户在 `/Applications/Koe.app` 真机界面体验时反馈左侧栏切换极卡、点击经常无响应，且 Dock 栏图标退化为系统默认白格占位图、Dock 右键菜单缺失。
- 修复：(1) 为 `SidebarView.swift`、`DesignKit.swift`、`InfoTip.swift`、`TodayBentoView.swift` 与 `PlayerBarView.swift` 中所有 `.buttonStyle(.plain)` 按钮补齐 `.contentShape(Rectangle())` 与 `.frame(maxWidth: .infinity)`，消除 AppKit 对 `Color.clear` 和 `Spacer()` 空白区域丢弃点击事件的热区死角；(2) 在 `HostSessionStore` 增加直达属性 `activeSection` 并在 `CopilotDrawerView` 绑定 `.id(store.activeSection)` 与独立「心力格式 / 顺带会议」视图分支；(3) 在 `scripts/install-macos.sh` 调用 `scripts/generate-app-icons.swift` 与 `iconutil -c icns` 将 `assets/artwork/koe-schoolgirl-b-cheerful.png` 打包为 `Contents/Resources/AppIcon.icns` 并写入 `Info.plist` `CFBundleIconFile`，同时在 `KoeAppDelegate` 实现 `applicationDockMenu(_:)` 与 `applyBundledApplicationIcon()`。
- 验证点：`swift test --package-path platforms/macos` 断言 `applicationDockMenu` 返回 13 项菜单且 5 个侧边栏分栏切换立即同步 `activeSection`；`/Applications/Koe.app/Contents/Resources/AppIcon.icns` 存在且签名验证通过。
- Seen 1x (2026-11-09)。

### macOS SwiftUI + AppKit + `@Observable` 必须做右侧空白像素点击验收、按切片解耦观测、过滤状态栏/气泡窗口且 `⌘W` 不退出进程

- 出处：2026-11-09 对抗式排查（`/interrogate` + `/correct`）发现多处「编译与语义 `AXPress` 全绿但真人上手残缺」隐患：(1) `.contentShape(Rectangle())` 若写在 `.buttonStyle(.plain)` 外层或尺寸过小（如 16pt `?` 气泡、无右侧留白的短时间轴标签），空白像素点击仍会漏点；(2) `HostSessionStore` 所有视图直读单一 `store.snapshot` 且 Rust `poll_timers`/`ingest_ble_chunk` 空转也递增 `generation`，导致时间轴拖拽或定时器空转触发整树重绘；(3) `KoeWindowPresenter` 未过滤 `NSStatusBarWindow`/`NSPanel`、弱引用 `cachedWorkspaceWindow` 未设置 `isReleasedWhenClosed = false`，且 `applicationShouldTerminateAfterLastWindowClosed` 在默认 `keepAliveEnabled == false` 时返回 `true`，导致按 `⌘W` 直接杀死进程或点 Dock 无法恢复原窗口；(4) `CopilotDrawerView` 未渲染 `copilotAnswer`、输入框缺 `.onSubmit`、`PlayerBarView` 打重点标记误传 `durationMs + 1000`、`心力格式` 与 `顺带会议` 页面内容重复、跨重启未持久化 `workspace_session.json`。
- 修复：(1) `verify-ui-principles.py` 强制校验每个 `.buttonStyle(.plain)` 的 `label` 闭包内部含 `.contentShape(Rectangle())`、每个 `TextField` 含 `.onSubmit`、`KoeMacApp.swift` 含 `isWorkspaceWindow`；(2) `HostSessionStore` 拆分为按域细粒度 `@Observable` 属性，Rust 空转不递增 `generation`；(3) `KoeWindowPresenter` 强持有 `cachedWorkspaceWindow`、监听 `didBecomeKeyNotification`/`willCloseNotification` 设置 `isReleasedWhenClosed = false`，`applicationShouldTerminateAfterLastWindowClosed` 恒返回 `false`；(4) 补齐 `CopilotDrawerView` 回答展示、拆分 `FormatsView` 双页、修复 `SliceMark` 游标与 `AudioOnly` 时间轴槽位、实现 `workspace_session.json` 自动落盘与恢复。
- 验证点：`./scripts/check`（含 `scripts/test_verify_ui_principles.py` 32 项静态门禁单测、`KoeMacUITests`、`KoeMacHostTests`）全绿，且在 `/Applications/Koe.app` 上通过真实像素坐标点击各行/标签/时间轴右侧空白区域与 `⌘W` 后 `open -a` 恢复同一 `window_id` 验证。
- Seen 1x (2026-11-09)。

### 领域快照通过不等于产品管线已接通

- 出处：2026-11-10 #587 梳理既有 Rust 迁移，原门禁通过但实时 PCM 被丢弃、已返回云结果在保存失败时丢失，旧 UI 投影混用当前记录。
- 修复：ProductWorkspace/Store 作为唯一事实；按 record + attempt + input revision 回写；云结果保存成功才消费；有序采集事件、内容版本音频和统一导航。
- 验证点：`cargo test -p koe-runtime` 覆盖本地真实 HTTP/WS、stop 前 final、切换记录、落盘故障恢复及旧格式迁移；完整原生应用另走实际点击与磁盘回读，不以构建替代。
- Seen 1x (2026-11-10)

### 实时录音订阅 `1A/07` 文件头不可用 `file_size == 0xFFFFFFFF` 覆盖实时流状态，且停录必须自动刷新 `1B/0E` 并拉取未同步文件

- 出处：2026-11-10 用户真机连接 D3200 录音豆按下录音键说话再关掉后，macOS 端既无实时状态/字幕显示，关掉开关后也未出现任何录音文件。排查发现：(1) `session.rs` 处理 `1A/07` 文件头时用 `self.active_is_realtime = head.unfinished`（仅当 `file_size == 0xFFFFFFFF` 为真）无条件覆盖了实时流状态，真机在录音刚启动返回 `file_size == 0` 或当前字节数时把 `active_is_realtime` 覆写为 `false`，导致后续 `1A/08` 语音分片全部跳过 `CaptureEvent::Audio` 且停录不进入 2s 静默收尾；(2) 硬件停录（`18/81`、`18/82`、`1A/06` 的 `state == 0`）未自动下发 `1B/0E` 刷新目录，`koe-runtime` 也无自动 `1A/07` 离线取回闭环；(3) `live.rs` 丢弃了 `sentence_end: false` 的 `asr::Event::Interim` 流式中间句，且 `BluetoothBridge.swift` 以 0ms 间隔连发 BLE 写帧，易被固件丢包。
- 修复：(1) `session.rs` 在 `active_is_realtime` 或 `device_recording_active` 期间收到对应 `file_id` 的 `1A/07` 文件头时保持 `StreamingRealtime` 并派发 `CaptureEvent::Started`，硬件停录与 2s 静默收尾自动排队 `1B/0E`（`list_files_with_end_time(0)`）；(2) `koe-runtime` 按 `file_id` 绑定实时记录、收到 `Started` 立即落盘创建 `live-{file_id}` 记录，并在空闲时通过 `maybe_start_auto_offline_pull` 自动取回目录中未同步的已完成文件；(3) `live.rs` 转发非空 `Interim` 中间句并在 `UtteranceSpine::update_segment` 中原地更新文本与起止时间戳；(4) `BluetoothBridge.swift` 引入 `BleOutboundQueue` 按 300ms 节流发送 BLE 指令，并在 `TodayView.swift`/`SidebarView.swift` 展示实时录音时长、字节流与流式字幕预览。
- 验证点：`cargo test -p koe-engine -p koe-client-providers -p koe-runtime`（含 `realtime_lifecycle_emits_started_finished_preserves_stream_on_head_and_refreshes_catalog_on_stop`、`live_head_with_zero_size_creates_record_immediately_and_hardware_stop_finalizes_audio`、`hardware_stop_with_zero_live_slices_auto_pulls_offline_audio_into_live_record`、`interim_sentences_stream_as_live_events_before_sentence_end`）及 `swift test --package-path platforms/macos`（含 `bleOutboundQueuePacing`）全绿。
- Seen 1x (2026-11-10)

### 迁移身份和音频格式须沿旧版真实写入链核对

- 出处：2026-11-10 F1 独立审查发现，初版按 u32 解析所有数字文件名前缀，漏掉旧本地导入的 16 位微秒身份；又把设备裸 Opus 当成 Ogg 容器。简单 WAV 夹具通过不足以证明旧库可迁。
- 修复：保留 u64 历史身份，设备编号单独转换；识别 Ogg 与裸帧，裸帧直接用真实 libopus 完整解码，不能借 Ogg 包装器的 pre-skip 裁掉开头。人工原文按旧版行首规则应用说话人别名。
- 验证点：微秒身份、裸 Opus、人工别名的原始先红后绿证据已归档。已归档的迁移用例位于 `272a5a1^:crates/koe-runtime/tests/legacy_restore.rs`，夹具说明已归档于 `272a5a1^:crates/koe-runtime/tests/fixtures/flutter/README.md`。
- Seen 1x (2026-11-10)。

### 安全存储重试不能解除工作区的未知提交状态

- 出处：2026-11-10 N1（#602）独立评审发现，凭据清除后的目录持久化屏障失败时，重试安全读取会从旧内存绑定恢复密钥并错误显示已配置。退休项逐个删除成功后，若不保存剩余项，也会反复授权已删除引用。
- 修复：`ProductStore.requires_reopen()` 保持不可由安全存储重试解除的门闩，只有关闭重开可恢复；删除清单保存实际剩余引用，显式重试每次最多授权一个当前或退休项，退休项失败不废弃仍有效的当前凭据。
- 验证点：`cargo test -p koe-runtime --test provider_persistence` 用目录权限制造 rename 成功后的真实持久化屏障失败，并覆盖多个退休项的授权与删除恢复；这不替代 #603 的签名安装升级验收。
- Seen 1x (2026-11-10)。

### 本地 HTTP 夹具的接收连接须显式恢复阻塞读取

- 出处：2026-11-10 N4A（#607）首次全量门禁，`cloud_workflow` 的 HTTP 读取在 0.34 秒内返回 WouldBlock，未到设置的 5 秒读取期限。
- 复发：2026-11-13 #684 的 CI 在 `network.rs` 同类夹具失败；本机诊断读取在 19 微秒返回 WouldBlock，配置的 3 秒超时未生效。
- 修复：监听器保留非阻塞 accept 与总期限，接受的连接在读取 HTTP 正文前显式 `set_nonblocking(false)`，再设置读写期限；5a600bf 将同样约束补入 loopback chat 夹具，保留完整正文和无 Authorization 断言。
- 验证点：`cargo test -p koe-runtime --test cloud_workflow` 、`cargo test -p koe-client-providers --test network`（本轮 9 项通过）与 `scripts/check`；读取必须等到完整 Content-Length，不能把刚 accept 当成正文已经到齐。
- Seen 2x（2026-11-10、2026-11-13）。

### 停止确认必须有丢包后的重试路径

- 出处：2026-11-10，N2 独立评审发现停止回应丢失后，断线重连仍保留等待标记，却没有重发停止；取消退出后界面只给开始入口，Rust 拒绝开始，用户无法恢复。Seen 1。
- 修复：握手恢复后重发未确认的停止指令；快照明确正在停止并保留重试入口。重试只发指令，不重启已有尾音静默计时，仍须设备真实停止回应才能解除限制。
- 验证点：`cargo test -p koe-runtime lifecycle_tests` 中丢回应/重连/取消后重新开始，以及重复停止不延迟音频落盘的回归均先红后绿。证据见 PR #613。

### 重试修复音频字节不能抹去提前停录的事实

- 出处：2026-11-10 N3B 分路保管独立评审用 RLIMIT_FSIZE 复现部分写入失败；重试同块成功后，保存错误清除，提前停止的录音却被标为完整。全空收尾也曾覆盖权限拒绝的具体原因。
- 修复：分开保存错误与采集中断事实；每路中断随 ProductRecord 持久化，重试仅清保存错误；无记录可保存时保留各路失败原因。
- 验证点：`cargo test -p koe-runtime --test dual_capture_fault --test dual_capture`；真实短写只在独立子进程中注入，恢复限制后重试同一序号和字节，仍标记采集不完整。两个缺陷均有改前红灯，证据见 #619。
- Seen 1x（2026-11-10）。

### 新持久字段须穿过工作区重建全链路

- 出处：2026-11-10 N3B 补强重启测试后，磁盘 JSON 已有分路资产，但 `ProductWorkspace::restore` 二次重建 `ProductRecord` 时丢掉新字段；只查 JSON 和记录存在会漏验。
- 修复：工作区重建保留并重新验证 `capture_lanes`，测试直接检查重开后的业务对象、资产身份与时长。
- 验证点：`cargo test -p koe-runtime --test dual_capture independent_sequences_tail_barrier_and_reopen_preserve_both_assets`，改前重开 lanes 数为0、改后为2；不以codec序列化成功替代完整Runtime重开。
- Seen 1x（2026-11-10）。

### 采集代次必须覆盖终止和失败事件

- 出处：2026-11-10 N3B 时间轴子单元（#623）独立评审和行为回归发现，只给 PCM 块加 epoch 不能隔离暂停前的旧源；恢复后尚未出新块时，旧 stopped 序号恰好匹配，会把新代次提前终止，旧 failed 也会中断新录音。
- 修复：带时钟会话的 stopped/failed 同样要求当前 epoch；未标记或过期终止事件不改变状态。
- 验证点：`cargo test -p koe-runtime --test capture_timeline`，包括未标记终止回调先红后绿、恢复后旧 epoch 失败/停止回调与当前代次继续收样。
- Seen 1x（2026-11-10）。

### 稀疏音频回放要验证系统媒体输出和异步完成边界

- 出处：2026-11-10 N3B 分路回放子单元，AVFoundation 会丢弃 composition 末尾的空白区间，轨道 preferredVolume 也不能代替 AVAudioMix 的显式静音。只核对插入操作或时长不能证明真实输出静音。
- 修复：Rust 输出共同时间上的精确样本片段；原生用同源、显式静音的末尾播放标记保持共同末尾，不改原始 WAV。异步加载成功和失败都核对实时快照身份，显式新请求可重试读取失败。
- 验证点：`swift test --package-path platforms/macos --filter NativePlayback` 逐样本回读真实 PCM 的首部、内部与尾部静音，核对完整原文件不变；延迟加载失败、失败重试与无时间轴旧录音的回归均先红后绿。签名安装版听感和系统授权仍见 #620。
- Seen 1x（2026-11-10）。

### 暂停确认须纳入停源等待期间发生的失败

- 出处：2026-11-10 #629 原生暂停接线。进入停源前检查一次失败仍会漏掉 fence 等待期间的设备故障，随后误报 paused，WAV 未发布。
- 修复：设备变化通知与音频回调共用 fence；停源返回后再次交付本代次失败，再根据 Rust 最新阶段选择暂停确认或最终停止。
- 验证点：`swift test --package-path platforms/macos --filter NativeCaptureIntegrationTests/testFailureDuringPauseFenceSavesTailAndCannotBecomePaused`，最小逆补丁复现 paused 且无 WAV，修复后尾块字节落盘、保留中断事实并允许退出。日志在本轮 `n3b-platform/red-stop-failure.log` 与 `green-stop-failure.log`，仅隔离适配器验收，真实设备变化仍待 #620。
- Seen 1x（2026-11-10）。

### 未运行态 Dock 图标不能靠 `NSApp.applicationIconImage` 掩盖，无 `Assets.car` 时禁写 `CFBundleIconName` 且须同卷 `renamex_np` 原子互换后 `lsregister -f`

- 出处，2026-11-11 用户在 macOS 27.2 退出 `/Applications/Koe.app` 后发现 Dock 常驻图标退化为系统默认白格占位图，应用运行期因启动后设置了 `NSApp.applicationIconImage` 遮住了问题。实证根因有四处：(1) `scripts/install-macos.sh` 未编译 `Assets.car` 却在 `Info.plist` 写入 `CFBundleIconName = AppIcon`（LaunchServices 记为 `supports-asset-catalog (0x5)`）并向 `Contents/Resources/` 复制未留白的 `AppIcon.png`；(2) 安装时原地 `rm -rf "$TARGET"` 再非原子 `ditto "$APP" "$TARGET"`，把缺失或半成品包暴露给 Dock 目录监听；(3) 未注销 `build/` 下未签名产物且未对安装目标执行 `lsregister -f`；(4) 一旦占位图写入 `DARWIN_USER_CACHE_DIR/com.apple.dock.iconcache`，单独重启 Dock 仍会从磁盘读回旧位图缓存。
- 修复，(1) `scripts/install-macos.sh` 抽离 `write_info_plist()`，移除 `CFBundleIconName`（仅保留 `CFBundleIconFile = AppIcon`），构建时校验 `verify-app-icon.swift`、写入 `.metadata_never_index` 且不再复制 `Contents/Resources/AppIcon.png`；(2) 在 `scripts/cleanup_app_registrations.py` 统一收敛五种路径保护关系（含禁止 `..` 与软链越界、APFS 大小写及 Unicode NFD 归一化等价）、`libproc` `proc_pidpath` 进程拦截与 `renamex_np(RENAME_SWAP)` 同卷单系统调用原子互换及异常回滚；(3) 互换后执行 `lsregister -f "$TARGET"` 并在正式目录安装时清理 `com.apple.dock.iconcache*`，在 `verify-ui-principles.py` 剥离注释并解析内嵌 `Info.plist` 固守静态门禁。
- 验证点，`python3 scripts/test_install_macos.py`、`python3 scripts/test_cleanup_app_registrations.py` 与 `python3 scripts/verify-ui-principles.py --mode all` 通过；正式安装退出进程后查 `lsregister -dump` 确认 `/Applications/Koe.app` 的 `icon flags` 为 `relative-icon-path (0x1)` 且 `build/` 下无残留注册，重启 Dock 后在未运行态截图核对 Koe 与相邻应用圆角边界一致。
- Seen 1x（2026-11-11）。

### 原文修订与说话人合并不可用子串替换改写旧纪要，且磁盘重开须区分引用完备性与新稿数字防幻觉校验

- 出处，2026-11-11 Slice R2（#637）三模型对抗审查（`/interrogate`）发现两处重启损坏隐患：(1) 磁盘编解码若继续对已过期的历史纪要调用 `parse_meeting_minutes_json_for_spine` 逐句比对数字和薪资，用户一旦修改转写数字就会在下次 `ProductStore::open` 时拒绝打开整个工作区；(2) 批量合并说话人时若对旧纪要执行全局子串替换 `MeetingMinutes::replace_speaker_name`，不仅会把短标签（如 `"1"`）误替换进正文百分比和日期（`"100%"` 变成 `"张工00%"`），还会把接近上限的 `overview` 撑破 20,000 字符解析上限导致重启打不开。
- 修复，(1) 在 `minutes.rs` 拆分 `parse_persisted_meeting_minutes_json`（仅校验 `S1..Sn` 引用存在性与结构完备性）供持久化重开使用，新生成的模型返回仍走严格数字归属校验；(2) `ProductWorkspace::rename_speaker` 保持历史 `MeetingMinutes` 原文不变，通过 `minutes_revision < content_revision` 派生 `MinutesFreshness::Stale` 提示用户重算，并在运行时立即回收已被编辑超越的在途摘要槽位。
- 验证点，`cargo test -p koe-engine --test product_transcript_edit`、`cargo test -p koe-client-services --test product_store` 与 `cargo test -p koe-runtime --test transcript_edit` 覆盖改数字后重开、短标签 `"1"` 改名长名字后重开及摘要生成中改句立即重算，均先红后绿。
- Seen 1x（2026-11-11）。

### 实时流正面双击书签须钳位至已收音频时长并在解码层自愈

- 出处：2026-11-12 用户升级 `04.92` 固件后实测 D3200 录音豆重启应用打不开（`live-1794444326-1794444325-32` 报 `highlight exceeds duration`，`duration_ms: 27660`，`bookmarks: [12000, 27680]`）。根因为实时流 `1A/08` 切片正面双击生成书签时 `SliceMark::position_ms(seq)`（`seq * 20`）使用切片线序序号，中途丢片或迟入流时线序大于已接收帧数；`ProductWorkspace::finish_capture` 未作钳位直接落盘，`RecordDto::into_record` 启动时硬校验抛错导致整个工作区拒绝打开。
- 修复：(1) `koe-engine` 会话层的 `finalize_active_transfer` 将 `marks_ms` 映射至 `m.min(pcm_duration_ms)`（实际解码 PCM 时长，保证短录音书签落在真实音频区间与 880 Hz 提示音对齐）并排序去重；(2) `crates/koe-engine/src/product/record.rs` 的 `ProductWorkspace::finish_capture` 在 `duration_ms > 0` 时做双向钳位、`duration_ms == 0` 时保留书签防被压成 0；(3) `crates/koe-client-services/src/product_store_codec.rs` 的 `RecordDto::into_record` 移除硬校验改由 `a.add_bookmark(if a.duration_ms > 0 { timestamp.min(a.duration_ms) } else { timestamp })` 在解码层自愈既有持久化记录；(4) `crates/koe-host-api/src/lib.rs` 补充打开失败诊断输出。
- 验证点：`cargo test -p koe-engine realtime_transfer_clamps_out_of_range_marks_to_duration`、`cargo test -p koe-engine --test product_workflow` 与 `cargo test -p koe-client-services --test product_store` 覆盖线序超长、零时长保留及历史工作区自愈重开。旧迁移回归已归档。
- Seen 1x（2026-11-12）。

### D3200 目录分页与录音暂停恢复必须保护已有历史文件并按相对分片对齐

- 出处：2026-11-12 固件 04.92 真机联调（10 个历史录音），目录单页仅返回 10 条导致待命录音落在第 2 页被截断，误将第 1 页 0 ms 残留未闭合录音认作新待命文件；且录音处于暂停态（state == 2）时取回必返回 0xFFFFFFFF 未闭合头（#253），直接触发待命模式自动拉取死循环与闪存文件误删。
- 修复：Engine 实施 `0x1B 0x0E` 多页分页与 `raw_catalog` 全量去重，待命启动时快照 `pre_start_entries`，优先选取不在快照中的全新未闭合文件；暂停录音续接（state == 2 -> 1）按 `(duration_ms / 20) * 166` 相对分片偏移发送 `1A/07`，双击打标与回放采用相对时间；Runtime 增加 `can_own_as_standby_scratch` 属权门禁，暂停态（state != 0）抑制离线自动取回，`Failed` 阶段在用户刷新/切模式/手动下载时重置恢复。
- 验证点：`cargo test -p koe-engine --lib multipage_catalog_pagination_selects_new_open_file_on_second_page` 与 `resumed_open_file_computes_slice_offset_and_relative_marks`；`cargo test -p koe-runtime --lib collar_standby_disabled_pause_recovery_resumes_open_file_and_protects_pre_existing_files` 与 `failed_offline_pull_recovers_via_device_refresh_or_mode_switch_or_manual_download`。
- Seen 1x（2026-11-12）。

### 主动释放蓝牙后必须过滤 CoreBluetooth 尾部排队切片且重新打开自动连接须恢复扫描

- 出处：2026-11-12 固件 04.92 实机联调通过多页分页和 16 kHz 流式转写后，在 Step 5 执行 `release_ble` -> 重新打开 `autoConnect` 暴露两处边缘时序缺陷：(1) Rust 侧调用 `DeviceRuntime::disconnect()` 后至宿主主循环取消 CBPeripheral 之间可相差至多 250 ms，期间 CoreBluetooth 交付已排队的 `0x1A 0x08` 音频切片，因无有效文件编号强行兜底 `file_id = 1` 触发假离线取回并最终超时进入 `TransferPhaseTag::Failed`，因连接已断开导致应用退出被死锁挂起；(2) 释放控制权清除了 savedBlePeripheralUUID，用户重新开启「自动连接」时宿主未感知 `false -> true` 跃迁触发扫描，导致录音豆无法自动重连。
- 修复：(1) Engine 彻底删除 `active_file_id.unwrap_or(1)`，未激活文件编号时严格丢弃孤儿音频切片；Runtime 增加 `explicitly_disconnected` 状态位，在 `disconnect()` 中置 true，并在 `scanning` / `connecting` / `ready` 时复位；`DeviceRuntime::ingest()` 首行门禁主动断开态拦截残余切片；(2) `BluetoothBridge` 拆分传输模型至 `BleTransportModels.swift` 并增设 `isHostActivated` 宿主激活权与扫描计数，在 `syncWithRuntimeDevice` 中检测 `wasAutoConnectDisabled && device.autoConnect` 并在中央管理器上电时调用 `startScanningIfPoweredOn()`；`applicationDidFinishLaunching` 在冷启动时主动调用 `bluetoothBridge.activateHost()`。
- 验证点：`cargo test -p koe-engine orphan_slice_without_active_file_id_is_ignored_and_never_creates_phantom_file`；`cargo test -p koe-runtime release_ble_ignores_late_queued_ble_slices_and_allows_immediate_quit` 与 `failed_phase_survives_5s_poll_blocks_quit_and_clears_on_cancel_quit`；`swift test --package-path platforms/macos` 验证 `reenableAutoConnectAfterReleaseControl`、`activateHostHeadlessRequestsScan` 与 `manualScanHeadlessRunsOnceWithoutDoubleCancelling`。
- Seen 1x（2026-11-12）。

### 指定 QA 工作区不等于隔离蓝牙设备

- 出处：2026-11-12 浅色色板 #652 验收，带 `--workspace-root` 的测试副本仍按默认 `ble_auto_connect=true` 自动连接附近 D3200 并取回文件。
- 修复：立即停止测试副本，在测试工作区明确关闭自动重连；本轮 QA 启动器在启动前检查该值必须为 false。未修改日常工作区。
- 验证点：运行完整宿主前确认测试工作区 `ble_auto_connect=false`，启动后在设置页回读“未连接”和未勾选的自动重连。凭据隔离不能代替硬件隔离。
- Seen 1x（2026-11-12）。


### 隔离自检不能占用日常通信入口，退出不能依赖路径仍存在

- 出处：2026-11-12 浅色版安装验收，旧版在取回保存完成后仍无法退出。进程采样显示主线程等待 BridgeServer::drop 的 join，监听线程阻塞于 accept。旧进程持有监听描述符，但 socket 路径已不存在（#657）。
- 根因：容器 Data 下所有工作区都映射到同一日常 socket，自检临时工作区也会删除该路径；退出通过路径 connect 唤醒 accept，失败后仍无限等待。
- 修复：仅正式默认工作区映射短路径；其他工作区独立解析。非阻塞 accept 通过线程唤醒和有界等待检查关闭状态，清理仅删除身份匹配的 socket。
- 验证点：删除路径后会话销毁可结束、普通文件不被替换、隔离工作区不映射日常入口。
- Seen 1x（2026-11-12）。

### 原生实时识别的结果流错误必须在录音中立即交付

- 出处：2026-11-12 #653 离线字幕独立审查。SpeechTranscriber 结果 reader 已失败时，旧实现只在 finish 等待 reader，导致录音继续而字幕停住。
- 修复：结果回调使用 Result，错误绑定 operation 与 epoch 立即交给 Rust，先失效当前操作，再由独立任务取消识别器，避免 reader 等待自己。首次模型准备遵循 AssetInventory.reserve 的幂等语义，返回 false 只表示已预留，不当作失败。
- 验证点：NativeLocalTranscriptionTests 的录音中及 finish 中 reader 故障测试。主回归改前 5 项断言失败，改后 9 项原生测试通过；禁止 outbound IP 的真实 Apple 识别器测试在停止输入前收到中文临时结果。
- Seen 1x（2026-11-12）。

### 恢复音频先提交归属，再释放恢复检查点

- 出处：#661 独立运行时审查发现恢复流程在工作区提交前删除 `.capture`，提交失败后再次启动会失去恢复入口。
- 修复：`CaptureAsset::recover` 保留检查点；Runtime 完成 metadata 提交后调用 `release_recovered`。提交失败仍能重试同一份录音。
- 验证：恢复提交失败、重开及退出重试行为回归通过。
- Seen 1x (2026-11-13)

### 暂存应用仍会保留包内目录软链

- 出处：2026-11-13 #665 许可打包独立审查，真实 `ditto` 与安装器回归复现 `Contents` 或 `Contents/Resources` 软链导致暂存包外的许可文件被删除并重写。
- 修复：签名前更新许可目录前，拒绝这两个父目录为软链；源包和安装目标的顶层路径校验不能替代包内写入路径校验。
- 验证点：`test_skip_build_rejects_symlinked_license_parents_without_modifying_external_files` 在修复前两个子场景失败，修复后拒绝安装且外部许可原样保留。
- Seen 1x（2026-11-13）。

### 主功能入口不能只剩工具栏快捷方式

- 出处：2026-11-13 一天一页收敛后，用户明确要求保留「问 Koe」独立板块，并增加专门的实时纪要区域。上一版只保留顶部问答入口，不能替代可发现的主导航。
- 修复：恢复问 Koe 主导航，实时纪要提供独立路由，实时原文和已生成纪要分开投影与展示。
- 验证点：原生窗口从侧栏进入问 Koe 和实时纪要，验证问答来源返回、录制跨页与停止后内容归属。Dock 菜单测试同步产品入口。
- Seen 1x（2026-11-13）。

### 传输结束不等于文件解密身份结束

- 出处：2026-11-13 #668 自动真机验收。第一次录音正常，停止后复用同一设备文件号的第二次录音丢失解密上下文，2225 包中1311包无法解码；文件存在和保存提示掩盖了音频损坏。错误头另会清掉活动录音，造成全天收尾一直等待。
- 修复：文件解密材料按文件号保留，连接会话结束时清除；无有效材料的完整加密头不能启用明文路径。实时传输错误保留录音身份与排空计时，正常停止后保存已收到的音频。
- 验证点：session.rs 的 repeated_realtime_capture_decrypts_without_fresh_file_key_wrapping、encrypted_head_without_valid_context_does_not_publish_ciphertext_as_audio 和 repeated_file_decrypt_context_is_isolated_by_file_and_connection 均先红后绿；capture_tests.rs 验证错误前后停止、保存重开和无音频终结。真机录音逐包解码并比较 WAV 采样数，不能只检查文件存在。
- Seen 1x（2026-11-13）。

### stdio 集成测试发送请求时必须同时排空子进程输出

- 出处：2026-11-13 PR #677 的 CI 停在 `live_host_session_serves_cli_and_full_mcp_stdio_over_bridge_without_lock_conflict`；两次进程采样均显示测试线程等待 `ChildStdin` 写入、MCP 子进程等待 stdout 写入，父进程尚未开始读取响应。
- 修复：现有请求数组由独立线程写入并在结束时关闭 stdin，主线程同时通过 `wait_with_output` 读取 stdout/stderr，随后 join 写入线程；保留全部九条响应与持久化结果断言。
- 验证点：`cargo test -p koe-cli --test commands live_host_session_serves_cli_and_full_mcp_stdio_over_bridge_without_lock_conflict` 完整结束并通过；不能依赖请求数量少就先同步写完再读取响应。
- Seen 1x（2026-11-13）。

### 语音输入入口必须同时准备待命和连接外部输入法

- 出处：2026-11-13 用户纠正首页与语音输入入口。旧首页展示录音摘要，语音输入只启动 Koe 采集，未准备领夹待命或连接 Responsay。既有 dev socket 配置也被进度误写成默认 socket 缺失的当前阻塞。
- 修复：`b050935` 在 Rust 统一准备待命和自动连接，经宿主动作打开 Responsay；Responsay `a4052255` 增加 Release URL 入口并保留 socket override。首页只移除录音与摘要展示，不删除记录。补丁独立审查 PASS，尚未安装验收。
- 正确做法：从用户点击入口跟到待命和外部音源选择，核对实际配置。分别记录源码实现、已安装版本和真实识别输入证据。
- 验证点：`navigation_tests` 与 `companion_mcp_tests` 验证记录重开、已有待命和录制保护；`NativeHostActionsTests` 验证固定 URL 与失败重试。真实 ASR、原光标输入与物理双击继续保持未验收。
- Seen 1x（2026-11-13）。

### 普通录音的默认用途不能继承显式模式或持久路由

- 出处：2026-11-13 #685 用户定稿普通录音键默认随心闪记；原默认回落 Meeting，普通采集也进入持续纪要，旧领夹配置重开会自动开录。
- 修复：普通采集默认 QuickNote，显式会话才建立持续纪要 scope；保留普通最终转写与摘要。本次 companion 启用状态只在 runtime 生效，真正会话结束后释放，持久配置保持。
- Done right：分开保存的配置、本次启用授权与已有会话的收尾。撤销新会话授权不能截断 quiet-drain 尾音，也不能把下一段普通录音音频混入旧租约。
- 验证点：capture_tests 的物理通知默认、显式会议结束后普通开录、全天结束回归；continuous_live_minutes 的 quick_note 不持续整理但停止后有摘要；companion_mcp_tests 的冷启动及停止回应后尾音。协议夹具不等于实体按键验收。
- Seen 1x（2026-11-13）。

### 指定麦克风启动须使用物理输入格式，不能把过期格式当成设备变化

- 出处：2026-11-13 #668 真机验收、#674 修复。指定麦克风启动时仍用过期的输出格式协商采集，被误判为设备变化并中断录音。
- 修复：`NativeAudioSource` 改读 `node.inputFormat(forBus: 0)`，仅在引擎、设备或格式真正变化时停止采集。
- 验证点：`testSelectedHardwareInputDeliversPcmThroughStartupConfigurationChange` 在启动配置变化后仍交付指定硬件的 PCM；修前物理输入测试的采样率、PCM 与通知断言失败，修后两个音源通过。真机证据见 PR #674。
- Seen 1x（2026-11-13）。

### 安全启动器注入的环境凭据必须被原生适配器按导入协议消费

- 出处：2026-11-13 #668 真机验收、#674 修复。安全启动器已把 `KOE_CREDENTIAL_SOURCE` 与 `DASHSCOPE_API_KEY` 注入进程环境，原生适配器未消费，新工作区表现为未配置，也无法用启动器凭据完成 ASR。
- 修复：`NativeCredentials` 识别 `KOE_CREDENTIAL_SOURCE=environment`，沿用 Rust 导入、保存、清除协议，不回退个人 Keychain。
- 验证点：`environmentLifecycle`（`Explicit environment credentials configure a new workspace, survive restart and respect clear`）覆盖首次导入、重启保留与清除后不再回读环境密钥；密钥不得写入工作区快照。
- Seen 1x（2026-11-13）。

### 保存密钥须先登记引用再写入安全项，避免提交前中断留下孤儿

- 出处：2026-11-15 #714（`92692a7e`），对应 #604。保存 API Key 时若进程在「新安全项已写入、工作区引用尚未提交」之间被终止，系统安全存储会留下无人引用的秘密。
- 修复：改为先登记、后写入、再一次提交提升。平台 `prepare` 只分配新引用（macOS 生产路径只生成 UUID，不调用 Keychain），ProductStore 写入 `provider.pending_credentials` 并提交；`create(reference, secret)` 在该引用上创建并读回校验，失败时确认删除后才移出 pending；一次提交把引用设为 `Saved`、旧引用移入 `retired` 并移出 pending。启动与重试清理按引用精确删除 pending/retired，不扫描、不枚举 Keychain。
- 验证点：`real_sigkill_after_create_reclaims_orphan_without_touching_other_workspace_or_legacy`、`pending_orphan_delete_failure_retries_with_explicit_authorization` 与 Swift `A secure item created before a crashed workspace commit is reclaimed on reopen` 均先红后绿。未在真实环境验证，没有运行签名安装包，也没有读写个人 Keychain。
- Seen 1x（2026-11-15）。

### SwiftUI @Observable 宿主存储须按变更频率切分属性并在关窗态门控离屏重排

- 出处：2026-11-16 #726（`815c8d3`），对应 #723。`HostSessionStore` 仅暴露单一 `@Observable` 属性 `snapshot`，叠加 4 Hz 定时器、逐块 `[Int16]` JSON 序列化投影及 `isReleasedWhenClosed = false` 缓存主窗口，导致播放进度或采集电平每跳都触发全工作区视图重算与关窗离屏 `NSHostingView` 重排。
- 修复：Rust 侧新增 `koe_host_session_ingest_pcm` 二进制采样快路径与 `trash_remaining_days` 24 小时阶跃水位线；Swift 侧将 `HostSessionStore` 按变更频率拆分为 `Equatable` 切片，仅 4 个叶子栏允许读取 4 Hz 切片并由 `verify-ui-principles.py` 静态门禁守护；`NativeCapture` 合并批次后再单次刷新；`KoeWindowPresenter` 在关窗及最小化稳态冻结 UI 切片广播并在恢复时同步追平；`CoreAudioInputMonitor` 用 HAL 属性监听替代 1 Hz 轮询。
- 验证点：`session_tests`、`ScopedObservationTests`、`OffscreenAndTimerTests`、`HardeningRegressionTests` 与 `test_verify_ui_principles.py` 均先红后绿；Release 基准关窗回放 40 拍耗时中位数从 `307.60 ms` 降至 `0.23 ms`，双路采集 20 拍 CPU 从 `696.66 ms` 降至 `131.30 ms`。
- Seen 1x（2026-11-16）。

### 移动端操作完成后，等目标页面和落盘结果再取证

- 2026-11-21，M10 在 iPhone 17 上复现了键盘弹出后自动化仍点击旧坐标的问题。编辑框里的项目名满足了原来的文本断言，但工作区项目字段仍为空。Android 窄屏详情页也曾命中只露出边缘的导出按钮。
- 项目归类和原文编辑现在等待编辑器关闭，归档筛选检查列表内容，删除确认等待回收站空态。复核时把 Maestro 的实际点击坐标与截图对照，并用宿主 trace 和重启后的工作区核实命令与落盘结果。
- Seen 1x（2026-11-21）。
