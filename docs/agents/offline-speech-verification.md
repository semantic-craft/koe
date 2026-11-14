# 本机模型与全天听记验收

`crates/koe-cli/examples/verify_offline.rs` 通过产品 Runtime 命令进入，使用实际下载模型。它不会注入识别文字，也不打开麦克风。测试工作区必须是新目录，避免把已有资料当测试目标。

准备一段包含真实说话的 PCM16 WAV。开发时使用的公开样本来自 [TaoSheng 固定版本](https://github.com/0xCoach/TaoSheng/blob/d82cc5545403fd34d83375a295634d5fec61f1ee/app/src/main/assets/asr-test.ogg)，转为 16 kHz 单声道 WAV 后用于回放。样本原文件 SHA-256 为 `0d83a965fee138606e96c0a4586ec06acf068ea2c464aeb7c7f1a2f284536696`。

```sh
cargo run -p koe-cli --example verify_offline -- /absolute/fresh-file-workspace /absolute/speech.wav sensevoice-small
cargo run -p koe-cli --example verify_offline -- /absolute/fresh-qwen-workspace /absolute/speech.wav qwen3-asr-0.6b
cargo run -p koe-cli --example verify_offline -- /absolute/fresh-day-workspace /absolute/speech.wav sensevoice-small --all-day
```

`crates/koe-cli/examples/verify_offline_socket.rs` 进一步经 C ABI（`HostSessionGuard`）与真实 `koe.sock`（`UnixStream`）驱动同一链路，可在 macOS 内核禁外网沙盒下离线运行：

```sh
cargo build --release -p koe-cli --example verify_offline_socket
sandbox-exec -p '(version 1)(allow default)(deny network-outbound (remote ip))' \
  target/release/examples/verify_offline_socket /short/ws-sv /absolute/speech.wav sensevoice-small --all-day
sandbox-exec -p '(version 1)(allow default)(deny network-outbound (remote ip))' \
  target/release/examples/verify_offline_socket /short/ws-qw /absolute/speech.wav qwen3-asr-0.6b
```

模型首次准备需要网络。重复验证可把已下载的固定模型文件放入新工作区 `speech-models/`；产品仍会校验大小和 SHA-256，再加载。显式工作区路径须保证 `<workspace>/koe.sock` 短于 Unix 套接字路径上限。

文件流程验证导入、实际识别、持久化、关闭和重开后文字一致。全天流程重复回放输入 WAV，累计 303 秒，检查五分钟边界后有两条包含原文的记录；只圈定最初 15 秒为听写，确认文字事件没有越出范围。最后重开工作区并比对两条记录原文。

这些命令验证生产 Runtime 和真实推理，不代表麦克风、D3200、耗电或长时间实际环境已通过。原生应用需操作设置、模型准备、全天听记和演示，再读回保存状态；硬件场景见 [#662](https://github.com/semantic-craft/koe/issues/662)。

模型生命周期、取消、故障、音频时间和持久化边界运行仓库统一检查。

```sh
./scripts/check
```

## 本轮独立复核

实现提交 `1779461` 通过独立真实 SenseVoice CPU 验收。随后 `verify_offline_socket` 在 `sandbox-exec` 禁全部外网 IP（正对照连接 `1.1.1.1:443` 返回 `Operation not permitted`）条件下，通过 `HostSessionGuard`（C ABI v2）与真实 `koe.sock` 完成两项离线验收：

- `sensevoice-small --all-day`：经已订阅的同一 `UnixStream` 发送 `set_dictation_active` 圈定首段 0–15000 ms；在首段与自动切分后的第二段（`ordinal = 2`）各执行一次暂停与单调时钟恢复（持久化多 `epoch` 时间轴）；注入 `product-workspace.json` 目录占位故障确认 `microphone.phase == "saving"` 暴露保存错误，恢复文件后调用 `retry_microphone_save` 收口为 300 秒（20 段）与 3 秒（1 段）两条 WAV 记录；后台导入音频并执行 `transcribe`，确认 `koe.sock` 零泄漏后台 `transcript_final` 事件，唯一听写事件与持久化分段完全一致；销毁会话确认 `koe.sock` 清理，重开后 `meetingAudioPolicy` 保持 `local_only`，未手动调用 `prepare_speech_model` 即自动重新加载模型至 `ready`。
- `qwen3-asr-0.6b`：在相同禁外网沙盒与 `koe.sock` 订阅下完成 15 秒麦克风听写圈定、后台导入文件离线识别（零事件泄漏）、会话销毁套接字清理，以及重开后 `local_only` 保持与模型自动就绪（`reopenAutoReady: true`）。

未在真实物理环境验证的项目：超过 5 分钟的真实麦克风与 D3200 连续说话、锁屏续录、物理蓝牙断连重连、真实外部输入法进程联调，以及本机大语言模型整理与问答；上述真机与本机 LLM 场景仍按 [#662](https://github.com/semantic-craft/koe/issues/662) 跟踪。
