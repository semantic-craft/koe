package com.semanticcraft.koe.core

import kotlinx.serialization.Serializable

@Serializable
data class QwenAsrModelOption(
    val id: String,
    val note: String,
    val badge: String? = null,
    val isRealtime: Boolean,
    val endpointLabel: String,
    val path: String,
    val nonRealtimeWarning: String? = null,
)

@Serializable
data class LlmModelOption(
    val id: String,
    val primaryBadge: String,
    val primaryBadgeRecommended: Boolean,
    val metaBadges: List<String>,
    val description: String,
)

@Serializable
data class ProviderCatalogSnapshot(
    val qwenAsrModels: List<QwenAsrModelOption>,
    val deepseekLlmModels: List<LlmModelOption>,
    val defaultQwenHost: String,
    val qwenWorkspaceHostSuffix: String,
    val defaultDeepseekAsrEndpoint: String,
    val defaultDeepseekChatEndpoint: String,
    val defaultQwenAsrModel: String,
    val defaultDeepseekLlmModel: String,
) {
    fun qwenHost(workspaceId: String): String {
        val cleaned = workspaceId.trim()
        return if (cleaned.isEmpty()) defaultQwenHost else "$cleaned$qwenWorkspaceHostSuffix"
    }

    fun qwenAsrOption(id: String): QwenAsrModelOption =
        qwenAsrModels.firstOrNull { it.id == id }
            ?: qwenAsrModels.firstOrNull()
            ?: ModelSettingsCatalog.qwenAsrModels[0]
}

object ModelSettingsCatalog {
    val qwenAsrModels: List<QwenAsrModelOption> = listOf(
        QwenAsrModelOption(
            id = "qwen-audio-3.1-asr-flash-streaming",
            note = "WebSocket 实时流式 | 会议/字幕/长录音 | 中间结果与时间戳",
            badge = "默认",
            isRealtime = true,
            endpointLabel = "当前 ASR 接口（WebSocket 实时流式）",
            path = "/api-ws/v1/inference",
            nonRealtimeWarning = null,
        ),
        QwenAsrModelOption(
            id = "qwen-audio-3.1-asr-flash-message",
            note = "WebSocket 实时短段 | 随心闪记 | 支持原生文本润色",
            badge = null,
            isRealtime = true,
            endpointLabel = "当前 ASR 接口（WebSocket 实时短段）",
            path = "/api-ws/v1/inference",
            nonRealtimeWarning = null,
        ),
        QwenAsrModelOption(
            id = "qwen-audio-3.1-asr-flash",
            note = "HTTP 非实时（<=5 分钟）| 支持说话人分离与润色",
            badge = null,
            isRealtime = false,
            endpointLabel = "当前 ASR 接口（HTTP 同步 <=5 分钟）",
            path = "/api/v1/services/aigc/multimodal-generation/generation",
            nonRealtimeWarning = "qwen-audio-3.1-asr-flash 为 HTTP 非实时接口（单段 <=5 分钟，支持说话人分离），录音结束后自动转写，不输出边录边看实时字幕。",
        ),
        QwenAsrModelOption(
            id = "qwen-audio-3.1-asr-flash-filetrans",
            note = "HTTP 异步长录音 | 录音豆离线文件 | 支持说话人分离",
            badge = null,
            isRealtime = false,
            endpointLabel = "当前 ASR 接口（HTTP 异步任务）",
            path = "/api/v1/services/audio/asr/transcription",
            nonRealtimeWarning = "qwen-audio-3.1-asr-flash-filetrans 为异步文件转写任务（适合录音豆离线长录音并支持说话人分离），录音结束后自动转写，不输出实时字幕。",
        ),
    )

