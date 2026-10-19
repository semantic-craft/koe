# 2026-10-19 单一强调色

整个 App 只保留品牌砖红 `AppColors.accent`（#A4472B）一种强调色，绿色 mint 系 token 删除。

`compare/` 每张图左边是改动前、右边是改动后，iPhone 18 Pro 模拟器（iOS 27）截图，示例数据由 [app_tour.dart](../../../integration_test/screenshots/app_tour.dart) 生成：

```bash
flutter drive -d <simulator-id> --driver=test_driver/screenshot_driver.dart --target=integration_test/screenshots/app_tour.dart
```

## 取色规则

| 语义 | 颜色 |
| --- | --- |
| 主操作、强调块（今日重点项目卡、问 Koe 按钮、导出按钮） | 实心 `accent` + 白字（对比度 5.97:1） |
| 选中、激活（筛选标签、多选勾、问答里自己的气泡） | `accentSoft` 底 + `accentBorder` 边 + `accent` 字（5.03:1） |
| 可点的来源（引用标记 [S1]、原话标签、待办引文图标、播放键、进度条） | `accent` |
| 完成、正常状态（已配置、已就绪、导出完成、D3200、已连接、电量充足） | 中性灰 `textSecondary` / `bgSubtle` |
| 错误 / 警告 | `coral` / `amber`，只在真有错误、警告时出现 |

Material 的 `secondary` 角色（筛选 chip、进度条轨道、开关）也指向 `accent` / `accentSoft`，原来进度条轨道会落到实心绿色。

浅色模式下的对比度：`accentSoft` 上的 `accent` 字 5.03:1，`accent` 上的 `accentSoft` 字 5.03:1，都过 WCAG AA。暗色 token（未启用，main.dart 锁浅色）里 `accentSoft` 上的 `accent` 只有 4.11:1，启用暗色前要重调。

iOS/macOS 的 `Switch.adaptive` 不传颜色时默认系统绿；主题里加了 `cupertinoOverrideTheme(applyThemeToAll: true)`，让它们落到 `accent`。现有开关都显式传了颜色，外观不变。
