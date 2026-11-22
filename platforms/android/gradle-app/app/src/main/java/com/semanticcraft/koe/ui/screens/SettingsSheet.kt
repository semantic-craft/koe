package com.semanticcraft.koe.ui.screens

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.relocation.BringIntoViewRequester
import androidx.compose.foundation.relocation.bringIntoViewRequester
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.mapSaver
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.launch
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.semanticcraft.koe.BuildConfig
import com.semanticcraft.koe.core.HostCommand
import com.semanticcraft.koe.core.HostSessionStore
import com.semanticcraft.koe.core.ModelSettingsDraft
import com.semanticcraft.koe.core.ProviderSnapshot
import com.semanticcraft.koe.ui.components.KoeBadge
import com.semanticcraft.koe.ui.components.KoeCard
import com.semanticcraft.koe.ui.components.KoeFilterChip
import com.semanticcraft.koe.ui.components.KoeInfoTip
import com.semanticcraft.koe.ui.components.KoeModalSheet
import com.semanticcraft.koe.ui.components.KoePrimaryButton
import com.semanticcraft.koe.ui.theme.KoeFontSizes
import com.semanticcraft.koe.ui.theme.KoeTheme

// Only non-secret fields belong in Android saved instance state.
private val settingsDraftSaver = mapSaver(
    save = { draft: ModelSettingsDraft ->
        mapOf(
            "qwenWorkspaceId" to draft.qwenWorkspaceId,
            "customChatEndpoint" to draft.customChatEndpoint,
            "customAsrEndpoint" to draft.customAsrEndpoint,
            "asrProvider" to draft.asrProvider,
            "qwenAsrModel" to draft.qwenAsrModel,
            "llmProvider" to draft.llmProvider,
            "deepseekLlmModel" to draft.deepseekLlmModel,
            "customLlmModel" to draft.customLlmModel,
            "enableThinking" to draft.enableThinking,
        )
    },
    restore = { saved ->
        ModelSettingsDraft(
            qwenWorkspaceId = saved.getValue("qwenWorkspaceId") as String,
            customChatEndpoint = saved.getValue("customChatEndpoint") as String,
            customAsrEndpoint = saved.getValue("customAsrEndpoint") as String,
            asrProvider = saved.getValue("asrProvider") as String,
            qwenAsrModel = saved.getValue("qwenAsrModel") as String,
            llmProvider = saved.getValue("llmProvider") as String,
            deepseekLlmModel = saved.getValue("deepseekLlmModel") as String,
            customLlmModel = saved.getValue("customLlmModel") as String,
            enableThinking = saved.getValue("enableThinking") as Boolean,
        )
    },
)

private data class ProviderModelSyncKey(
    val asrProvider: String,
    val asrModel: String,
    val llmProvider: String,
    val model: String,
    val enableThinking: Boolean,
    val qwenWorkspaceId: String,
    val asrEndpoint: String,
    val chatEndpoint: String,
)

private fun ProviderSnapshot.modelSyncKey(): ProviderModelSyncKey = ProviderModelSyncKey(
    asrProvider = asrProvider,
    asrModel = asrModel,
    llmProvider = llmProvider,
    model = model,
    enableThinking = enableThinking,
    qwenWorkspaceId = qwenWorkspaceId,
    asrEndpoint = asrEndpoint,
    chatEndpoint = chatEndpoint,
)

