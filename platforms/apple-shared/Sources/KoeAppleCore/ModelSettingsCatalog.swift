import Foundation

public struct QwenAsrModelOption: Identifiable, Equatable, Sendable {
    public let id: String
    public let note: String
    public let badge: String?
    public let isRealtime: Bool
    public let endpointLabel: String
    public let path: String
    public let nonRealtimeWarning: String?

    public init(
        id: String,
        note: String,
        badge: String?,
        isRealtime: Bool,
        endpointLabel: String,
        path: String,
        nonRealtimeWarning: String?
    ) {
        self.id = id
        self.note = note
        self.badge = badge
        self.isRealtime = isRealtime
        self.endpointLabel = endpointLabel
        self.path = path
        self.nonRealtimeWarning = nonRealtimeWarning
    }
}

public struct LlmModelOption: Identifiable, Equatable, Sendable {
    public let id: String
    public let primaryBadge: String
    public let primaryBadgeRecommended: Bool
    public let metaBadges: [String]
    public let description: String

    public init(
        id: String,
        primaryBadge: String,
        primaryBadgeRecommended: Bool,
        metaBadges: [String],
        description: String
    ) {
        self.id = id
        self.primaryBadge = primaryBadge
        self.primaryBadgeRecommended = primaryBadgeRecommended
        self.metaBadges = metaBadges
        self.description = description
    }
}

public enum ModelSettingsCatalog {
    public static let qwenAsrModels: [QwenAsrModelOption] = [
        QwenAsrModelOption(
            id: "qwen-audio-3.1-asr-flash-streaming",
            note: "WebSocket 实时流式 | 会议/字幕/长录音 | 中间结果与时间戳",
            badge: "默认",
            isRealtime: true,
            endpointLabel: "当前 ASR 接口（WebSocket 实时流式）",
            path: "/api-ws/v1/inference",
            nonRealtimeWarning: nil
        ),
        QwenAsrModelOption(
            id: "qwen-audio-3.1-asr-flash-message",
            note: "WebSocket 实时短段 | 随心闪记 | 支持原生文本润色",
            badge: nil,
            isRealtime: true,
            endpointLabel: "当前 ASR 接口（WebSocket 实时短段）",
            path: "/api-ws/v1/inference",
            nonRealtimeWarning: nil
        ),
        QwenAsrModelOption(
            id: "qwen-audio-3.1-asr-flash",
            note: "HTTP 非实时（<=5 分钟）| 支持说话人分离与润色",
            badge: nil,
            isRealtime: false,
            endpointLabel: "当前 ASR 接口（HTTP 同步 <=5 分钟）",
            path: "/api/v1/services/aigc/multimodal-generation/generation",
            nonRealtimeWarning: "qwen-audio-3.1-asr-flash 为 HTTP 非实时接口（单段 <=5 分钟，支持说话人分离），录音结束后自动转写，不输出边录边看实时字幕。"
        ),
        QwenAsrModelOption(
            id: "qwen-audio-3.1-asr-flash-filetrans",
            note: "HTTP 异步长录音 | 录音豆离线文件 | 支持说话人分离",
            badge: nil,
            isRealtime: false,
            endpointLabel: "当前 ASR 接口（HTTP 异步任务）",
            path: "/api/v1/services/audio/asr/transcription",
            nonRealtimeWarning: "qwen-audio-3.1-asr-flash-filetrans 为异步文件转写任务（适合录音豆离线长录音并支持说话人分离），录音结束后自动转写，不输出实时字幕。"
        )
    ]

    public static let deepseekLlmModels: [LlmModelOption] = [
        LlmModelOption(
            id: "deepseek-flash",
            primaryBadge: "默认推荐",
            primaryBadgeRecommended: true,
            metaBadges: ["DeepSeek-V4.1-Flash", "1M / 384K"],
            description: "官方最新主力模型，空闲时段 1 元/百万输入、4 元/百万输出（高峰 2 元/8 元），支持思考切换。"
        ),
        LlmModelOption(
            id: "deepseek-v4-pro",
            primaryBadge: "旗舰推理",
            primaryBadgeRecommended: false,
            metaBadges: ["DeepSeek-V4-Pro", "1M / 384K"],
            description: "面向深度分析与复杂结构化纪要，空闲 4.5 元/13.5 元（高峰 9 元/27 元），最大输出 384K。"
        )
    ]

    public static func qwenHost(workspaceId: String) -> String {
        let cleaned = workspaceId.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "dashscope.aliyuncs.com" : "\(cleaned).cn-beijing.maas.aliyuncs.com"
    }

    public static func qwenAsrOption(for id: String) -> QwenAsrModelOption {
        qwenAsrModels.first(where: { $0.id == id }) ?? qwenAsrModels[0]
    }
}

public struct ModelSettingsDraft: Equatable, Sendable {
    public var qwenApiKey = ""
    public var deepseekApiKey = ""
    public var qwenWorkspaceId = ""
    public var customChatEndpoint = ""
    public var customAsrEndpoint = ""
    public var asrProvider = "qwen"
    public var qwenAsrModel = "qwen-audio-3.1-asr-flash-streaming"
    public var llmProvider = "deepseek"
    public var deepseekLlmModel = "deepseek-flash"
    public var customLlmModel = ""
    public var enableThinking = false

