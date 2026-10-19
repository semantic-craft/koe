# Koe UI 与交互规范

一页说清 Koe 界面怎么取色、分层、描边、圆角、动和表达状态。令牌都在 [lib/theme/app_theme.dart](../../lib/theme/app_theme.dart)，状态指示组件在 [lib/ui/widgets/status_indicators.dart](../../lib/ui/widgets/status_indicators.dart)。新界面直接用令牌，不写裸色值、裸圆角和裸时长。

参考来源：[Caho1/open-claude-ui](https://github.com/Caho1/open-claude-ui)（MIT，Copyright (c) 2026 Caho1）`docs/v1` 的 01、02、04、08 篇，是对 Claude 桌面端设计系统的逆向整理。我们只借鉴方法和比例，不用其中任何 Claude / Anthropic 品牌元素、字体或资产。

## 采纳

| 规则 | Koe 的做法 | 原因 |
| --- | --- | --- |
| 表面分层 Surface 0–3 | `surface0` #F5F5F3 画布、`surface1` #FCFCFB 栏和面板、`surface2` #FFFFFF 卡片、`surface3` #FFFFFF 输入框和浮层。旧名 `bg` / `bgElevated` / `bgCard` 是同值别名 | 层级靠微小明度差建立，不靠粗边框和重阴影 |
| 发丝细边 | 卡片、分隔线、导航栏顶线用宽度 0 的 `BorderSide`（一个物理像素）；输入框保持 1px | Retina 屏上 1px 显粗；输入框需要可辨认的边界 |
| 单闭合边框 | 一条视线最多穿过一层闭合边框。卡片里的按钮、chips、分段控件不带边框，只靠底色（`bgPanel` / `accentSoft`）表达可点和选中 | 套娃边框让界面沉重 |
| 文字三级 | `textPrimary` / `textSecondary` / `textMuted`，删掉 `textBody` 和 `textFaint`。`textMuted` 调深到 #6F6F67，在 surface 0–3 上 ≥4.6:1 | 原来五级区分不出用途，`textFaint` 在白底上只有 2.77:1 |
| 单一强调色 | 品牌砖红 `accent` #A4472B；按下 `accentPressed` #8A3B23；浅底 `accentSoft` #F6E9E2。错误 `coral`、警告 `amber` 只在真有错误、警告时出现 | 不用 Claude 的陶土色 #D97757：白字在 #A4472B 上 5.97:1，在 #D97757 上只有 3.12:1，小字不过 AA；也不让 Koe 像仿品 |
| 圆角矩阵 | `AppRadii.button` 8、`panel` 10、`card` 12、`sheet` 16（主视觉卡、对话框、底部面板）、`pill` 999 | 全 App 只用这几档，同类元素同圆角 |
| 弹簧动效 | `AppMotion.snappy`（按钮、Tab、分段切换）、`gentle`（面板、对话框、底部面板打开）、`heavySnap`（底部面板关闭、吸附）；时长只有 `micro` 70 / `snap` 120 / `sheet` 300ms | 去掉默认 ease 和 linear；弹簧有落定感 |
| 减少动态效果 | iOS「减少动态效果」打开时，`AppMotion.duration` 归零、底部面板无动画出现、呼吸点和思考三点静止 | 前庭敏感的用户；有回归测试 [reduced_motion_test.dart](../../test/reduced_motion_test.dart) |
| 等宽数字 | 主题所有文字样式带 `FontFeature.tabularFigures()`，计时、时长、计数跳动时不抖 | 中文字形不受影响，一处设置全 App 生效 |
| 状态指示 | 录音中：录音面板标题前 `BreathingDot`（2.4s 一呼吸）。AI 生成中（问 Koe、日记、提取待办、昨天要点）：`ThinkingDots`（1.9s 三点依次升起）替换转圈 | 转圈只说「在忙」；呼吸和思考三点区分「在录」和「在想」 |
| 键盘焦点 | 按钮获得键盘焦点时外侧画 2px `accent` 环（主要是 macOS） | 键盘用户需要看见焦点在哪 |

## 调整后采纳

- **按钮尺寸阶梯**：iPhone 上所有按钮、图标按钮、分段控件最小 44pt（Apple HIG）；macOS 用 32pt 的紧凑档。只借鉴参考里的内边距、字号和圆角比例，不照搬它 26–32px 的桌面高度。
- **焦点环**：参考用「1px 表面色隔离 + accent 光晕」三层；Flutter 的按钮边框无法留缝，做成 2px 外描边。
- **录音条**：底部常驻的「录音中」条用静止的 accent 圆点，不呼吸。录音可能连续几小时，常驻动画会一直重绘耗电；呼吸点只放在录音面板里。
- **开关**：iOS / macOS 用系统样式，轨道 `accent`、白色滑块；不再各处自定半透明轨道。

## 不采纳

- 桌面专用部分：画廊平移缩放、iframe 分栏、macOS 毛玻璃、Composer 指令引擎、合成提示音。Koe 手机优先，这些在 iPhone 上没有对应场景。
- 任何 Claude、Anthropic 品牌元素、字体或资产。
- 0.5px 发丝边的媒体查询写法：Flutter 用宽度 0 的边框直接得到一个物理像素，不需要分辨率判断。

## 取色速查

| 语义 | 颜色 |
| --- | --- |
| 主操作、强调块 | 实心 `accent` + 白字，按下 `accentPressed` |
| 选中、激活 | `accentSoft` 底 + `accent` 字（5.03:1），不加边框 |
| 可点来源（引用、播放、进度） | `accent` |
| 完成、正常状态 | `textSecondary` / `bgSubtle` |
| 错误 / 警告 | `coral` / `amber` |

对比度以浅色模式为准；暗色 token 未启用（`main.dart` 锁浅色），启用前要重核。
