# 安全策略 / Security Policy

## 报告漏洞

**请不要在公开 Issue、PR 或讨论里报告安全问题。**

请使用 GitHub 的私密漏洞报告：仓库页面 **Security → Report a vulnerability**。我们会在 7 天内回复，确认问题后与你商定修复和披露时间。

报告里请写明：

- 受影响的版本或提交、平台（macOS / iOS / Android，或 CLI/MCP）
- 复现步骤和影响（例如工作区越权读取、设备认证绕过、API Key 泄露）
- 你建议的修复方式（可选）

## 不要贴密钥

**任何地方都不要贴 API Key、token、配对信息或 `.env` / `.envrc` 内容**，包括 Issue、PR、日志截图和诊断日志。需要附日志时先检查并删掉这些内容。

如果你不小心公开了自己的 Key，请立即到对应的服务商控制台（例如阿里云 DashScope 或 DeepSeek）吊销并重新生成。

## 范围

Koe 在本机保管录音。Apple 宿主使用系统 Keychain，Android 使用 Keystore 保护的加密存储。配置并触发云端任务时，Rust 根据所选模型及会议音频上传许可向服务商传送对应输入。以下问题在范围内：

- Key、录音、转写文字或个人记录被其他应用、其他设备或日志读到
- D3200 认证、加密或音频托管校验被绕过，或 macOS 本地 RPC 越过同 UID 边界
- 导入资料包（`.koepack`）或音频文件导致越权读写或崩溃

录音豆固件、阿里云 DashScope（千问）、DeepSeek 或 Apple 系统识别本身的问题请报告给对应厂商。

## 诊断包与资料包

- 脱敏诊断包移除密钥、原始 PCM 与用户私有原文。飞行记录保留事件顺序、时间、采样元数据及用于协议回放的 BLE 通知字节。回放使用临时工作区、隔离凭据与合成样本。
- CLI 指定 `koe doctor --bundle` 输出路径时以 `0600` 原子落盘，macOS 文件导出也设置 `0600`。iOS 在应用沙盒暂存后交给系统分享。Android 的 `FileProvider` 只映射应用缓存中独立的 `cache/koe-diagnostics/`，通过临时只读 URI 授权分享单个文件。
- `.koepack` 解码器只读解析输入字节，校验格式、长度、版本和纪要引用，拒绝含原音频的包及尾随字节。导入由上层工作区事务另行提交，包内元数据无法指定本机写入路径。见 [资料包格式](docs/material-pack.md)。

---

**Please do not report security issues in public issues or PRs.** Use GitHub private vulnerability reporting (**Security → Report a vulnerability**); we reply within 7 days. Never post API keys, tokens, pairing info or `.env` contents anywhere; if you leak a key, revoke it at the provider immediately.
