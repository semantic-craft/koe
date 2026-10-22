# 教训台账（内部）

只给 agent 用：记每条教训的出处、修复和复发次数（Seen N×）。对外的十条规则在 [CONTRIBUTING](../../CONTRIBUTING.md)；同一条教训在 3 个不同日子出现，就升为 [AGENTS.md](../../AGENTS.md) 交付规则，能写成测试或检查的写成测试或检查。
#286 开源准备时根目录 `lessons.md` 并入了 CONTRIBUTING，Seen 计数随归档一起删了；本文件从 2026-10-19 起接着记，旧条目原文在 git 历史 `ae0cfa5^:lessons.md`（#286 删除前的最后一版）。

### 异步测试要等真实 I/O 结束的确定状态，不拿中间状态当完成信号

- 出事：2026-10-19 一天里三处同根因的偶发失败，都在本机负载下拖红 CI：#205（20ca963）重启恢复用例在日志读完前取 `jobs.single`、在最后一次落盘前结束；#213（1100aac）未等待的保存落进临时目录、用一次 `pumpEventQueue` 当落盘完成；#305（992af84）保存后 `pumpAndSettle` 只推进假时钟，对话框遮罩还在，点「译文」落到遮罩上。
- 修复：20ca963、992af84 只改测试，加确定的同步点或等到对话框真正关闭；1100aac 把 `pumpEventQueue` 改为轮询读回，并改了存储层：固定 `.tmp` 改为每次写入用独立临时文件（`lib/state/atomic_file.dart`）。
- Done right: #305 在测试控制器里注入 300ms 真实 I/O 延迟，改前稳定复现 CI 失败、改后在 18 核满载下连跑 40 次全过；#205 注入 40ms 读写延迟复现两处缺口。
- Seen 2x (2026-10-16, 2026-10-19)；10-19 同日三起只算一次。已在 CONTRIBUTING 第 7 条；再出现一天就升 AGENTS 硬规则。

### 全局主题改动要在真实界面逐类组件看一遍

- 出事：`lib/theme/app_theme.dart` 一直用 `base.copyWith(textTheme: TextTheme(...))` 拿一个全新的 TextTheme 覆盖基础主题（首个提交 43befb5 就这样写，10-19 UI 规范系列 #259 f467144 外面又包了一层 `_tabular`）。`headlineSmall` 等没定制的样式因此没有颜色，所有 AlertDialog 标题在 iPhone 和 Mac 上都是空白。这个写法在 1.2.2 之前的发布版（1.1.0、1.2.0、1.2.1）里都有，到 10-19 1.2.1 真机复测才发现（#306）。哪个版本、哪个提交开始真正显示空白，待核实。
- 修复：3046034（#309，在基础 textTheme 上 `copyWith`，随 1.2.2 发布）；#308 在 1.2.2 上用 iPhone 和 Mac 安装版复测，对话框标题可见。
- Done right: #309 加了 iOS/macOS × 浅色/深色 4 条回退测试（改前标题颜色为 null），#308 再用 `scripts/mac-ax` 和 iPhone 截图在真实界面确认标题。以后改主题时，把对话框、菜单、输入框等每类组件都在真实界面截一遍图再合。
- Seen 1x (2026-10-19)

### 验收记录只写有证据的操作，不替用户补全没看到的步骤

- 出事：#255（c9fd4f3）把 #231 复测写成「没人按键、录音豆自己结束文件」，实际是用户 13:55 左右按录音豆实体键结束了录音；结论因此把「补取成功」错归给了自动结束。
- 修复：57b9a5b（#256，依据用户确认的操作和当时的 BLE 日志更正；补取成功那次日志为 `head … size=1195200`）。
- Done right: 验收结论里每一步用户或设备操作都要指向日志、截图或用户原话；看不到的写「待核实」，先问再写。
- Seen 1x (2026-10-19)

### 本机跑测试前清掉 shell 里的云端密钥环境变量

- 出事：2026-10-21 #337 在本机跑 `check`，干净 main 也红 5 条（`engine_lineup_test`、`recording_processing_test`、`context_export_test`）：agent 的 shell 带着 `DASHSCOPE_API_KEY` 等变量，`lib/ai/cloud_stt_service.dart` 会读它们，「未配置」的用例因此看到已配置。CI 运行机没有这些变量，所以只在本机红。
- 修复：只改跑法：`env -u DASHSCOPE_API_KEY -u ARK_API_KEY -u DOUBAO_TTS_API_KEY check`，main 与分支都全绿。没有读取或打印变量值。
- 反过来也会漏：2026-10-22 #344 新加的冷启动用例在本机单跑 `flutter test` 时全过，靠的是 shell 里的密钥；去掉变量跑 `check` 才红：读回已保存设置时 Qwen 的 key 被换成保存的空值。修复在测试保存的设置里带上替身 key。
- Done right: 本机 `check` 出现与改动无关的「已配置」类失败，先在干净 worktree 用同样去掉密钥变量的命令复跑一遍对照，再判断是不是回归。单跑 `flutter test <文件>` 也加同样的 `env -u …` 前缀。
- Seen 2x (2026-10-21, 2026-10-22)

### 真机场景不能假设 Pixel 停在解锁的桌面：充电时会进屏保，锁屏要 PIN

- 出事：2026-10-22 #344 快捷方式场景头一次真正在 Pixel 上跑（#347 到 #354 的场景提交时 Pixel 都离线，没在真机跑过），接连失败。`moveTaskToBack` 后 Koe 的生命周期一直是 resumed：手机充电，息屏 30 秒就进时钟屏保（`com.google.assistant.hubui` 的 `EverydayClockDreamService`），Koe 留在屏保后面，只收到 `wm_on_top_resumed_lost_called`。改按 Home 键后，屏保一退就露出锁屏；锁屏要 PIN，`wm dismiss-keyguard` 解不开。点快捷方式时 Koe 只在锁屏后面恢复一下又暂停（`wm_pause_activity … sleep`、`wm_set_keyguard_occluded [0,0,0]`），麦克风前台服务被拒：logcat 里服务本身获准启动（`ACTIVITY_VISIBILITY_GRACE_PERIOD`），但 uidState 是 `TPSL`（置顶但在睡眠）、`allowWiu:-1`，接着报 `can not have location/camera/microphone access`，`startForeground` 抛 SecurityException。
- 修复：`KOE_ADB: home` 先 `wake-screen` 再按 Home，场景等 Koe 真进了后台。原生状态加 `deviceLocked`（`KeyguardManager.isDeviceLocked`）；手机锁着时场景打印 `KOE_ADB: skip <原因>` 并跳过，`scripts/android-check` 以 77 退出：记为跳过，不算通过也不算失败。试过离屏 8 秒后再点快捷方式，锁着时照样被拒。
- Done right: 写需要 Koe 在屏幕上的场景前，先用 `adb shell dumpsys power`（`mWakefulness`、`mDreamsActivateOnSleepSetting`）和 `dumpsys trust`（`deviceLocked`）看设备实际状态；失败时看 `adb logcat -b events` 里 `wm_pause_activity` 的原因，和 `ActivityManager` 对前台服务的判定（`uidState`、`allowWiu`）。没人值守解不开 PIN 锁屏：要 Koe 在屏幕上的场景，手机锁着时跳过。
- Seen 1x (2026-10-22)
