# 按住说话（#142）截图

iPhone 17 模拟器（iOS 27），示例数据、假麦克风、假识别、假朗读由 [app_tour.dart](../../../integration_test/screenshots/app_tour.dart) 生成（24–34）：

```bash
flutter drive -d <simulator-id> --driver=test_driver/screenshot_driver.dart --target=integration_test/screenshots/app_tour.dart
```

| 文件 | 内容 |
| --- | --- |
| 24 | 新记录：按住说话记一条、改用文字 |
| 25 | 按住中：呼吸点、计时、松开发送/上滑取消 |
| 26 | 松开后保存为原件并显示转写结果 |
| 27 | 文字记一条 |
| 28 | 问 Koe 切到语音输入 |
| 29 | 按住提问 |
| 30 | 上滑进入取消区（单帧截图，按钮底色动画尚未走完） |
| 31 | 断网：说明原因，这句话保留，可重新识别或丢弃 |
| 32 | 识别后发出并回答，标「语音识别 · 已发送」 |
| 33 | 交办只回「暂未开放」，标「未执行」 |
| 34 | 打开朗读后的合成语音标识与停止 |

真机步骤见 #283。
