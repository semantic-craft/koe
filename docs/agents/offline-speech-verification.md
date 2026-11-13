# 本机模型与全天听记验收

`crates/koe-cli/examples/verify_offline.rs` 通过产品 Runtime 命令进入，使用实际下载模型。它不会注入识别文字，也不打开麦克风。测试工作区必须是新目录，避免把已有资料当测试目标。

准备一段包含真实说话的 PCM16 WAV。开发时使用的公开样本来自 [TaoSheng 固定版本](https://github.com/0xCoach/TaoSheng/blob/d82cc5545403fd34d83375a295634d5fec61f1ee/app/src/main/assets/asr-test.ogg)，转为 16 kHz 单声道 WAV 后用于回放。样本原文件 SHA-256 为 `0d83a965fee138606e96c0a4586ec06acf068ea2c464aeb7c7f1a2f284536696`。

```sh
cargo run -p koe-cli --example verify_offline -- /absolute/fresh-file-workspace /absolute/speech.wav sensevoice-small
cargo run -p koe-cli --example verify_offline -- /absolute/fresh-qwen-workspace /absolute/speech.wav qwen3-asr-0.6b
cargo run -p koe-cli --example verify_offline -- /absolute/fresh-day-workspace /absolute/speech.wav sensevoice-small --all-day
```

模型首次准备需要网络。重复验证可把已下载的固定模型文件放入新工作区 `speech-models/`；产品仍会校验大小和 SHA-256，再加载。

文件流程验证导入、实际识别、持久化、关闭和重开后文字一致。全天流程重复回放输入 WAV，累计 303 秒，检查五分钟边界后有两条包含原文的记录；只圈定最初 15 秒为听写，确认文字事件没有越出范围。最后重开工作区并比对两条记录原文。

这些命令验证生产 Runtime 和真实推理，不代表麦克风、D3200、耗电或长时间实际环境已通过。原生应用需操作设置、模型准备、全天听记和演示，再读回保存状态；硬件场景见 [#662](https://github.com/semantic-craft/koe/issues/662)。

模型生命周期、取消、故障、音频时间和持久化边界运行仓库统一检查。

```sh
./scripts/check
```
