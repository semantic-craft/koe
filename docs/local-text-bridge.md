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

## 外部 PCM 识别租约

需要自行识别音频的应用，先在订阅请求中声明能力。

```json
{"method":"subscribe","params":{"capability":"external_pcm_v1"}}
```

`hello.capabilities` 包含 `external_pcm_v1`。音频仍为 `pcm16/16000/mono`，协议版本仍为 1。租约在此 socket 的生命周期内独占外部 PCM 控制权。已有听写或另一位租约持有者会使订阅连接关闭。只设置 `autoGate:false` 不会取得此能力。

每次采集使用新的 `captureId`，并回传当前 `hello.epoch`。只有持有租约的同一 socket 可以发送下列命令。

```json
{"method":"external_pcm","epoch":"hello 中的 epoch","captureId":"本次唯一标识","action":"start","reason":"shortcut"}
{"method":"external_pcm","epoch":"hello 中的 epoch","captureId":"本次唯一标识","action":"stop","reason":"shortcut"}
```

开始须等待 `online` 与 `standbyReady` 都为真。开始确认是 `capture_state` 事件，`state` 为 `started`。普通停止会先排入剩余 240ms PCM，再排入 `state:ended` 确认。确认携带 `epoch`、`captureId` 和单调递增的 `sequence`，与 PCM 共用同一写入队列。客户端收到 `ended` 后才结束识别器。

`reason:"double_tap"` 停止时丢弃敲击尾音。`action:"cancel"` 也丢弃尾音。正面双击产生 `control_edge` 的 `down:true` 和 `down:false` 两帧，只有前者代表一次手势。租约模式下 Koe 不自动切换听写，不为外部 PCM 创建听写记录，也不运行第二份识别。普通会议与录音文件语义保持原样。

错误身份、旧 epoch 或非法状态转换关闭连接。断开释放租约并丢弃未完成的 PCM 尾部；客户端应取消旧采集。BLE 重连的 `hello` 更换 epoch，旧采集不可续接。观察者与旧 socket 不能控制该租约。回到本机麦克风或退出应用时应关闭 socket。
