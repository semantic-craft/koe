# 给外部语音输入法的文字桥

Koe 负责采集、识别和保存原文。外部输入法订阅用户圈定的听写文字，负责润色与插入目标应用。双方不需要为同一段声音重复识别，也不绑定特定输入法产品。

应用运行时连接该工作区的本地 Unix socket。默认签名工作区使用容器内 `.koe/koe.sock`，显式开发工作区使用 `<workspace>/koe.sock`。套接字只允许同一用户访问。已有 `companion-listen` 命令可观察事件。

连接后发送一行 JSON 订阅事件。

```json
{"method":"companion/subscribe"}
```

同一连接发送听写范围命令，每条命令独占一行。

```json
{"method":"set_dictation_active","active":true}
{"method":"set_dictation_active","active":false}
```

开启前需要已有现场音源。命令只圈定听写，不表示停止全天录音。用户也可在界面点击开始和结束语音输入，或通过录音豆双击控制。

确定文字完成工作区提交后，订阅流发送 `transcript_final`。以下是协议示例，不是生产录音。

```json
{"event":"transcript_final","recordId":"example-record","segmentId":"S1","startMs":0,"endMs":3000,"text":"示例文字","dictation":true}
```

输入法只处理 `dictation: true` 的定稿事件，以 `recordId` 与 `segmentId` 识别同一段。时间相对该记录，不能把另一条记录的 S1 当成同一句。全天背景内容和后台历史文件识别不作为听写推送。

桥保留原有 `hello`、`control_edge`、`audio_pcm16` 和 `device_status` 事件。已有音频输入客户端可继续使用 PCM 接口；只需要文字的客户端忽略其他事件。该流不提供历史消息重放，断开后原文仍保存在 Koe 记录中，可通过现有记录接口读取。
