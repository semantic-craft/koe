# Koe UI 与交互规范

一页说清 Koe 界面怎么取色、分层、描边、圆角、动和表达状态。令牌都在 [lib/theme/app_theme.dart](../../lib/theme/app_theme.dart)，状态指示组件在 [lib/ui/widgets/status_indicators.dart](../../lib/ui/widgets/status_indicators.dart)。新界面直接用令牌，不写裸色值、裸圆角和裸时长。

参考来源：[Caho1/open-claude-ui](https://github.com/Caho1/open-claude-ui)（MIT，Copyright (c) 2026 Caho1）`docs/v1` 的 01、02、04、08 篇，是对 Claude 桌面端设计系统的逆向整理。我们只借鉴方法和比例，不用其中任何 Claude / Anthropic 品牌元素、字体或资产。

## 采纳

| 规则 | Koe 的做法 | 原因 |
| --- | --- | --- |
| 表面分层 Surface 0–3 | `surface0` #F5F4F0 宣纸画布、`surface1` #FAF9F6 栏和面板、`surface2` #FFFFFF 卡片、`surface3` #FFFFFF 输入框和浮层。所有中性灰保持暖灰（R ≥ G ≥ B），不用冷蓝灰 | 层级靠暖灰明度差与发丝细边建立；页面默认纯平，卡片不叠阴影、不发光、不套卡片，阴影只给浮起的弹窗 |
| 发丝细边与同心圆角 | 卡片、分隔线、导航栏顶线用宽度 0 的 `BorderSide`（一个物理像素）；嵌套圆角用 `AppRadii.concentric(outer, gap)`（内圆角 = 外圆角 - 间距） | 避免双重粗框与生硬的同半径嵌套 |
| 单一强调色（中国传统色） | 采用中国传统色「竹青」`accent` #2E5E4E（白字对比度 7.42:1）；按下 `accentPressed` #23493C；浅底 `accentSoft` #E8F0EC。备选传统色为「靛青」#2B4C65 与「松烟墨」#2C2B29 | 不用橙色、陶土色或老式后台亮蓝色；单页只留一个强调色，不在同一页面混排五颜六色的状态块 |
| 四级字号阶梯 | 全站统一 `AppFontSizes` 四档：`xs` 12、`sm` 14、`md` 16、`lg` 22；单页最多 4 种字号，配合阅读行高（正文 1.4） | 字号克制才有清晰的阅读节奏与无障碍对比度，且在 320pt 宽 × 2.0x 大字号下不溢出 |
| 字体、标点与动词克制 | 说明文案不用斜体；按钮与分组标题（`SectionLabel`）不用全大写；等宽字体只用于代码、路径与数字指标；不用中间点 `·` 拼接文案；同一动作全产品只用一个动词（如统一用「连接录音豆」「开始录音」），不用「立即…」催促词 | 符合母语直觉，界面能自己表达的不再堆砌冗余说明 |
| 确认克制与非惊悚危险态 | 常规或可恢复操作（如移入回收站、断开重连）直接执行，仅在不可逆操作（如永久清空、解绑）二次确认；危险操作不用大片红底实心按钮 | 尊重用户直觉，避免满屏确认框与刺眼红色 |
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
