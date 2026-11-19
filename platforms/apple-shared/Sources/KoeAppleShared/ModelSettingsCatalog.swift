import Foundation

struct QwenAsrModelOption: Identifiable, Equatable {
    let id: String
    let note: String
    let badge: String?
    let isRealtime: Bool
    let endpointLabel: String
    let path: String
    let nonRealtimeWarning: String?
}

struct LlmModelOption: Identifiable, Equatable {
    let id: String
    let primaryBadge: String
    let primaryBadgeRecommended: Bool
    let metaBadges: [String]
    let description: String
}

enum ModelSettingsCatalog {
    static let qwenAsrModels: [QwenAsrModelOption] = [
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

    static let qwenLlmModels: [LlmModelOption] = [
        LlmModelOption(
            id: "qwen3.7-plus",
            primaryBadge: "均衡推荐",
            primaryBadgeRecommended: true,
            metaBadges: ["1M / 128K"],
            description: "百炼官方主推均衡档，替代旧版 qwen-plus，兼顾纪要质量、速度与成本。"
        ),
        LlmModelOption(
            id: "qwen4-max",
            primaryBadge: "旗舰 深度推理",
            primaryBadgeRecommended: false,
            metaBadges: ["1M / 262K"],
            description: "通义千问新一代旗舰模型，适合复杂会议纪要、多记录综合问答与长文梳理。"
        ),
        LlmModelOption(
            id: "qwen3.8-flash",
            primaryBadge: "极速低成本",
            primaryBadgeRecommended: false,
            metaBadges: ["1M / 128K"],
            description: "最新 Flash 系列，响应最快、单价最低，适合高频随心闪记与实时草稿。"
        )
    ]

    static let deepseekLlmModels: [LlmModelOption] = [
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

    static func qwenHost(workspaceId: String) -> String {
        let cleaned = workspaceId.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "dashscope.aliyuncs.com" : "\(cleaned).cn-beijing.maas.aliyuncs.com"
    }

    static func qwenAsrOption(for id: String) -> QwenAsrModelOption {
        qwenAsrModels.first(where: { $0.id == id }) ?? qwenAsrModels[0]
    }
}

struct ModelSettingsDraft: Equatable {
    var qwenApiKey = ""
    var deepseekApiKey = ""
    var qwenWorkspaceId = ""
    var customChatEndpoint = ""
    var customAsrEndpoint = ""
    var asrProvider = "qwen"
    var qwenAsrModel = "qwen-audio-3.1-asr-flash-streaming"
    var llmProvider = "qwen"
    var qwenLlmModel = "qwen3.7-plus"
    var deepseekLlmModel = "deepseek-flash"
    var customLlmModel = ""
    var enableThinking = false

    mutating func sync(from provider: ProviderSnapshot) {
        qwenWorkspaceId = provider.qwenWorkspaceId
        asrProvider = provider.asrProvider
        if ModelSettingsCatalog.qwenAsrModels.contains(where: { $0.id == provider.asrModel }) {
            qwenAsrModel = provider.asrModel
        } else if !provider.asrModel.isEmpty {
            qwenAsrModel = provider.asrModel
        }
        llmProvider = provider.llmProvider
        if provider.llmProvider == "deepseek" {
            deepseekLlmModel = provider.model.isEmpty ? "deepseek-flash" : provider.model
        } else if provider.llmProvider == "custom" {
            customLlmModel = provider.model
        } else {
            qwenLlmModel = provider.model.isEmpty ? "qwen3.7-plus" : provider.model
        }
        enableThinking = provider.enableThinking

        let defaultChat = computedDefaultChatEndpoint()
        customChatEndpoint = (provider.llmProvider == "custom" || provider.chatEndpoint != defaultChat)
            ? provider.chatEndpoint
            : ""
        let defaultAsr = computedDefaultAsrEndpoint()
        customAsrEndpoint = provider.asrEndpoint != defaultAsr ? provider.asrEndpoint : ""
    }

    var activeLlmModel: String {
        switch llmProvider {
        case "qwen": qwenLlmModel
        case "deepseek": deepseekLlmModel
        default: customLlmModel.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    func computedDefaultAsrEndpoint() -> String {
        if asrProvider == "deepseek" {
            return "https://api.deepseek.com/v1/tools/asr"
        }
        let host = ModelSettingsCatalog.qwenHost(workspaceId: qwenWorkspaceId)
        let meta = ModelSettingsCatalog.qwenAsrOption(for: qwenAsrModel)
        return (meta.isRealtime ? "wss://" : "https://") + host + meta.path
    }

    func effectiveAsrEndpoint() -> String {
        let custom = customAsrEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        return custom.isEmpty ? computedDefaultAsrEndpoint() : custom
    }

    func computedDefaultChatEndpoint() -> String {
        if llmProvider == "deepseek" {
            return "https://api.deepseek.com/chat/completions"
        }
        let host = ModelSettingsCatalog.qwenHost(workspaceId: qwenWorkspaceId)
        return "https://\(host)/compatible-mode/v1/chat/completions"
    }

    func effectiveChatEndpoint() -> String {
        let custom = customChatEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        if llmProvider == "custom" {
            return custom
        }
        return custom.isEmpty ? computedDefaultChatEndpoint() : custom
    }

    mutating func applyPreset(_ preset: String) {
        customAsrEndpoint = ""
        customChatEndpoint = ""
        switch preset {
        case "hybrid":
            asrProvider = "qwen"
            qwenAsrModel = "qwen-audio-3.1-asr-flash-streaming"
            llmProvider = "deepseek"
            deepseekLlmModel = "deepseek-flash"
        case "deepseek-full":
            asrProvider = "deepseek"
            llmProvider = "deepseek"
            deepseekLlmModel = "deepseek-flash"
        default:
            asrProvider = "qwen"
            qwenAsrModel = "qwen-audio-3.1-asr-flash-streaming"
            llmProvider = "qwen"
            qwenLlmModel = "qwen3.7-plus"
        }
    }

    func matchedPreset(speechEngine: String) -> String? {
        guard speechEngine == "cloud" else { return nil }
        if asrProvider == "qwen" && qwenAsrModel == "qwen-audio-3.1-asr-flash-streaming" && llmProvider == "qwen" {
            return "qwen-full"
        }
        if asrProvider == "qwen" && qwenAsrModel == "qwen-audio-3.1-asr-flash-streaming" && llmProvider == "deepseek" {
            return "hybrid"
        }
        if asrProvider == "deepseek" && llmProvider == "deepseek" {
            return "deepseek-full"
        }
        return nil
    }
}
