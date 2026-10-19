# CI 运行机（自己的 Mac）

CI（[.github/workflows/ci.yml](../../.github/workflows/ci.yml)）只在带 `self-hosted, macOS, ARM64` 标签的运行机上跑，不用 GitHub 托管机器，也就不花 GitHub 托管分钟。运行机就是装好 Flutter 3.47.7 的这台 Mac（Homebrew 装在 `/opt/homebrew/bin/flutter`）。版本不对时 CI 第一步直接失败并提示。

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
