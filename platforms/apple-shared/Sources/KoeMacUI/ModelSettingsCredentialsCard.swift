import SwiftUI

struct ModelSettingsCredentialsCard: View {
    let store: HostSessionStore
    @Binding var draft: ModelSettingsDraft
    let onSave: () -> Void
    @State private var showAdvancedEndpoints = false

    var body: some View {
        let provider = store.settings.provider
        KoeCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    Label("服务商凭证", systemImage: "key")
                        .font(.system(size: AppFontSizes.md, weight: .medium))
                    Spacer()
                    KoeBadge(
                        provider.isolated ? "隔离会话仅内存有效" : "密钥仅存 macOS 钥匙串，不回显明文",
                        tint: AppColors.textMuted
                    )
                }

                HStack(alignment: .top, spacing: 12) {
                    qwenCredentialBox(provider)
                    deepseekCredentialBox(provider)
                }

                if let warning = credentialWarning(provider) {
                    HStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(AppColors.warning)
                        Text(warning)
                            .font(.system(size: AppFontSizes.xs))
                            .foregroundStyle(AppColors.warning)
                        Spacer()
                        KoeActionButton("重试读取安全配置") {
                            store.send(.retryProviderCredentials(authorize: true))
                        }
                    }
                    .padding(10)
                    .background(AppColors.warning.opacity(0.08), in: RoundedRectangle(cornerRadius: AppRadii.control))
                }

                DisclosureGroup("高级：自定义 OpenAI 兼容或本机 localhost 服务", isExpanded: $showAdvancedEndpoints) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .top, spacing: 12) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("对话接口地址（支持 http://127.0.0.1）")
                                    .font(.system(size: AppFontSizes.xs))
                                    .foregroundStyle(AppColors.textSecondary)
                                TextField("https://your-host/v1/chat/completions", text: $draft.customChatEndpoint)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.system(size: AppFontSizes.xs, design: .monospaced))
                                    .onSubmit { onSave() }
                            }
                            VStack(alignment: .leading, spacing: 6) {
                                Text("语音识别 WebSocket / HTTP 地址")
                                    .font(.system(size: AppFontSizes.xs))
                                    .foregroundStyle(AppColors.textSecondary)
                                TextField("wss://your-host/api-ws/v1/inference", text: $draft.customAsrEndpoint)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.system(size: AppFontSizes.xs, design: .monospaced))
                                    .onSubmit { onSave() }
                            }
                        }
                        Text("本机 http://127.0.0.1 服务免填密钥；远程自定义 HTTPS 服务复用上方已保存的 API Key。")
                            .font(.system(size: AppFontSizes.xs))
                            .foregroundStyle(AppColors.textMuted)
                    }
                    .padding(.top, 10)
                }
                .font(.system(size: AppFontSizes.xs))
                .foregroundStyle(AppColors.textSecondary)
            }
        }
    }

    private func qwenCredentialBox(_ provider: ProviderSnapshot) -> some View {
        let active = draft.asrProvider == "qwen"
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Qwen（阿里云百炼）")
                    .font(.system(size: AppFontSizes.sm, weight: .semibold))
                Spacer()
                KoeBadge(
                    provider.qwenConfigured ? "已配置" : "未配置",
                    tint: provider.qwenConfigured ? AppColors.success : AppColors.textMuted
                )
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("API Key").font(.system(size: AppFontSizes.xs)).foregroundStyle(AppColors.textSecondary)
                    Spacer()
                    Text("DASHSCOPE_API_KEY").font(.system(size: AppFontSizes.xs, design: .monospaced)).foregroundStyle(AppColors.textMuted)
                }
                HStack(spacing: 6) {
                    SecureField(
                        provider.qwenConfigured ? "已保存在钥匙串，留空保持不变" : "粘贴阿里云百炼 API Key",
                        text: $draft.qwenApiKey
                    )
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: AppFontSizes.xs, design: .monospaced))
                    .onSubmit { onSave() }
                    KoeActionButton("清除") {
                        draft.qwenApiKey = ""
                        store.send(.clearProviderCredential(provider: "qwen"))
                    }
                    .disabled(!provider.qwenConfigured && draft.qwenApiKey.isEmpty)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("业务空间 ID（可选）").font(.system(size: AppFontSizes.xs)).foregroundStyle(AppColors.textSecondary)
                    Spacer()
                    Text("华北 2 北京").font(.system(size: AppFontSizes.xs)).foregroundStyle(AppColors.textMuted)
                }
                TextField("留空使用 dashscope.aliyuncs.com", text: $draft.qwenWorkspaceId)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: AppFontSizes.xs, design: .monospaced))
                    .onSubmit { onSave() }
            }
            HStack(spacing: 6) {
                KoeBadge("主力 ASR", tint: AppColors.success)
                KoeBadge("流式 / 异步转写", tint: AppColors.textSecondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(active ? AppColors.surface0 : AppColors.bgSubtle, in: RoundedRectangle(cornerRadius: AppRadii.control))
        .overlay(RoundedRectangle(cornerRadius: AppRadii.control).stroke(active ? AppColors.accent.opacity(0.45) : AppColors.border))
    }

    private func deepseekCredentialBox(_ provider: ProviderSnapshot) -> some View {
        let active = draft.asrProvider == "deepseek" || draft.llmProvider == "deepseek"
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("DeepSeek（官方 API）")
                    .font(.system(size: AppFontSizes.sm, weight: .semibold))
                Spacer()
                KoeBadge(
                    provider.deepseekConfigured ? "已配置" : "未配置",
                    tint: provider.deepseekConfigured ? AppColors.success : AppColors.textMuted
                )
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("API Key").font(.system(size: AppFontSizes.xs)).foregroundStyle(AppColors.textSecondary)
                    Spacer()
                    Text("DEEPSEEK_API_KEY").font(.system(size: AppFontSizes.xs, design: .monospaced)).foregroundStyle(AppColors.textMuted)
                }
                HStack(spacing: 6) {
                    SecureField(
                        provider.deepseekConfigured ? "已保存在钥匙串，留空保持不变" : "粘贴 DeepSeek 官方 API Key",
                        text: $draft.deepseekApiKey
                    )
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: AppFontSizes.xs, design: .monospaced))
                    .onSubmit { onSave() }
                    KoeActionButton("清除") {
                        draft.deepseekApiKey = ""
                        store.send(.clearProviderCredential(provider: "deepseek"))
                    }
                    .disabled(!provider.deepseekConfigured && draft.deepseekApiKey.isEmpty)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("官方接口基址").font(.system(size: AppFontSizes.xs)).foregroundStyle(AppColors.textSecondary)
                    Spacer()
                    Text("OpenAI 兼容").font(.system(size: AppFontSizes.xs)).foregroundStyle(AppColors.textMuted)
                }
                Text("https://api.deepseek.com")
                    .font(.system(size: AppFontSizes.xs, design: .monospaced))
                    .foregroundStyle(AppColors.textSecondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(AppColors.bgSubtle, in: RoundedRectangle(cornerRadius: 4))
            }
            HStack(spacing: 6) {
                KoeBadge("默认文本 LLM", tint: AppColors.success)
                KoeBadge("可选短语音 ASR（<=120s）", tint: AppColors.textSecondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(active ? AppColors.surface0 : AppColors.bgSubtle, in: RoundedRectangle(cornerRadius: AppRadii.control))
        .overlay(RoundedRectangle(cornerRadius: AppRadii.control).stroke(active ? AppColors.accent.opacity(0.45) : AppColors.border))
    }

    private func credentialWarning(_ provider: ProviderSnapshot) -> String? {
        for state in [provider.credentialState, provider.deepseekCredentialState] {
            switch state {
            case "reopen_required":
                return "工作区保存结果尚未确认，请退出并重新打开 Koe。"
            case "missing_saved":
                return "已保存的密钥在当前安全存储中不存在，请重新输入或清除。"
            case "unavailable":
                return "安全凭据暂不可读取，云端处理已停用。"
            default:
                continue
            }
        }
        return nil
    }
}
