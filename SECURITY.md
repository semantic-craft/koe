# 安全策略 / Security Policy

## 报告漏洞

**请不要在公开 Issue、PR 或讨论里报告安全问题。**

请使用 GitHub 的私密漏洞报告：仓库页面 **Security → Report a vulnerability**。我们会在 7 天内回复，确认问题后与你商定修复和披露时间。

报告里请写明：

- 受影响的版本或提交、平台（iOS / macOS）
- 复现步骤和影响（例如能读到别人的录音、绕过 Mac 归档配对、泄露 API Key）
- 你建议的修复方式（可选）

## 不要贴密钥

**任何地方都不要贴 API Key、token、配对信息或 `.env` / `.envrc` 内容**，包括 Issue、PR、日志截图和诊断日志。需要附日志时先检查并删掉这些内容。

如果你不小心公开了自己的 Key，请立即到服务商控制台（阿里云 DashScope、火山引擎）吊销并重新生成；删除评论不能让已经泄露的 Key 失效。

## 范围

Koe 在本机处理录音，把 Key 存在系统 Keychain，只把音频和文字发给你在设置里选的服务商。以下问题在范围内：

- Key、录音、转写文字或个人记录被其他应用、其他设备或日志读到
- Mac 原件归档的配对、认证或加密被绕过
- 导入资料包（`.koepack`）或音频文件导致越权读写或崩溃

录音豆固件和服务商（千问、豆包、Apple）自身的问题请报告给对应厂商。

---

**Please do not report security issues in public issues or PRs.** Use GitHub private vulnerability reporting (**Security → Report a vulnerability**); we reply within 7 days. Never post API keys, tokens, pairing info or `.env` contents anywhere; if you leak a key, revoke it at the provider immediately.
