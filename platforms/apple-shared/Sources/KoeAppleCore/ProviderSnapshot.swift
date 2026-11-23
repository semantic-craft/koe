import Foundation

public struct ProviderCatalogSnapshot: Codable, Equatable, Sendable {
    public let qwenAsrModels: [QwenAsrModelOption]
    public let deepseekLlmModels: [LlmModelOption]
    public let defaultQwenHost: String
    public let qwenWorkspaceHostSuffix: String
    public let defaultDeepseekAsrEndpoint: String
    public let defaultDeepseekChatEndpoint: String
    public let defaultQwenAsrModel: String
    public let defaultDeepseekLlmModel: String

    public init(
        qwenAsrModels: [QwenAsrModelOption],
        deepseekLlmModels: [LlmModelOption],
        defaultQwenHost: String,
        qwenWorkspaceHostSuffix: String,
        defaultDeepseekAsrEndpoint: String,
        defaultDeepseekChatEndpoint: String,
        defaultQwenAsrModel: String,
        defaultDeepseekLlmModel: String
    ) {
        self.qwenAsrModels = qwenAsrModels
        self.deepseekLlmModels = deepseekLlmModels
        self.defaultQwenHost = defaultQwenHost
        self.qwenWorkspaceHostSuffix = qwenWorkspaceHostSuffix
        self.defaultDeepseekAsrEndpoint = defaultDeepseekAsrEndpoint
        self.defaultDeepseekChatEndpoint = defaultDeepseekChatEndpoint
        self.defaultQwenAsrModel = defaultQwenAsrModel
        self.defaultDeepseekLlmModel = defaultDeepseekLlmModel
    }

    public func qwenHost(workspaceId: String) -> String {
        let cleaned = workspaceId.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? defaultQwenHost : "\(cleaned)\(qwenWorkspaceHostSuffix)"
    }

    public func qwenAsrOption(for id: String) -> QwenAsrModelOption {
        qwenAsrModels.first(where: { $0.id == id })
            ?? qwenAsrModels.first
            ?? ModelSettingsCatalog.qwenAsrModels[0]
    }

    public static let fallback = ProviderCatalogSnapshot(
        qwenAsrModels: ModelSettingsCatalog.qwenAsrModels,
        deepseekLlmModels: ModelSettingsCatalog.deepseekLlmModels,
        defaultQwenHost: "dashscope.aliyuncs.com",
        qwenWorkspaceHostSuffix: ".cn-beijing.maas.aliyuncs.com",
        defaultDeepseekAsrEndpoint: "https://api.deepseek.com/v1/tools/asr",
        defaultDeepseekChatEndpoint: "https://api.deepseek.com/chat/completions",
        defaultQwenAsrModel: "qwen-audio-3.1-asr-flash-streaming",
        defaultDeepseekLlmModel: "deepseek-flash"
    )
}

public struct ProviderSnapshot: Codable, Equatable, Sendable {
    public let meetingAudioPolicy: String
    public let meetingAudioStatus: String?
    public let meetingAudioPolicyError: String?
    public let configured: Bool
    public let qwenConfigured: Bool
    public let deepseekConfigured: Bool
    public let asrConfigured: Bool
    public let asrIsRealtime: Bool
    public let asrProvider: String
    public let asrModel: String
    public let llmProvider: String
    public let model: String
    public let enableThinking: Bool
    public let qwenWorkspaceId: String
    public let asrEndpoint: String
    public let chatEndpoint: String
    public let defaultAsrEndpoint: String?
    public let defaultChatEndpoint: String?
    public let catalog: ProviderCatalogSnapshot?
    public let credentialState: String
    public let deepseekCredentialState: String
    public let isolated: Bool

    public var effectiveCatalog: ProviderCatalogSnapshot { catalog ?? .fallback }

    private enum CodingKeys: String, CodingKey {
        case configured, qwenConfigured, deepseekConfigured, asrConfigured, asrIsRealtime
        case asrProvider, asrModel, llmProvider, model, enableThinking, qwenWorkspaceId
        case asrEndpoint, chatEndpoint, defaultAsrEndpoint, defaultChatEndpoint, catalog
        case credentialState, deepseekCredentialState, isolated
        case meetingAudioPolicy, meetingAudioStatus, meetingAudioPolicyError
    }

