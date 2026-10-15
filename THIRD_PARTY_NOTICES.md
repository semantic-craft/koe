# 第三方内容

结构化纪要的章节选择和整理规则改编自以下 MIT 项目；没有引入其应用、后端或本地模型运行时。分发包包含完整许可正文，并登记到 Flutter LicenseRegistry。

| 项目 | 固定参考版本 | 采纳范围 | 许可 |
| --- | --- | --- | --- |
| [Meetily](https://github.com/Zackriya-Solutions/meetily/tree/a2cb62e827da7ef59f65064c97233efb2313878e) | a2cb62e827da7ef59f65064c97233efb2313878e | standard_meeting.json 的摘要、决策、待办及来源字段设计 | assets/licenses/meetily.txt |
| [Ownscribe](https://github.com/paberr/ownscribe/tree/9d5f82e2b8ec6c093755b43ebe8fead9ec06d7fe) | 9d5f82e2b8ec6c093755b43ebe8fead9ec06d7fe | prompts.py 的通用会议章节、合并去重和保留事实/任务规则 | assets/licenses/ownscribe.txt |

思维导图固定依赖 GraphView 1.5.1（MIT），使用其 BuchheimWalkerAlgorithm 进行树形布局。界面交互、来源关联与离屏 PNG 导出由本项目实现；不需要在线渲染服务。依赖许可随 Flutter 包分发。
