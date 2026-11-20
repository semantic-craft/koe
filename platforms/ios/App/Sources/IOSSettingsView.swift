import KoeAppleCore
import SwiftUI

struct IOSSettingsView: View {
    let store: HostSessionStore
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ModelSettingsDraft()

    var body: some View {
        let platform = store.platform
        let provider = store.settings.provider
        let speech = store.settings.speech

        NavigationStack {
            Form {
                Section {
                    DisclosureGroup {
                        LabeledContent("平台标识", value: platform.id)
                        LabeledContent("本机语音引擎", value: platform.nativeSpeechLabel)
                        LabeledContent("识别模式", value: speech.engine)
                        LabeledContent("Apple 本机状态", value: speech.appleMessage ?? speech.appleState)
                        LabeledContent {
                            Text(platform.supportsSystemAudio ? "可用" : "iOS 端不可用")
                        } label: {
                            HStack {
                                Text("系统音频录制")
                                IOSInfoTip("iOS 端不支持系统音频内录，请使用 iPhone 麦克风或 Soundcore Work 录音豆。", title: "iOS 音频限制")
                            }
                        }
                        LabeledContent("应用更新通道", value: platform.supportsSelfUpdate ? "应用内更新" : "App Store 分发")
                    } label: {
                        LabeledContent("宿主设备", value: platform.hostDisplayName)
                    }
                }

                Section("服务商凭据") {
                    credentialField("Qwen", key: $draft.qwenApiKey, slot: "qwen",
                                    state: provider.credentialState, configured: provider.qwenConfigured)
                    credentialField("DeepSeek", key: $draft.deepseekApiKey, slot: "deepseek",
                                    state: provider.deepseekCredentialState, configured: provider.deepseekConfigured)
                    settingsField("Qwen 业务空间 ID（可选）", text: $draft.qwenWorkspaceId)
                    LabeledContent("凭据存储", value: provider.isolated ? "隔离会话内存" : "系统钥匙串")
                }

                Section("语音识别（ASR）") {
                    Picker("提供方", selection: Binding(
                        get: { draft.asrProvider },
                        set: {
                            draft.asrProvider = $0
                            draft.customAsrEndpoint = ""
                        }
                    )) {
                        Text("Qwen").tag("qwen")
                        Text("DeepSeek").tag("deepseek")
                    }
                    if draft.asrProvider == "qwen" {
                        Picker("模型", selection: Binding(
                            get: { draft.qwenAsrModel },
                            set: {
                                draft.qwenAsrModel = $0
                                draft.customAsrEndpoint = ""
                            }
                        )) {
                            ForEach(ModelSettingsCatalog.qwenAsrModels) { option in
                                Text(option.id).tag(option.id)
                            }
                        }
                    }
                    DisclosureGroup("自定义识别端点") {
                        settingsField(draft.computedDefaultAsrEndpoint(), text: $draft.customAsrEndpoint)
                            .accessibilityLabel("识别接口地址")
                            .keyboardType(.URL)
                    }
                    Toggle(isOn: Binding(
                        get: { provider.meetingAudioPolicy == "cloud_allowed" },
                        set: { store.send(.setMeetingAudioPolicy(policy: $0 ? "cloud_allowed" : "local_only")) }
                    )) {
                        HStack {
                            Text("允许会议音频上传")
                            IOSInfoTip("此开关即时保存。关闭后会议音频留在本机，文本整理服务仍可处理转写文字。", title: "会议音频上传策略")
                        }
                    }
                    if let message = provider.meetingAudioPolicyError ?? provider.meetingAudioStatus {
                        Text(message).foregroundStyle(IOSColors.warning)
                    }
                }

                Section("文本整理与问答（LLM）") {
                    Picker("提供方", selection: Binding(
                        get: { draft.llmProvider },
                        set: { draft.selectLlmProvider($0) }
                    )) {
                        Text("DeepSeek").tag("deepseek")
                        Text("自定义兼容").tag("custom")
                    }
                    if draft.llmProvider == "custom" {
                        settingsField("自定义模型 ID", text: $draft.customLlmModel)
                        chatEndpoint
                    } else {
                        Picker("模型", selection: $draft.deepseekLlmModel) {
                            ForEach(ModelSettingsCatalog.deepseekLlmModels) { option in
                                Text(option.id).tag(option.id)
                            }
                        }
                        .accessibilityIdentifier("settings-llm-model")
                        DisclosureGroup("自定义对话端点") { chatEndpoint }
                    }
                    Toggle("纪要与问答启用深度思考", isOn: $draft.enableThinking)
                }
            }
            .font(.system(size: AppFontSizes.sm))
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .bottom) {
                if let error = store.navigation.effectiveError {
                    Text(error)
                        .foregroundStyle(IOSColors.danger)
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(.regularMaterial)
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                        .accessibilityIdentifier("settings-close")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存", action: saveConfiguration)
                        .accessibilityIdentifier("settings-save-button")
                }
            }
        }
        .onAppear { draft.sync(from: store.settings.provider) }
    }

    private func saveConfiguration() {
        store.send(draft.configureProviderCommand)
        if store.navigation.effectiveError == nil { dismiss() }
    }

    private func settingsField(_ placeholder: String, text: Binding<String>) -> some View {
        TextField(placeholder, text: text)
            .submitLabel(.done)
            .onSubmit(saveConfiguration)
    }

    private var chatEndpoint: some View {
        settingsField("https://your-host/v1/chat/completions", text: $draft.customChatEndpoint)
            .accessibilityLabel("对话接口地址")
            .keyboardType(.URL)
    }

    private func credentialField(
        _ name: String, key: Binding<String>, slot: String, state: String, configured: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(name).fontWeight(.semibold)
                Spacer()
                IOSBadge(credentialLabel(state), tint: configured ? IOSColors.success : IOSColors.textMuted)
            }
            HStack {
                SecureField(configured ? "留空保留已有密钥" : "输入 API Key", text: key)
                    .accessibilityLabel("\(name) API Key")
                    .submitLabel(.done)
                    .onSubmit(saveConfiguration)
                if configured {
                    Button("清除", role: .destructive) {
                        key.wrappedValue = ""
                        store.send(.clearProviderCredentialFor(provider: slot))
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("清除 \(name) 凭据")
                }
            }
        }
    }

    private func credentialLabel(_ state: String) -> String {
        switch state {
        case "ready": "已就绪"
        case "reopen_required": "需重新打开工作区"
        case "missing_saved": "需重新输入"
        case "unavailable": "暂不可用"
        default: "未设置"
        }
    }
}