    public init() {}

    public mutating func sync(from provider: ProviderSnapshot) {
        qwenWorkspaceId = provider.qwenWorkspaceId
        asrProvider = provider.asrProvider == "deepseek" ? "deepseek" : "qwen"
        if ModelSettingsCatalog.qwenAsrModels.contains(where: { $0.id == provider.asrModel }) {
            qwenAsrModel = provider.asrModel
        } else if !provider.asrModel.isEmpty {
            qwenAsrModel = provider.asrModel
        }
        llmProvider = provider.llmProvider == "custom" ? "custom" : "deepseek"
        if llmProvider == "custom" {
            customLlmModel = provider.model
        } else {
            let validDeepSeek = provider.llmProvider == "deepseek" && !provider.model.isEmpty
            deepseekLlmModel = validDeepSeek ? provider.model : "deepseek-flash"
        }
        enableThinking = provider.enableThinking

        let defaultChat = computedDefaultChatEndpoint()
        customChatEndpoint = (llmProvider == "custom" || (provider.llmProvider == "deepseek" && provider.chatEndpoint != defaultChat))
            ? provider.chatEndpoint
            : ""
        let defaultAsr = computedDefaultAsrEndpoint()
        customAsrEndpoint = provider.asrEndpoint != defaultAsr ? provider.asrEndpoint : ""
    }

    public var configureProviderCommand: HostCommand {
        let trimmedQwen = qwenApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDeepseek = deepseekApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let asrEndpoint = customAsrEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        let chatEndpoint = customChatEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        return .configureProvider(
            apiKey: trimmedQwen.isEmpty ? nil : qwenApiKey,
            deepseekApiKey: trimmedDeepseek.isEmpty ? nil : deepseekApiKey,
            asrProvider: asrProvider,
            asrModel: asrProvider == "deepseek" ? "" : qwenAsrModel,
            llmProvider: llmProvider,
            model: resolvedLlmModelForSave,
            enableThinking: enableThinking,
            qwenWorkspaceId: qwenWorkspaceId.trimmingCharacters(in: .whitespacesAndNewlines),
            asrEndpoint: asrEndpoint,
            chatEndpoint: chatEndpoint
        )
    }

    public var activeLlmModel: String {
        switch llmProvider {
        case "custom": customLlmModel.trimmingCharacters(in: .whitespacesAndNewlines)
        default: deepseekLlmModel
        }
    }

    public var resolvedLlmModelForSave: String {
        switch llmProvider {
        case "custom": customLlmModel.trimmingCharacters(in: .whitespacesAndNewlines)
        default: deepseekLlmModel.isEmpty ? "deepseek-flash" : deepseekLlmModel
        }
    }

    public mutating func selectLlmProvider(_ provider: String) {
        let normalized = provider == "custom" ? "custom" : "deepseek"
        guard llmProvider != normalized else { return }
        llmProvider = normalized
        if normalized == "deepseek" {
            customChatEndpoint = ""
        }
    }

    public func computedDefaultAsrEndpoint() -> String {
        if asrProvider == "deepseek" {
            return "https://api.deepseek.com/v1/tools/asr"
        }
        let host = ModelSettingsCatalog.qwenHost(workspaceId: qwenWorkspaceId)
        let meta = ModelSettingsCatalog.qwenAsrOption(for: qwenAsrModel)
        return (meta.isRealtime ? "wss://" : "https://") + host + meta.path
    }

    public func effectiveAsrEndpoint() -> String {
        let custom = customAsrEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        return custom.isEmpty ? computedDefaultAsrEndpoint() : custom
    }

    public func computedDefaultChatEndpoint() -> String {
        "https://api.deepseek.com/chat/completions"
    }

    public func effectiveChatEndpoint() -> String {
        let custom = customChatEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        if llmProvider == "custom" {
            return custom
        }
        return custom.isEmpty ? computedDefaultChatEndpoint() : custom
    }

    public mutating func applyPreset(_ preset: String) {
        customAsrEndpoint = ""
        customChatEndpoint = ""
        switch preset {
        case "deepseek-full":
            asrProvider = "deepseek"
            llmProvider = "deepseek"
            deepseekLlmModel = "deepseek-flash"
        default:
            asrProvider = "qwen"
            qwenAsrModel = "qwen-audio-3.1-asr-flash-streaming"
            llmProvider = "deepseek"
            deepseekLlmModel = "deepseek-flash"
        }
    }

    public func matchedPreset(speechEngine: String) -> String? {
        guard speechEngine == "cloud" else { return nil }
        if asrProvider == "qwen" && qwenAsrModel == "qwen-audio-3.1-asr-flash-streaming" && llmProvider == "deepseek" {
            return "hybrid"
        }
        if asrProvider == "deepseek" && llmProvider == "deepseek" {
            return "deepseek-full"
        }
        return nil
    }
}
