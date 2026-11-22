package com.semanticcraft.koe.ui.screens

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.CheckCircle
import androidx.compose.material.icons.outlined.RadioButtonUnchecked
import androidx.compose.material.icons.outlined.WarningAmber
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.semanticcraft.koe.core.HostPlatformSnapshot
import com.semanticcraft.koe.core.LlmModelOption
import com.semanticcraft.koe.core.ModelSettingsCatalog
import com.semanticcraft.koe.core.ModelSettingsDraft
import com.semanticcraft.koe.core.ProviderSnapshot
import com.semanticcraft.koe.core.QwenAsrModelOption
import com.semanticcraft.koe.core.SpeechSnapshot
import com.semanticcraft.koe.ui.components.KoeBadge
import com.semanticcraft.koe.ui.components.KoeCard
import com.semanticcraft.koe.ui.components.KoeFilterChip
import com.semanticcraft.koe.ui.components.KoeInfoTip
import com.semanticcraft.koe.ui.theme.KoeFontSizes
import com.semanticcraft.koe.ui.theme.KoeShapes
import com.semanticcraft.koe.ui.theme.KoeTheme

@OptIn(ExperimentalLayoutApi::class)
@Composable
fun SettingsAsrCard(
    platform: HostPlatformSnapshot,
    speech: SpeechSnapshot,
    provider: ProviderSnapshot,
    draft: ModelSettingsDraft,
    onConfigureSpeech: (String) -> Unit,
    onDraftChange: (ModelSettingsDraft) -> Unit,
    onSetMeetingAudioPolicy: (String) -> Unit,
    modifier: Modifier = Modifier,
) {
    val colors = KoeTheme.colors
    val isCloud = speech.engine == "cloud"
    val isQwen = draft.asrProvider == "qwen"
    val qwenOption = ModelSettingsCatalog.qwenAsrOption(draft.qwenAsrModel)

    KoeCard(modifier = modifier) {
        Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Text("语音识别（ASR）", color = colors.textPrimary, fontSize = KoeFontSizes.md, fontWeight = FontWeight.SemiBold)

            FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                KoeFilterChip(
                    label = "云端识别",
                    selected = isCloud,
                    onClick = { onConfigureSpeech("cloud") },
                    modifier = Modifier.testTag("settings-speech-cloud"),
                )
                if (platform.supportsNativeSpeech || speech.engine == "apple_speech") {
                    KoeFilterChip(
                        label = platform.nativeSpeechLabel,
                        selected = speech.engine == "apple_speech",
                        onClick = { onConfigureSpeech("apple_speech") },
                        modifier = Modifier.testTag("settings-speech-native"),
                    )
                }
            }

            if (isCloud) {
                FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    KoeFilterChip(
                        label = "Qwen 阿里云百炼",
                        selected = isQwen,
                        onClick = { onDraftChange(draft.copy(asrProvider = "qwen", customAsrEndpoint = "")) },
                        modifier = Modifier.testTag("settings-asr-provider-qwen"),
                    )
                    KoeFilterChip(
                        label = "DeepSeek 官方语音",
                        selected = !isQwen,
                        onClick = { onDraftChange(draft.copy(asrProvider = "deepseek", customAsrEndpoint = "")) },
                        modifier = Modifier.testTag("settings-asr-provider-deepseek"),
                    )
                }

                if (isQwen) {
                    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                        ModelSettingsCatalog.qwenAsrModels.forEach { option ->
                            QwenAsrOptionRow(
                                option = option,
                                selected = draft.qwenAsrModel == option.id,
                                onClick = {
                                    onDraftChange(
                                        draft.copy(asrProvider = "qwen", qwenAsrModel = option.id, customAsrEndpoint = ""),
                                    )
                                },
                            )
                        }
                    }
                    qwenOption.nonRealtimeWarning?.let { SettingsWarningBanner(text = it) }
                } else {
                    Surface(
                        shape = KoeShapes.control,
                        color = colors.bgSubtle,
                        border = BorderStroke(1.dp, colors.border),
                        modifier = Modifier.fillMaxWidth(),
                    ) {
                        Column(modifier = Modifier.padding(10.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                                Text("DeepSeek 独立语音接口", color = colors.textPrimary, fontSize = KoeFontSizes.xs, fontWeight = FontWeight.SemiBold)
                                KoeBadge(text = "非流式 <=120s", tint = colors.warning)
                            }
                            Text(
                                text = "自动识别中/粤/英/日/韩等 21 语种，超 120 秒录音会在静音点自动切段顺序拼接，录音结束后转写，不输出边录边看实时字幕。",
                                color = colors.textSecondary,
                                fontSize = KoeFontSizes.xs,
                            )
                        }
                    }
                }

                EndpointPreviewBox(
                    label = if (isQwen) qwenOption.endpointLabel else "当前 ASR 接口（HTTP 整段上传 <=120s）",
                    endpoint = draft.effectiveAsrEndpoint(),
                )
            } else {
                Surface(shape = KoeShapes.control, color = colors.bgSubtle, modifier = Modifier.fillMaxWidth()) {
                    Column(modifier = Modifier.padding(10.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                        Text("本机引擎状态：${speech.appleStateLabel}", color = colors.textSecondary, fontSize = KoeFontSizes.xs, fontWeight = FontWeight.Medium)
                        Text(
                            text = speech.appleMessage?.takeIf { it.isNotBlank() } ?: "当前使用本机语音识别。",
                            color = colors.textMuted,
                            fontSize = KoeFontSizes.xs,
                        )
                    }
                }
            }

            HorizontalDivider(color = colors.border)

            SettingsToggleRow(
                title = "允许将录音音频上传到云端",
                subtitle = "关闭后音频仅保留在本机，文本整理服务仍可处理转写文字。",
                tipTitle = "录音音频上传授权",
                tipMessage = "这是独立的音频上传授权。切换识别引擎不会改变此授权。关闭后音频保存在本机，文字整理服务仍可接收转写文字。",
                checked = provider.meetingAudioPolicy == "cloud_allowed",
                onCheckedChange = { checked ->
                    onSetMeetingAudioPolicy(if (checked) "cloud_allowed" else "local_only")
                },
                switchTestTag = "settings-meeting-audio-switch",
            )

            val policyNote = provider.meetingAudioPolicyError?.takeIf { it.isNotBlank() }
                ?: provider.meetingAudioStatus?.takeIf { it.isNotBlank() }
            if (policyNote != null) {
                Text(text = policyNote, color = colors.warning, fontSize = KoeFontSizes.xs)
            }
        }
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
fun SettingsLlmCard(
    provider: ProviderSnapshot,
    draft: ModelSettingsDraft,
    onDraftChange: (ModelSettingsDraft) -> Unit,
    onSave: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val colors = KoeTheme.colors
    val isCustom = draft.llmProvider == "custom"

    KoeCard(modifier = modifier) {
        Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                Text("文本整理与问答（LLM）", color = colors.textPrimary, fontSize = KoeFontSizes.md, fontWeight = FontWeight.SemiBold)
                Spacer(modifier = Modifier.weight(1f))
                KoeBadge(
                    text = if (provider.configured) "已就绪" else "未配置",
                    tint = if (provider.configured) colors.success else colors.textMuted,
                )
            }

            FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                KoeFilterChip(
                    label = "DeepSeek（官方）",
                    selected = !isCustom,
                    onClick = { onDraftChange(draft.selectLlmProvider("deepseek")) },
                    modifier = Modifier.testTag("settings-llm-provider-deepseek"),
                )
                KoeFilterChip(
                    label = "自定义兼容",
                    selected = isCustom,
                    onClick = { onDraftChange(draft.selectLlmProvider("custom")) },
                    modifier = Modifier.testTag("settings-llm-provider-custom"),
                )
            }

            if (!isCustom) {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    ModelSettingsCatalog.deepseekLlmModels.forEach { option ->
                        DeepSeekLlmOptionCard(
                            option = option,
                            selected = draft.deepseekLlmModel == option.id,
                            onClick = { onDraftChange(draft.copy(deepseekLlmModel = option.id)) },
                        )
                    }
                }
            } else {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                        Text("自定义模型名称（Model ID）", color = colors.textSecondary, fontSize = KoeFontSizes.xs)
                        SettingsTextField(
                            value = draft.customLlmModel,
                            onValueChange = { onDraftChange(draft.copy(customLlmModel = it)) },
                            placeholder = "例如：deepseek-flash 或本机模型名",
                            onDone = onSave,
                            modifier = Modifier.fillMaxWidth().testTag("settings-custom-llm-model"),
                        )
                    }
                    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                        Text("对话接口地址（支持 http://127.0.0.1）", color = colors.textSecondary, fontSize = KoeFontSizes.xs)
                        SettingsTextField(
                            value = draft.customChatEndpoint,
                            onValueChange = { onDraftChange(draft.copy(customChatEndpoint = it)) },
                            placeholder = "https://your-host/v1/chat/completions",
                            keyboardType = KeyboardType.Uri,
                            onDone = onSave,
                            modifier = Modifier.fillMaxWidth().testTag("settings-custom-llm-endpoint"),
                        )
                    }
                }
            }

            EndpointPreviewBox(
                label = "当前 LLM 接口（OpenAI 兼容）",
                endpoint = draft.effectiveChatEndpoint().ifEmpty { "请填写自定义兼容服务对话接口地址" },
            )

            SettingsToggleRow(
                title = "纪要与问答启用深度思考",
                subtitle = "关闭可缩短实时纪要生成耗时；开启适合复杂会议分析与长文推理。",
                tipTitle = "深度思考模式",
                tipMessage = "DeepSeek V4.1 / V4 支持深度思考切换。关闭可显著缩短实时纪要首字耗时与生成延迟。",
                checked = draft.enableThinking,
                onCheckedChange = { checked -> onDraftChange(draft.copy(enableThinking = checked)) },
                switchTestTag = "settings-thinking-switch",
            )
        }
    }
}