@OptIn(ExperimentalLayoutApi::class)
@Composable
fun SettingsSheet(
    store: HostSessionStore,
    onDismiss: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val platform by store.platform.collectAsStateWithLifecycle()
    val settings by store.settings.collectAsStateWithLifecycle()
    val navigation by store.navigation.collectAsStateWithLifecycle()
    val provider = settings.provider
    val speech = settings.speech
    val colors = KoeTheme.colors
    val scope = rememberCoroutineScope()

    var draft by rememberSaveable(stateSaver = settingsDraftSaver) { mutableStateOf(ModelSettingsDraft.from(provider)) }
    val modelSyncKey = provider.modelSyncKey()
    var lastSyncedKey by remember { mutableStateOf(modelSyncKey) }
    var showSavedNotice by remember { mutableStateOf(false) }
    var saving by remember { mutableStateOf(false) }

    LaunchedEffect(modelSyncKey) {
        if (modelSyncKey != lastSyncedKey) {
            draft = draft.syncWith(provider)
            lastSyncedKey = modelSyncKey
        }
    }

    DisposableEffect(Unit) {
        onDispose {
            draft = draft.clearingApiKeyInputs()
        }
    }

    fun updateDraft(next: ModelSettingsDraft) {
        draft = next
        showSavedNotice = false
    }

    fun saveSettings() {
        if (saving) return
        val submittedQwenKey = draft.qwenApiKey
        val submittedDeepseekKey = draft.deepseekApiKey
        val command = draft.toConfigureProviderCommand()
        saving = true
        scope.launch(start = CoroutineStart.UNDISPATCHED) {
            try {
                if (store.sendReturningErrorAsync(command) == null) {
                    draft = draft.copy(
                        qwenApiKey = if (draft.qwenApiKey == submittedQwenKey) "" else draft.qwenApiKey,
                        deepseekApiKey = if (draft.deepseekApiKey == submittedDeepseekKey) "" else draft.deepseekApiKey,
                    )
                    showSavedNotice = true
                } else {
                    showSavedNotice = false
                }
            } finally {
                saving = false
            }
        }
    }

    val matchedPreset = draft.matchedPreset(speech.engine)

    KoeModalSheet(onDismissRequest = onDismiss, modifier = modifier) {
        Column(verticalArrangement = Arrangement.spacedBy(14.dp)) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    text = "设置",
                    color = colors.textPrimary,
                    fontSize = KoeFontSizes.md,
                    fontWeight = FontWeight.SemiBold,
                )
                Spacer(modifier = Modifier.weight(1f))
                KoePrimaryButton(
                    title = "完成",
                    isPrimary = false,
                    onClick = onDismiss,
                    modifier = Modifier.testTag("settings-sheet-close"),
                )
            }

            navigation.effectiveError?.let { errorMessage ->
                val errorBanner = remember { BringIntoViewRequester() }
                LaunchedEffect(errorMessage) { errorBanner.bringIntoView() }
                Text(
                    modifier = Modifier.bringIntoViewRequester(errorBanner),
                    text = errorMessage,
                    color = colors.danger,
                    fontSize = KoeFontSizes.xs,
                    fontWeight = FontWeight.Medium,
                )
            }

            KoeCard {
                Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Text(
                            text = "宿主设备配置",
                            color = colors.textPrimary,
                            fontSize = KoeFontSizes.md,
                            fontWeight = FontWeight.SemiBold,
                        )
                        Spacer(modifier = Modifier.weight(1f))
                        KoeBadge(text = platform.hostDisplayName, tint = colors.accent)
                    }

                    SettingsKeyValueRow("平台标识", platform.id)
                    SettingsKeyValueRow("分发渠道", BuildConfig.KOE_DISTRIBUTION)
                    SettingsKeyValueRow("识别引擎", when (speech.engine) {
                        "apple_speech" -> platform.nativeSpeechLabel
                        "cloud" -> "云端识别"
                        "downloaded" -> "下载的本机模型"
                        else -> "未知引擎"
                    })

                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(4.dp),
                    ) {
                        Text(
                            text = "系统音频录制",
                            color = colors.textSecondary,
                            fontSize = KoeFontSizes.xs,
                        )
                        KoeInfoTip(
                            title = "Android 音频限制",
                            message = "Android 端不支持系统音频内录，请使用 Android 麦克风或 Soundcore Work 录音豆采集声音。",
                        )
                        Spacer(modifier = Modifier.weight(1f))
                        Text(
                            text = if (platform.supportsSystemAudio) "可用" else "Android 端不可用",
                            color = colors.textMuted,
                            fontSize = KoeFontSizes.xs,
                            fontWeight = FontWeight.Medium,
                        )
                    }

                    SettingsKeyValueRow(
                        "应用更新通道",
                        if (platform.supportsSelfUpdate) "GitHub 发行版更新" else "Play 商店分发",
                    )
                }
            }

            KoeCard {
                Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Text(
                            text = "快捷组合",
                            color = colors.textPrimary,
                            fontSize = KoeFontSizes.md,
                            fontWeight = FontWeight.SemiBold,
                        )
                        Spacer(modifier = Modifier.weight(1f))
                        KoeBadge(
                            text = if (provider.configured) "已配置" else "未配置",
                            tint = if (provider.configured) colors.success else colors.textMuted,
                        )
                    }
                    FlowRow(
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                        verticalArrangement = Arrangement.spacedBy(8.dp),
                    ) {
                        KoeFilterChip(
                            label = "混合主力",
                            selected = matchedPreset == "hybrid",
                            onClick = {
                                if (speech.engine != "cloud") {
                                    store.send(HostCommand.ConfigureSpeech("cloud"))
                                }
                                updateDraft(draft.applyPreset("hybrid"))
                            },
                            modifier = Modifier.testTag("settings-preset-hybrid"),
                        )
                        KoeFilterChip(
                            label = "纯 DeepSeek",
                            selected = matchedPreset == "deepseek-full",
                            onClick = {
                                if (speech.engine != "cloud") {
                                    store.send(HostCommand.ConfigureSpeech("cloud"))
                                }
                                updateDraft(draft.applyPreset("deepseek-full"))
                            },
                            modifier = Modifier.testTag("settings-preset-deepseek-full"),
                        )
                    }
                }
            }

            SettingsExtrasCards(store, settings.appUpdate, platform.supportsSelfUpdate)

            SettingsCredentialsCard(
                provider = provider,
                draft = draft,
                onDraftChange = ::updateDraft,
                onClearCredential = { slot -> store.send(HostCommand.ClearProviderCredential(slot)) },
                onRetryCredentials = { store.send(HostCommand.RetryProviderCredentials(authorize = true)) },
                onSave = ::saveSettings,
            )

            SettingsAsrCard(
                platform = platform,
                speech = speech,
                provider = provider,
                draft = draft,
                onConfigureSpeech = { engine -> store.send(HostCommand.ConfigureSpeech(engine)) },
                onDraftChange = ::updateDraft,
                onSetMeetingAudioPolicy = { policy -> store.send(HostCommand.SetMeetingAudioPolicy(policy)) },
            )

            SettingsLlmCard(
                provider = provider,
                draft = draft,
                onDraftChange = ::updateDraft,
                onSave = ::saveSettings,
            )

            KoeCard {
                Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    if (showSavedNotice) {
                        Text(
                            text = "已保存模型配置",
                            color = colors.success,
                            fontSize = KoeFontSizes.xs,
                            fontWeight = FontWeight.SemiBold,
                        )
                    }
                    KoePrimaryButton(
                        title = "保存模型配置",
                        isPrimary = true,
                        enabled = !saving,
                        onClick = ::saveSettings,
                        modifier = Modifier
                            .fillMaxWidth()
                            .testTag("settings-save-button"),
                    )
                }
            }
        }
    }
}

@Composable
internal fun SettingsKeyValueRow(label: String, value: String) {
    val colors = KoeTheme.colors
    Row(
        modifier = Modifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Text(
            text = label,
            color = colors.textSecondary,
            fontSize = KoeFontSizes.xs,
        )
        Spacer(modifier = Modifier.weight(1f))
        Text(
            text = value,
            color = colors.textPrimary,
            fontSize = KoeFontSizes.xs,
            fontWeight = FontWeight.Medium,
            textAlign = TextAlign.End,
        )
    }
}
