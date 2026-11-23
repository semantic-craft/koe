# CI 运行环境

公开仓库的 CI（[.github/workflows/ci.yml](../../.github/workflows/ci.yml)）运行在 GitHub 托管的 `macos-26` ARM64 运行机上（包含 macOS 26 SDK，满足 `SpeechAnalyzer` 编译要求），不再对公开 PR 使用自托管运行机，避免不受信任的 PR 代码在个人机器上执行。工作流顶层仅申请最小只读权限 `permissions: { contents: read }`。

## 按改动分流

必过检查名为 `test`，所有 PR 和 `main` 推送都会产生结果。`scripts/ci.py` 只将根目录 Markdown、`docs/` 下的 Markdown、`progress/progress.json` 和 `progress/index.html` 视为轻量改动。

- 纯文档运行 `git diff --check` 和 `python3 scripts/check_docs.py`，检查本地 Markdown 链接与活跃文档中的退役符号。涉及进度文件时额外检查生成一致性和本地链接。
- 其他文件，包括 `progress/progress.py`、工作流和脚本，先检查进度，然后由 `./scripts/check` 运行文档门禁及其回归、宿主契约、UI 门禁、Rust 编译、Clippy、工作区测试、形式状态模型、Apple SwiftPM 与桌面 JNI 测试。
- PR 从共同祖先计算改动；`main` 推送检查整个推送范围。重命名同时检查旧、新路径，删除同样参与分流。手动触发、空范围或无法确定改动时运行完整检查。

`swiftlint`、`ios`、`android` 和 `lint-scripts` 在 PR 上按改动路径启用，`main` 推送及手动触发时全部运行。Apple 检查使用 `macos-26`，Android 与脚本 lint 使用 Ubuntu。iOS 从 XcodeGen 规格生成工程并运行模拟器单测。Android 检查桌面 JNI、GitHub/Play 渠道的 Gradle 单测和 Release Lint（含 Compose Lint）。脚本检查运行 Ruff 和 ShellCheck。

## 环境与离线模式

- `macos-26` 托管镜像预装 Rust 工具链（`cargo` / `rustc`）、Xcode 26+ Command Line Tools（`swift` 与 macOS 26 SDK）、`python3`、`cmake` 与 `pkg-config`；工作流在执行前保留 `export PATH="/opt/homebrew/bin:$PATH"`。
- `scripts/verify-local.sh` 默认允许 Cargo 按 `Cargo.lock` 拉取依赖，以便 GitHub 托管运行机与全新克隆开箱即用；本地断网验证可设置 `KOE_CARGO_OFFLINE=1 ./scripts/verify-local.sh`。
- 开发构建默认隔离 Keychain（见 [CONTRIBUTING](../../CONTRIBUTING.md) 规则 3），CI 工作流不读取任何密钥或签名证书。