@Composable
private fun SettingsToggleRow(
    title: String,
    subtitle: String,
    tipTitle: String,
    tipMessage: String,
    checked: Boolean,
    onCheckedChange: (Boolean) -> Unit,
    switchTestTag: String,
) {
    val colors = KoeTheme.colors
    Row(
        modifier = Modifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                Text(title, color = colors.textPrimary, fontSize = KoeFontSizes.sm, fontWeight = FontWeight.Medium)
                KoeInfoTip(title = tipTitle, message = tipMessage)
            }
            Text(subtitle, color = colors.textMuted, fontSize = KoeFontSizes.xs)
        }
        Switch(
            checked = checked,
            onCheckedChange = onCheckedChange,
            modifier = Modifier.testTag(switchTestTag),
            colors = SwitchDefaults.colors(
                checkedThumbColor = colors.onAccent,
                checkedTrackColor = colors.accent,
                uncheckedThumbColor = colors.textMuted,
                uncheckedTrackColor = colors.bgSubtle,
            ),
        )
    }
}

@Composable
private fun QwenAsrOptionRow(
    option: QwenAsrModelOption,
    selected: Boolean,
    onClick: () -> Unit,
) {
    val colors = KoeTheme.colors
    Surface(
        onClick = onClick,
        shape = KoeShapes.control,
        color = if (selected) colors.accentSoft else colors.surface0,
        border = BorderStroke(1.dp, if (selected) colors.accent else colors.border),
        modifier = Modifier.fillMaxWidth().testTag("settings-asr-option-${option.id}"),
    ) {
        Row(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 10.dp, vertical = 9.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Icon(
                imageVector = if (selected) Icons.Outlined.CheckCircle else Icons.Outlined.RadioButtonUnchecked,
                contentDescription = null,
                tint = if (selected) colors.accent else colors.textMuted,
                modifier = Modifier.size(18.dp),
            )
            Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Text(
                    text = option.id,
                    color = colors.textPrimary,
                    fontSize = KoeFontSizes.xs,
                    fontWeight = FontWeight.SemiBold,
                    fontFamily = FontFamily.Monospace,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                Text(option.note, color = colors.textSecondary, fontSize = KoeFontSizes.xs)
            }
            option.badge?.let { KoeBadge(text = it, tint = colors.success) }
        }
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun DeepSeekLlmOptionCard(
    option: LlmModelOption,
    selected: Boolean,
    onClick: () -> Unit,
) {
    val colors = KoeTheme.colors
    Surface(
        onClick = onClick,
        shape = KoeShapes.control,
        color = if (selected) colors.accentSoft else colors.bgSubtle,
        border = BorderStroke(1.dp, if (selected) colors.accent else colors.border),
        modifier = Modifier.fillMaxWidth().testTag("settings-llm-option-${option.id}"),
    ) {
        Column(modifier = Modifier.fillMaxWidth().padding(12.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Text(
                    text = option.id,
                    color = colors.textPrimary,
                    fontSize = KoeFontSizes.xs,
                    fontWeight = FontWeight.SemiBold,
                    fontFamily = FontFamily.Monospace,
                    modifier = Modifier.weight(1f),
                )
                Icon(
                    imageVector = if (selected) Icons.Outlined.CheckCircle else Icons.Outlined.RadioButtonUnchecked,
                    contentDescription = null,
                    tint = if (selected) colors.accent else colors.textMuted,
                    modifier = Modifier.size(18.dp),
                )
            }
            FlowRow(horizontalArrangement = Arrangement.spacedBy(4.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                KoeBadge(
                    text = option.primaryBadge,
                    tint = if (option.primaryBadgeRecommended) colors.success else colors.accent,
                )
                option.metaBadges.forEach { KoeBadge(text = it, tint = colors.textMuted) }
            }
            Text(option.description, color = colors.textSecondary, fontSize = KoeFontSizes.xs)
        }
    }
}

@Composable
private fun EndpointPreviewBox(label: String, endpoint: String) {
    val colors = KoeTheme.colors
    Surface(shape = KoeShapes.control, color = colors.bgSubtle, modifier = Modifier.fillMaxWidth()) {
        Column(modifier = Modifier.fillMaxWidth().padding(horizontal = 10.dp, vertical = 8.dp), verticalArrangement = Arrangement.spacedBy(3.dp)) {
            Text(label, color = colors.textMuted, fontSize = KoeFontSizes.xs)
            Text(
                text = endpoint,
                color = colors.textSecondary,
                fontSize = KoeFontSizes.xs,
                fontFamily = FontFamily.Monospace,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
            )
        }
    }
}

@Composable
private fun SettingsWarningBanner(text: String) {
    val colors = KoeTheme.colors
    Surface(
        shape = KoeShapes.control,
        color = colors.warning.copy(alpha = 0.08f),
        border = BorderStroke(1.dp, colors.warning.copy(alpha = 0.35f)),
        modifier = Modifier.fillMaxWidth(),
    ) {
        Row(modifier = Modifier.fillMaxWidth().padding(10.dp), verticalAlignment = Alignment.Top, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            Icon(Icons.Outlined.WarningAmber, contentDescription = null, tint = colors.warning, modifier = Modifier.size(16.dp))
            Text(text, color = colors.warning, fontSize = KoeFontSizes.xs)
        }
    }
}
