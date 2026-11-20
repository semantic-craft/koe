package com.semanticcraft.koe.core

import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ModelSettingsCatalogTest {
    @Test
    fun syncFromProviderPopulatesFieldsDetectsCustomEndpointsAndPreservesTypedKeys() {
        val provider = ProviderSnapshot(
            asrProvider = "qwen",
            asrModel = "qwen-audio-3.1-asr-flash-filetrans",
            llmProvider = "deepseek",
            model = "deepseek-v4-pro",
            enableThinking = true,
            qwenWorkspaceId = "ws-bj-01",
            asrEndpoint = "https://ws-bj-01.cn-beijing.maas.aliyuncs.com/api/v1/services/audio/asr/transcription",
            chatEndpoint = "https://proxy.example.com/v1/chat/completions",
        )

        val initial = ModelSettingsDraft(
            qwenApiKey = "sk-qwen-typed",
            deepseekApiKey = "sk-ds-typed",
        ).syncWith(provider)

        assertEquals("sk-qwen-typed", initial.qwenApiKey)
        assertEquals("sk-ds-typed", initial.deepseekApiKey)
        assertEquals("qwen", initial.asrProvider)
        assertEquals("qwen-audio-3.1-asr-flash-filetrans", initial.qwenAsrModel)
        assertEquals("deepseek", initial.llmProvider)
        assertEquals("deepseek-v4-pro", initial.deepseekLlmModel)
        assertTrue(initial.enableThinking)
        assertEquals("ws-bj-01", initial.qwenWorkspaceId)
        assertEquals("", initial.customAsrEndpoint)
        assertEquals("https://proxy.example.com/v1/chat/completions", initial.customChatEndpoint)

        val cleared = initial.clearingApiKeyInputs()
        assertEquals("", cleared.qwenApiKey)
        assertEquals("", cleared.deepseekApiKey)
        assertEquals("deepseek-v4-pro", cleared.deepseekLlmModel)
    }

    @Test
    fun selectLlmProviderClearsCustomChatEndpointOnlyWhenReturningToDeepSeek() {
        val customDraft = ModelSettingsDraft.from(ProviderSnapshot.empty)
            .selectLlmProvider("custom")
            .copy(
                customLlmModel = "qwen2.5:14b",
                customChatEndpoint = "http://127.0.0.1:11434/v1/chat/completions",
            )

        assertEquals("custom", customDraft.llmProvider)
        assertEquals("qwen2.5:14b", customDraft.activeLlmModel)
        assertEquals("http://127.0.0.1:11434/v1/chat/completions", customDraft.effectiveChatEndpoint())

        val emptyCustom = customDraft.copy(customChatEndpoint = "   ")
        assertEquals("", emptyCustom.effectiveChatEndpoint())

        val backToDeepSeek = customDraft.selectLlmProvider("deepseek")
        assertEquals("deepseek", backToDeepSeek.llmProvider)
        assertEquals("", backToDeepSeek.customChatEndpoint)
        assertEquals("https://api.deepseek.com/chat/completions", backToDeepSeek.effectiveChatEndpoint())
    }

    @Test
    fun presetsApplyHybridAndDeepSeekFullAndMatchCloudSpeechEngineOnly() {
        val base = ModelSettingsDraft(
            customAsrEndpoint = "https://custom-asr.example.com",
            customChatEndpoint = "https://custom-chat.example.com",
            qwenAsrModel = "qwen-audio-3.1-asr-flash",
            llmProvider = "custom",
        )

        val deepseekFull = base.applyPreset("deepseek-full")
        assertEquals("deepseek", deepseekFull.asrProvider)
        assertEquals("deepseek", deepseekFull.llmProvider)
        assertEquals("deepseek-flash", deepseekFull.deepseekLlmModel)
        assertEquals("", deepseekFull.customAsrEndpoint)
        assertEquals("", deepseekFull.customChatEndpoint)
        assertEquals("deepseek-full", deepseekFull.matchedPreset("cloud"))
        assertNull(deepseekFull.matchedPreset("apple_speech"))

        val hybrid = deepseekFull.applyPreset("hybrid")
        assertEquals("qwen", hybrid.asrProvider)
        assertEquals("qwen-audio-3.1-asr-flash-streaming", hybrid.qwenAsrModel)
        assertEquals("deepseek", hybrid.llmProvider)
        assertEquals("deepseek-flash", hybrid.deepseekLlmModel)
        assertEquals("hybrid", hybrid.matchedPreset("cloud"))
        assertNull(hybrid.matchedPreset("downloaded"))
    }

    @Test
    fun effectiveAsrEndpointResolvesQwenProtocolsWorkspaceHostDeepSeekAndCustomOverride() {
        assertEquals(4, ModelSettingsCatalog.qwenAsrModels.size)
        assertEquals(2, ModelSettingsCatalog.deepseekLlmModels.size)

        val streaming = ModelSettingsDraft(
            asrProvider = "qwen",
            qwenAsrModel = "qwen-audio-3.1-asr-flash-streaming",
        )
        assertEquals("wss://dashscope.aliyuncs.com/api-ws/v1/inference", streaming.effectiveAsrEndpoint())

        val filetrans = streaming.copy(qwenAsrModel = "qwen-audio-3.1-asr-flash-filetrans")
        assertEquals(
            "https://dashscope.aliyuncs.com/api/v1/services/audio/asr/transcription",
            filetrans.effectiveAsrEndpoint(),
        )
        assertTrue(ModelSettingsCatalog.qwenAsrOption(filetrans.qwenAsrModel).nonRealtimeWarning != null)

        val workspaceStreaming = streaming.copy(qwenWorkspaceId = "  ws-prod-42  ")
        assertEquals(
            "wss://ws-prod-42.cn-beijing.maas.aliyuncs.com/api-ws/v1/inference",
            workspaceStreaming.effectiveAsrEndpoint(),
        )

        val deepseek = streaming.copy(asrProvider = "deepseek")
        assertEquals("https://api.deepseek.com/v1/tools/asr", deepseek.effectiveAsrEndpoint())

        val overridden = deepseek.copy(customAsrEndpoint = "  ws://127.0.0.1:9001/asr  ")
        assertEquals("ws://127.0.0.1:9001/asr", overridden.effectiveAsrEndpoint())
    }

    @Test
    fun toConfigureProviderCommandOmitsBlankKeysTrimsSecretsAndClearsDeepSeekAsrModel() {
        val blankKeyDraft = ModelSettingsDraft(
            qwenApiKey = "   ",
            deepseekApiKey = "",
            asrProvider = "qwen",
            qwenAsrModel = "qwen-audio-3.1-asr-flash-message",
            llmProvider = "deepseek",
            deepseekLlmModel = "deepseek-v4-pro",
            enableThinking = true,
            qwenWorkspaceId = " ws-9 ",
        )
        val blankCmd = blankKeyDraft.toConfigureProviderCommand()
        assertNull(blankCmd.apiKey)
        assertNull(blankCmd.deepseekApiKey)
        assertEquals("qwen", blankCmd.asrProvider)
        assertEquals("qwen-audio-3.1-asr-flash-message", blankCmd.asrModel)
        assertEquals("deepseek", blankCmd.llmProvider)
        assertEquals("deepseek-v4-pro", blankCmd.model)
        assertEquals(true, blankCmd.enableThinking)
        assertEquals("ws-9", blankCmd.qwenWorkspaceId)
        assertEquals(
            "wss://ws-9.cn-beijing.maas.aliyuncs.com/api-ws/v1/inference",
            blankCmd.asrEndpoint,
        )
        assertEquals("https://api.deepseek.com/chat/completions", blankCmd.chatEndpoint)

        val blankJson = HostJson.json.parseToJsonElement(blankCmd.toJsonString()) as JsonObject
        assertFalse(blankJson.containsKey("apiKey"))
        assertFalse(blankJson.containsKey("deepseekApiKey"))
        assertEquals(true, blankJson["enableThinking"]?.jsonPrimitive?.boolean)

        val deepseekCmd = blankKeyDraft.copy(
            qwenApiKey = "  sk-qwen-123  ",
            deepseekApiKey = "  sk-ds-456  ",
            asrProvider = "deepseek",
        ).toConfigureProviderCommand()
        assertEquals("sk-qwen-123", deepseekCmd.apiKey)
        assertEquals("sk-ds-456", deepseekCmd.deepseekApiKey)
        assertEquals("deepseek", deepseekCmd.asrProvider)
        assertEquals("", deepseekCmd.asrModel)
        assertEquals("https://api.deepseek.com/v1/tools/asr", deepseekCmd.asrEndpoint)
    }
}
