# 双端九旅程验收

在仓库根目录运行同一个入口。iOS 的 `UDID` 必须属于本次专用模拟器，Android 使用 `githubDebug` APK 和 `koe-test-api35`。两端传同一个新产物目录。

```sh
python3 scripts/run_mobile_e2e.py ios "$evidence" --udid "$UDID"
python3 scripts/run_mobile_e2e.py android "$evidence" --apk "$APK"
python3 scripts/verify_mobile_e2e.py "$evidence"
```

| 旅程 | 流程 | 验收点 |
| --- | --- | --- |
| 1、2 | design-capture-detail | 冷启动、识别引擎、保存模型、创建闪记和项目归类 |
| 3、4 | design-capture-detail | 真实采录、暂停与继续、工作区控件、播放与拖动、迷你播放条、修订、说话人、重点与导出 |
| 5、7 | design-review-ask-trash | 审核待办与记忆、恢复忽略项、归档保护、撤销删除、取消与确认清除 |
| 6 | design-ask | 指定记录范围、单击发送、引用返回原文定位 |
| 8 | design-device、design-device-link | 连接引导、面板错误、控制权、存储与传输进度、打开已同步记录 |
| 9 | design-restart | 强制结束应用后，使用同一 Rust 工作区核对配置、项目和修订 |

入口先用 Rust Host API 创建两个待办和两条记忆候选。闪记、归类、修订和 WAV 由本次操作产生。设备阶段注入 D3200 视图，将已同步文件关联到实际存在的种子记录。两次设备启动分别验收控制权与来源导航。

每端保存 live、restart、device 和 device-link 四组截图、宿主 trace 和系统日志。live 和 restart 另存 Rust 工作区。校验器按记录 ID 检查两次落盘内容，并按麦克风记录 ID 打开对应的 WAV。Android 的 restart 在同一次模拟器开机内运行，以免重新加载 Golden Snapshot 回滚应用数据。