    val deepseekLlmModels: List<LlmModelOption> = listOf(
        LlmModelOption(
            id = "deepseek-flash",
            primaryBadge = "默认推荐",
            primaryBadgeRecommended = true,
            metaBadges = listOf("DeepSeek-V4.1-Flash", "1M / 384K"),
            description = "官方最新主力模型，空闲时段 1 元/百万输入、4 元/百万输出（高峰 2 元/8 元），支持思考切换。",
        ),
        LlmModelOption(
            id = "deepseek-v4-pro",
            primaryBadge = "旗舰推理",
            primaryBadgeRecommended = false,
            metaBadges = listOf("DeepSeek-V4-Pro", "1M / 384K"),
            description = "面向深度分析与复杂结构化纪要，空闲 4.5 元/13.5 元（高峰 9 元/27 元），最大输出 384K。",
        ),
    )

    val fallback: ProviderCatalogSnapshot = ProviderCatalogSnapshot(
        qwenAsrModels = qwenAsrModels,
        deepseekLlmModels = deepseekLlmModels,
        defaultQwenHost = "dashscope.aliyuncs.com",
        qwenWorkspaceHostSuffix = ".cn-beijing.maas.aliyuncs.com",
        defaultDeepseekAsrEndpoint = "https://api.deepseek.com/v1/tools/asr",
        defaultDeepseekChatEndpoint = "https://api.deepseek.com/chat/completions",
        defaultQwenAsrModel = "qwen-audio-3.1-asr-flash-streaming",
        defaultDeepseekLlmModel = "deepseek-flash",
    )

    fun qwenHost(workspaceId: String): String = fallback.qwenHost(workspaceId)

    fun qwenAsrOption(id: String): QwenAsrModelOption = fallback.qwenAsrOption(id)
}

