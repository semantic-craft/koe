import KoeAppleCore
import SwiftUI
import UniformTypeIdentifiers

struct IOSSettingsView: View {
    let store: HostSessionStore
    private let onExportDiagnostics: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focusedField: String?
    @State private var draft = ModelSettingsDraft()
    @State private var didInitialize = false

    @State private var trace: IOSTraceDocument?
    @State private var exportingTrace = false

    init(store: HostSessionStore, onExportDiagnostics: (() -> Void)? = nil) {
        self.store = store
        self.onExportDiagnostics = onExportDiagnostics
    }

    var body: some View {
        let platform = store.platform
        let provider = store.settings.provider
        let catalog = provider.effectiveCatalog
        let speech = store.settings.speech

        NavigationStack {
            Form {
                Section {
                    DisclosureGroup {
                        LabeledContent("平台标识", value: platform.id)
                        LabeledContent("本机语音引擎", value: platform.nativeSpeechLabel)
                        LabeledContent("识别模式", value: engineLabel(speech.engine))
                        LabeledContent("Apple 本机状态", value: appleStateLabel(speech.appleState))
                        LabeledContent {
                            Text(platform.supportsSystemAudio ? "可用" : "iOS 端不可用")
                        } label: {
                            HStack {
                                Text("系统音频录制")
                                IOSInfoTip("iOS 端不支持系统音频内录，请使用本机麦克风或 Soundcore Work 录音豆。", title: "iOS 音频限制")
                            }
                        }
                        LabeledContent("应用更新通道", value: platform.supportsSelfUpdate ? "应用内更新" : "App Store 分发")
                    } label: {
                        LabeledContent("宿主设备", value: platform.hostDisplayName)
                    }
                }

                Section("官方模型组合") {
                    IOSModelPresets(store: store, draft: $draft)
                }
                Section("服务商凭据") {
                    if [provider.credentialState, provider.deepseekCredentialState].contains(where: { ["unavailable", "missing_saved", "reopen_required"].contains($0) }) {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("服务商凭据需要恢复", systemImage: "exclamationmark.triangle")
                                .foregroundStyle(IOSColors.warning)
                            Button("重试读取安全配置") { store.send(.retryProviderCredentials(authorize: true)) }
                        }
                    }
                    credentialField("Qwen", key: $draft.qwenApiKey, slot: "qwen",
                                    state: provider.credentialState, configured: provider.qwenConfigured)
                    credentialField("DeepSeek", key: $draft.deepseekApiKey, slot: "deepseek",
                                    state: provider.deepseekCredentialState, configured: provider.deepseekConfigured)
                    settingsField("Qwen 业务空间 ID（可选）", text: $draft.qwenWorkspaceId)
                    LabeledContent("凭据存储", value: provider.isolated ? "隔离会话内存" : "系统钥匙串")
                }

                Section("语音识别（ASR）") {
                    Picker("识别引擎", selection: Binding(
                        get: { speech.engine },
                        set: { store.send(.configureSpeech(engine: $0)) }
                    )) {
                        Text("Apple 本机").tag("apple_speech")
                        Text("云端识别").tag("cloud")
                        if speech.engine == "downloaded" { Text("下载的本机模型").tag("downloaded") }
                    }
                    .accessibilityIdentifier("settings-speech-engine")
                    if speech.engine == "apple_speech" {
                        LabeledContent("本机状态", value: appleStateLabel(speech.appleState))
                        if speech.appleState == "unavailable" {
                            Text(speech.appleMessage ?? "此设备暂时无法进行本机识别，原始录音仍会保存。")
                                .foregroundStyle(IOSColors.textSecondary)
                            Button("切换为云端识别") { store.send(.configureSpeech(engine: "cloud")) }
                        }
                    }
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
                            ForEach(catalog.qwenAsrModels) { option in
                                Text(option.id).tag(option.id)
                            }
                        }
                    }
                    IOSSpeechModeNotice(draft: draft, catalog: catalog)
                    DisclosureGroup("自定义识别端点") {
                        settingsField(draft.computedDefaultAsrEndpoint(catalog: catalog), text: $draft.customAsrEndpoint)
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
                            ForEach(catalog.deepseekLlmModels) { option in
                                Text(option.id).tag(option.id)
                            }
                        }
                        .accessibilityIdentifier("settings-llm-model")
                        DisclosureGroup("自定义对话端点") { chatEndpoint }
                    }
                    Toggle("纪要与问答启用深度思考", isOn: $draft.enableThinking)
                }
                Section("关于 Koe") {
                    LabeledContent("版本", value: store.settings.appUpdate.versionWithBuildLabel)
                    if let onExportDiagnostics {
                        Button("导出诊断包") {
                            onExportDiagnostics()
                            dismiss()
                        }
                        .accessibilityIdentifier("settings-export-diagnostics-bundle")
                    }
                    Button("导出诊断追踪") {
                        trace = IOSTraceDocument(json: store.exportTraceJSON())
                        exportingTrace = true
                    }
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
        .fileExporter(isPresented: $exportingTrace, document: trace, contentType: .json, defaultFilename: "koe-trace") { result in
            trace = nil
            if case .failure(let error) = result { store.reportNativeError(error.localizedDescription) }
        }
        .onAppear {
            if !didInitialize {
                draft.sync(from: store.settings.provider)
                didInitialize = true
            }
        }
        .onChange(of: store.settings.provider.persistedModelFingerprint) { _, _ in
            draft.sync(from: store.settings.provider)
        }
        .onDisappear {
            draft.qwenApiKey = ""
            draft.deepseekApiKey = ""
        }
    }

    private func saveConfiguration() {
        if store.sendReturningError(draft.configureProviderCommand) == nil {
            draft.qwenApiKey = ""
            draft.deepseekApiKey = ""
            dismiss()
        }
    }

    private func settingsField(_ placeholder: String, text: Binding<String>) -> some View {
        TextField(placeholder, text: text)
            .focused($focusedField, equals: placeholder)
            .submitLabel(.done)
            .onSubmit { focusedField = nil }
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
                    .focused($focusedField, equals: slot)
                    .accessibilityLabel("\(name) API Key")
                    .submitLabel(.done)
                    .onSubmit { focusedField = nil }
                if configured {
                    Button("清除", role: .destructive) {
                        key.wrappedValue = ""
                        store.send(.clearProviderCredential(provider: slot))
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("清除 \(name) 凭据")
                }
            }
        }
    }

    private func engineLabel(_ engine: String) -> String {
        switch engine {
        case "apple_speech": "Apple 本机"
        case "cloud": "云端识别"
        case "downloaded": "下载的本机模型"
        default: "未知引擎"
        }
    }

    private func appleStateLabel(_ state: String) -> String {
        switch state {
        case "ready": "已就绪"
        case "preparing": "准备中"
        case "unavailable": "暂不可用"
        default: "状态未知"
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

private struct IOSTraceDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.json]
    let data: Data

    init(json: String) { data = Data(json.utf8) }
    init(configuration: ReadConfiguration) throws {
        guard let contents = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        data = contents
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
