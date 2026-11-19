# CI 运行环境

公开仓库的 CI（[.github/workflows/ci.yml](../../.github/workflows/ci.yml)）运行在 GitHub 托管的 `macos-15` ARM64 运行机上，不再对公开 PR 使用自托管运行机，避免不受信任的 PR 代码在个人机器上执行。工作流顶层仅申请最小只读权限 `permissions: { contents: read }`。

## 按改动分流

必过检查名为 `test`，所有 PR 和 `main` 推送都会产生结果。`scripts/ci.py` 只将根目录 Markdown、`docs/` 下的 Markdown、`progress/progress.json` 和 `progress/index.html` 视为轻量改动。

- 纯文档检查改动中的空白错误。涉及进度文件时，再运行 `python3 progress/progress.py check`，验证生成一致性和本地链接，不访问 GitHub。
- 其他文件，包括 `progress/progress.py`、工作流和脚本，先检查进度生成，再运行 `cargo --version` 及 `./scripts/check`（Python 契约测试、`verify-ui-principles.py`、全量 `cargo test --workspace`、`cargo clippy --workspace --all-targets -- -D warnings` 与 `swift test --package-path platforms/macos`）。进度脚本或生成器改动也不会漏掉生成校验。
- PR 从共同祖先计算改动；`main` 推送检查整个推送范围。重命名同时检查旧、新路径，删除同样参与分流。手动触发、空范围或无法确定改动时运行完整检查。

CI 不按路径跳过整个工作流，避免必过检查一直等待。没有代码改动时不启动 Rust / Swift 全量编译；代码检查保留 Python、Rust 四层工作区与 Apple 原生宿主（AppKit + SwiftUI）完整覆盖。

## 环境与离线模式

- `macos-15` 托管镜像预装 Rust 工具链（`cargo` / `rustc`）、Xcode Command Line Tools（`swift`）、`python3`、`cmake` 与 `pkg-config`；工作流在执行前保留 `export PATH="/opt/homebrew/bin:$PATH"`。
- `scripts/verify-local.sh` 默认允许 Cargo 按 `Cargo.lock` 拉取依赖，以便 GitHub 托管运行机与全新克隆开箱即用；本地断网验证可设置 `KOE_CARGO_OFFLINE=1 ./scripts/verify-local.sh`。
- 开发构建默认隔离 Keychain（见 [CONTRIBUTING](../../CONTRIBUTING.md) 规则 3），CI 工作流不读取任何密钥或签名证书。
