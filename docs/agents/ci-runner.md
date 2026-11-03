# CI 运行机（自己的 Mac）

CI（[.github/workflows/ci.yml](../../.github/workflows/ci.yml)）只在带 `self-hosted, macOS, ARM64` 标签的运行机上跑，不用 GitHub 托管机器，也就不花 GitHub 托管分钟。运行机就是装好 Flutter 3.47.7 的这台 Mac（Homebrew 装在 `/opt/homebrew/bin/flutter`）。代码检查中版本不对会直接失败并提示。

## 按改动分流

必过检查名仍为 `test`，所有 PR 和 main 推送都会产生结果。`scripts/ci.py` 只将根目录 Markdown、`docs/` 下的 Markdown、`progress/progress.json` 和 `progress/index.html` 视为轻量改动。

- 纯文档检查改动中的空白错误。涉及进度文件时，再运行 `python3 progress/progress.py check`，验证生成一致性和本地链接，不访问 GitHub。
- 其他文件，包括 `progress/progress.py`、工作流和脚本，先检查进度生成，再运行 Flutter 版本检查、依赖安装及 `scripts/check --reporter expanded`。进度脚本或生成器改动也不会漏掉生成校验。
- PR 从共同祖先计算改动；main 推送检查整个推送范围。重命名同时检查旧、新路径，删除同样参与分流。手动触发、空范围或无法确定改动时运行完整检查。

CI 不按路径跳过整个工作流，避免必过检查一直等待。没有代码改动时不启动 Flutter；代码检查保留 Python、Swift 和 Flutter 覆盖。本地已通过的定向检查无需重复运行，最终完整门禁由 CI 执行一次。

## 注册（一次）

1. 打开 <https://github.com/semantic-craft/koe/settings/actions/runners/new>，选 **macOS**、**ARM64**。
2. 页面会给出 Download 和 Configure 两段命令。在「终端」里**逐行**粘贴运行；目录用页面默认的 `~/actions-runner`，不要放进仓库。`--token` 是一次性注册令牌，只在终端里用，不要发到聊天、工单或 PR 里。
3. `./config.sh` 会问几个问题，全部按回车接受默认值即可（名称默认是电脑名，标签默认已含 `self-hosted, macOS, ARM64`）。
4. 让它在后台常驻（开机登录后自动启动）：

   ```bash
   cd ~/actions-runner && ./svc.sh install && ./svc.sh start
   ```

   只想临时跑一次，就改用 `./run.sh`，关掉终端即停。
5. 刷新 <https://github.com/semantic-craft/koe/settings/actions/runners>，看到运行机显示 **Idle**（绿点）就成功了。
6. 在 <https://github.com/semantic-craft/koe/settings/actions> 打开 Actions（Allow all actions），然后在 PR 页面点 Re-run，或推一个新提交。

## 注意

- **Mac 要开着、联网、已登录**，CI 才会跑；关机时任务会排队等待。
- **PR 的代码会以你的用户身份在这台 Mac 上执行。** 仓库保持私有、只接受自己和受信 agent 的 PR；workflow 不读任何密钥。开发构建默认隔离 Keychain（见 [CONTRIBUTING](../../CONTRIBUTING.md) 规则 3），测试不会读个人凭据。
- 账单：自托管运行机不消耗托管分钟。如果 GitHub 仍以「付款失败 / 支出上限」拒绝任务，去 <https://github.com/settings/billing> 处理付款状态；支出上限保持 $0 就不会产生托管机器费用。
- 停用：`cd ~/actions-runner && ./svc.sh stop && ./svc.sh uninstall`，再在 Runners 页面删掉这台运行机。