    public init(
        meetingAudioPolicy: String,
        meetingAudioStatus: String?,
        meetingAudioPolicyError: String?,
        configured: Bool,
        qwenConfigured: Bool,
        deepseekConfigured: Bool,
        asrConfigured: Bool,
        asrIsRealtime: Bool,
        asrProvider: String,
        asrModel: String,
        llmProvider: String,
        model: String,
        enableThinking: Bool,
        qwenWorkspaceId: String,
        asrEndpoint: String,
        chatEndpoint: String,
        defaultAsrEndpoint: String? = nil,
        defaultChatEndpoint: String? = nil,
        catalog: ProviderCatalogSnapshot? = nil,
        credentialState: String,
        deepseekCredentialState: String,
        isolated: Bool
    ) {
        self.meetingAudioPolicy = meetingAudioPolicy
        self.meetingAudioStatus = meetingAudioStatus
        self.meetingAudioPolicyError = meetingAudioPolicyError
        self.configured = configured
        self.qwenConfigured = qwenConfigured
        self.deepseekConfigured = deepseekConfigured
        self.asrConfigured = asrConfigured
        self.asrIsRealtime = asrIsRealtime
        self.asrProvider = asrProvider
        self.asrModel = asrModel
        self.llmProvider = llmProvider
        self.model = model
        self.enableThinking = enableThinking
        self.qwenWorkspaceId = qwenWorkspaceId
        self.asrEndpoint = asrEndpoint
        self.chatEndpoint = chatEndpoint
        self.defaultAsrEndpoint = defaultAsrEndpoint
        self.defaultChatEndpoint = defaultChatEndpoint
        self.catalog = catalog
        self.credentialState = credentialState
        self.deepseekCredentialState = deepseekCredentialState
        self.isolated = isolated
    }

    public var persistedModelFingerprint: [String] {
        [
            asrProvider,
            asrModel,
            llmProvider,
            model,
            String(enableThinking),
            qwenWorkspaceId,
            asrEndpoint,
            chatEndpoint,
        ]
    }

    public static let empty = ProviderSnapshot(
        meetingAudioPolicy: "local_only",
        meetingAudioStatus: nil,
        meetingAudioPolicyError: nil,
        configured: false,
        qwenConfigured: false,
        deepseekConfigured: false,
        asrConfigured: false,
        asrIsRealtime: true,
        asrProvider: "qwen",
        asrModel: "qwen-audio-3.1-asr-flash-streaming",
        llmProvider: "deepseek",
        model: "deepseek-flash",
        enableThinking: false,
        qwenWorkspaceId: "",
        asrEndpoint: "wss://dashscope.aliyuncs.com/api-ws/v1/inference",
        chatEndpoint: "https://api.deepseek.com/chat/completions",
        credentialState: "missing",
        deepseekCredentialState: "missing",
        isolated: true
    )
}

extension ProviderSnapshot {
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        meetingAudioPolicy = try values.decodeIfPresent(String.self, forKey: .meetingAudioPolicy) ?? "local_only"
        meetingAudioStatus = try values.decodeIfPresent(String.self, forKey: .meetingAudioStatus)
        meetingAudioPolicyError = try values.decodeIfPresent(String.self, forKey: .meetingAudioPolicyError)
        let configured = try values.decode(Bool.self, forKey: .configured)
        self.configured = configured
        qwenConfigured = try values.decodeIfPresent(Bool.self, forKey: .qwenConfigured) ?? configured
        deepseekConfigured = try values.decodeIfPresent(Bool.self, forKey: .deepseekConfigured) ?? false
        asrConfigured = try values.decodeIfPresent(Bool.self, forKey: .asrConfigured) ?? qwenConfigured
        asrIsRealtime = try values.decodeIfPresent(Bool.self, forKey: .asrIsRealtime) ?? true
        asrProvider = try values.decodeIfPresent(String.self, forKey: .asrProvider) ?? "qwen"
        asrModel = try values.decodeIfPresent(String.self, forKey: .asrModel) ?? "qwen-audio-3.1-asr-flash-streaming"
        llmProvider = try values.decodeIfPresent(String.self, forKey: .llmProvider) ?? "deepseek"
        model = try values.decode(String.self, forKey: .model)
        enableThinking = try values.decodeIfPresent(Bool.self, forKey: .enableThinking) ?? false
        qwenWorkspaceId = try values.decodeIfPresent(String.self, forKey: .qwenWorkspaceId) ?? ""
        asrEndpoint = try values.decodeIfPresent(String.self, forKey: .asrEndpoint) ?? ""
        chatEndpoint = try values.decodeIfPresent(String.self, forKey: .chatEndpoint) ?? ""
        defaultAsrEndpoint = try values.decodeIfPresent(String.self, forKey: .defaultAsrEndpoint)
        defaultChatEndpoint = try values.decodeIfPresent(String.self, forKey: .defaultChatEndpoint)
        catalog = try values.decodeIfPresent(ProviderCatalogSnapshot.self, forKey: .catalog)
        credentialState = try values.decodeIfPresent(String.self, forKey: .credentialState) ?? (configured ? "ready" : "missing")
        deepseekCredentialState = try values.decodeIfPresent(String.self, forKey: .deepseekCredentialState) ?? "missing"
        isolated = try values.decodeIfPresent(Bool.self, forKey: .isolated) ?? true
    }
}

public struct LifecycleSnapshot: Codable, Equatable, Sendable {
    public let keepAwake: Bool
    public let quitPhase: String
    public let message: String?

    public init(keepAwake: Bool, quitPhase: String, message: String? = nil) {
        self.keepAwake = keepAwake
        self.quitPhase = quitPhase
        self.message = message
    }
}
