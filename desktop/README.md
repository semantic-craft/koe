# Koe Rust + GPUI Kit 桌面端

`desktop/Cargo.toml` 统一管理两个 crate：

- `desktop/core`（`koe-core` 库 + `koe-pack` CLI）：支持 `.koepack` v1/v2 Framing 与校验、旧版 `AnkerRecorder` 资料库无损读写（`recording_library.json`、`transcripts.json`、`analysis.json`）、16-bit PCM WAV 录音（`cpal`）、`schemaVersion: 2` 结构化纪要生成，以及按会话授权的 MCP `live.json` 与 `.koepack` 快照发布（`koe-pack mcp --live-directory PATH`）。
- `desktop/app`（`koe-desktop` GPUI Kit 桌面应用）：集成资料库浏览、`.koepack` 阅读、`rodio` 原声播放、麦克风录音、转写校订保存、结构化纪要生成与逐条录音 MCP 共享开关。

## 构建、验证与启动

在仓库根目录执行：

```sh
scripts/check-desktop
scripts/verify-desktop-flow
cargo run --locked --manifest-path desktop/Cargo.toml --bin koe-desktop -- --library <AnkerRecorder 目录>
```

命令参数：

- `koe-desktop --library <DIR>`：打开指定资料目录。
- `koe-desktop --pack <PATH>`：打开指定 `.koepack` 资料包。
- `koe-desktop --smoke-test <PATH>`：打开资料目录或 `.koepack` 资料包，完成真实 GPUI 窗口渲染后自动退出（成功返回 0，失败或超时返回 1）。
- `python3 desktop/scripts/package-preview.py`：在 `desktop/target/Koe Preview.app` 生成本地开发预览应用包。
