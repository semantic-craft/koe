# 千问与豆包语音接入验收

日期：2026-10-15。录音为用户授权的同一段约 30.26 秒独立录音；完整音频、转写和运行输出只保存在本地忽略目录 `build/device-validation/`，不提交仓库。

## 引擎与行为

豆包配置只要求 API Key。千问只要求 API Key，另有可选 Workspace ID，程序生成业务空间专属地址；现有旧域名配置保留可用路径。首次保存自动启用并关闭弹窗，模型无需用户输入。Workspace 专属域名的实际账户请求尚未验证；本轮使用原有 Key 和旧域名完成实测。

| 场景 | 千问 | 豆包 |
| --- | --- | --- |
| 文件转写 | `qwen-audio-3.1-asr-flash-filetrans` | 极速版，资源 `volc.bigasr.auc_turbo` |
| 实时转写 | `qwen-audio-3.1-asr-flash-streaming` | 2.0 优化二遍，资源 `volc.seedasr.sauc.duration`，`bigmodel_async`，`enable_nonstream: true` |

设置页保留 Apple、千问、豆包。移除 MOSS/Soniox 的适配器、凭据表单和执行入口；旧提供商枚举只用于读取历史记录。旧任务不会静默转给另一个付费服务。已保存的结果继续保留，旧未完成任务读取后停止并说明原因。

实时连接发送 16 kHz 单声道 PCM，每块 200 ms；结束时发送剩余音频并等待服务端完成标记。二遍修订覆盖上一版累计文本，暂停后新连接保留前段结果。只有确认收到最终结果才跳过文件补转写，异常关闭不能当作完成。独立录音取回仍走持久文件队列。

## 已完成的服务验收

同一个 WAV（48 kHz 单声道，2,905,004 字节）：

| 路径 | 结果 | 单次耗时 / 过程 |
| --- | --- | --- |
| 豆包极速文件 | 成功，130 字 | 1.963 秒 |
| 千问 3.1 文件 | 成功，131 字 | 3.483 秒 |
| 豆包实时二遍，按真实时间回放 PCM | 收到最终完成，130 字 | 55 次中间结果 |
| 千问 3.1 实时，同一 PCM | 收到最终完成，121 字 | 44 次中间结果 |

这是单个样本、单次请求的观察，不能推导总体速度或准确率排名。两种文件转写的主要内容一致，开头短语存在差异；没有人工逐字标注，因此未计算 WER。实时回放证明真实 WebSocket 协议链路工作，不替代录音豆蓝牙实时录音的端到端验收。

## 已安装 App 验收

- Mac：新版 Release 已安装；配置页已通过真实界面确认豆包仅一个密钥框，千问为密钥与可选 Workspace 两个输入框。通过实际界面分别选择豆包和千问，对 16:25 的同一录音执行“重新转写”，两次均展示完成文本；豆包任务日志也确认完成。
- iPhone：新版已安装。豆包密钥已由用户填写并保存；豆包与千问均通过实际界面对同一段录音重新转写成功。最新配置表单已重新安装，手机界面复核等待解锁。
- 两端新版本的录音豆实时录音、暂停续录和交接验收尚未完成。此前版本已验证的 BLE 取回和手动断开持久化不能替代这一轮新功能验收。

Mac 当前使用开发启动脚本注入运行时凭据；这不等同于密钥已经永久保存。开发脚本从明确白名单取得环境变量，不把凭据写入构建产物或任务日志。

## 自动化证据

最终 `flutter test --concurrency=1` 全量 238 项通过，`flutter analyze --no-pub` 无问题。并行编译期间的一次普通全量运行曾有 BLE 活跃传输超时测试失败（StreamSink 已关闭）；该测试单独复跑及随后全量串行运行均通过，保留这一时序波动记录。新增本地 WebSocket 协议测试覆盖握手、开始前不发音频、二遍缩短修订、分块和尾包、最终完成、异常断开。迁移测试覆盖停用旧提供商、清除旧凭据读写和保留已有结果。队列恢复、重复通知、暂停和文件处理继续由现有回归覆盖。

## 标准版上传调查

[火山标准版文档](https://docs.volcengine.com/docs/DoubaoVoice/LargemodelrecordingfilerecognitionstandardversionAPI?lang=zh) 要求 `audio.url`，采用异步提交和查询；不能把极速版的 `audio.data` 原样搬过去。[极速版文档](https://docs.volcengine.com/docs/DoubaoVoice/LargemodelrecordingfileLiterecognitionAPI?lang=zh) 支持直接传 Base64，因而本轮先完成极速版。

进一步核对[方舟 Files API](https://docs.volcengine.com/docs/ark/file-api?lang=zh)、[上传接口](https://docs.volcengine.com/docs/ark/upload-files-api?lang=zh)和[文件查询接口](https://docs.volcengine.com/docs/ark/search-files-api?lang=zh)：方舟提供托管文件上传，不必先要求用户自建存储桶；查询文档列有可选 `download_url`。

实际使用现有方舟凭据上传同一段授权录音：上传 HTTP 200，查询 HTTP 200 且状态 `active`，但响应没有 `download_url`。随后删除该临时文件，删除返回 HTTP 200 且 `deleted: true`。因此，已证明托管上传可用，尚未证明能取得标准版语音服务可下载的链接；不能把方舟文件 ID 当作 URL，也不能宣称标准版已打通。当前代码未将此未经验证的路径开放给用户。

资源名称包含 `bigasr` 不足以判断模型代际或准确率。模型功能以官方能力说明及实际服务返回为准。