data class ModelSettingsDraft(
    val qwenApiKey: String = "",
    val deepseekApiKey: String = "",
    val qwenWorkspaceId: String = "",
    val customChatEndpoint: String = "",
    val customAsrEndpoint: String = "",
    val asrProvider: String = "qwen",
    val qwenAsrModel: String = "qwen-audio-3.1-asr-flash-streaming",
    val llmProvider: String = "deepseek",
    val deepseekLlmModel: String = "deepseek-flash",
    val customLlmModel: String = "",
    val enableThinking: Boolean = false,
) {
    val activeLlmModel: String
        get() = when (llmProvider) {
            "custom" -> customLlmModel.trim()
            else -> deepseekLlmModel
        }

    val resolvedLlmModelForSave: String
        get() = when (llmProvider) {
            "custom" -> customLlmModel.trim()
            else -> deepseekLlmModel.ifEmpty { ModelSettingsCatalog.fallback.defaultDeepseekLlmModel }
        }

    fun syncWith(provider: ProviderSnapshot): ModelSettingsDraft {
        val catalog = provider.effectiveCatalog
        val nextAsrProvider = if (provider.asrProvider == "deepseek") "deepseek" else "qwen"
        val nextQwenAsrModel = if (provider.asrModel.isNotEmpty()) provider.asrModel else qwenAsrModel
        val nextLlmProvider = if (provider.llmProvider == "custom") "custom" else "deepseek"
        val nextCustomLlmModel = if (nextLlmProvider == "custom") provider.model else customLlmModel
        val nextDeepseekLlmModel = if (nextLlmProvider == "custom") {
            deepseekLlmModel
        } else if (provider.llmProvider == "deepseek" && provider.model.isNotEmpty()) {
            provider.model
        } else {
            catalog.defaultDeepseekLlmModel
        }

        val updated = copy(
            qwenWorkspaceId = provider.qwenWorkspaceId,
            asrProvider = nextAsrProvider,
            qwenAsrModel = nextQwenAsrModel,
            llmProvider = nextLlmProvider,
            deepseekLlmModel = nextDeepseekLlmModel,
            customLlmModel = nextCustomLlmModel,
            enableThinking = provider.enableThinking,
        )
        val defaultChat = provider.defaultChatEndpoint ?: updated.computedDefaultChatEndpoint(catalog)
        val nextCustomChatEndpoint = if (
            nextLlmProvider == "custom" ||
            (provider.llmProvider == "deepseek" && provider.chatEndpoint != defaultChat)
        ) {
            provider.chatEndpoint
        } else {
            ""
        }
        val defaultAsr = provider.defaultAsrEndpoint ?: updated.computedDefaultAsrEndpoint(catalog)
        val nextCustomAsrEndpoint = if (provider.asrEndpoint != defaultAsr) provider.asrEndpoint else ""
        return updated.copy(
            customChatEndpoint = nextCustomChatEndpoint,
            customAsrEndpoint = nextCustomAsrEndpoint,
        )
    }

    fun selectLlmProvider(provider: String): ModelSettingsDraft {
        val normalized = if (provider == "custom") "custom" else "deepseek"
        if (llmProvider == normalized) return this
        return if (normalized == "deepseek") {
            copy(llmProvider = normalized, customChatEndpoint = "")
        } else {
            copy(llmProvider = normalized)
        }
    }

    fun computedDefaultAsrEndpoint(catalog: ProviderCatalogSnapshot = ModelSettingsCatalog.fallback): String {
        if (asrProvider == "deepseek") {
            return catalog.defaultDeepseekAsrEndpoint
        }
        val host = catalog.qwenHost(qwenWorkspaceId)
        val meta = catalog.qwenAsrOption(qwenAsrModel)
        val scheme = if (meta.isRealtime) "wss://" else "https://"
        return scheme + host + meta.path
    }

    fun effectiveAsrEndpoint(catalog: ProviderCatalogSnapshot = ModelSettingsCatalog.fallback): String {
        val custom = customAsrEndpoint.trim()
        return custom.ifEmpty { computedDefaultAsrEndpoint(catalog) }
    }

    fun computedDefaultChatEndpoint(catalog: ProviderCatalogSnapshot = ModelSettingsCatalog.fallback): String =
        catalog.defaultDeepseekChatEndpoint

    fun effectiveChatEndpoint(catalog: ProviderCatalogSnapshot = ModelSettingsCatalog.fallback): String {
        val custom = customChatEndpoint.trim()
        if (llmProvider == "custom") return custom
        return custom.ifEmpty { computedDefaultChatEndpoint(catalog) }
    }

    fun applyPreset(preset: String, catalog: ProviderCatalogSnapshot = ModelSettingsCatalog.fallback): ModelSettingsDraft =
        when (preset) {
            "deepseek-full" -> copy(
                customAsrEndpoint = "",
                customChatEndpoint = "",
                asrProvider = "deepseek",
                llmProvider = "deepseek",
                deepseekLlmModel = catalog.defaultDeepseekLlmModel,
            )
            else -> copy(
                customAsrEndpoint = "",
                customChatEndpoint = "",
                asrProvider = "qwen",
                qwenAsrModel = catalog.defaultQwenAsrModel,
                llmProvider = "deepseek",
                deepseekLlmModel = catalog.defaultDeepseekLlmModel,
            )
        }

    fun matchedPreset(speechEngine: String, catalog: ProviderCatalogSnapshot = ModelSettingsCatalog.fallback): String? {
        if (speechEngine != "cloud") return null
        if (asrProvider == "qwen" && qwenAsrModel == catalog.defaultQwenAsrModel && llmProvider == "deepseek") {
            return "hybrid"
        }
        if (asrProvider == "deepseek" && llmProvider == "deepseek") {
            return "deepseek-full"
        }
        return null
    }

    fun clearingApiKeyInputs(): ModelSettingsDraft = copy(
        qwenApiKey = "",
        deepseekApiKey = "",
    )

    fun toConfigureProviderCommand(): HostCommand.ConfigureProvider = HostCommand.ConfigureProvider(
        apiKey = qwenApiKey.trim().ifEmpty { null },
        deepseekApiKey = deepseekApiKey.trim().ifEmpty { null },
        asrProvider = asrProvider,
        asrModel = if (asrProvider == "deepseek") "" else qwenAsrModel,
        llmProvider = llmProvider,
        model = resolvedLlmModelForSave,
        enableThinking = enableThinking,
        qwenWorkspaceId = qwenWorkspaceId.trim(),
        asrEndpoint = customAsrEndpoint.trim(),
        chatEndpoint = customChatEndpoint.trim(),
    )

    companion object {
        fun from(provider: ProviderSnapshot): ModelSettingsDraft =
            ModelSettingsDraft().syncWith(provider)
    }
}
