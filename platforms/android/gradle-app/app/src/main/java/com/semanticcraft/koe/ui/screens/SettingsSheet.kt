package com.semanticcraft.koe.ui.screens

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.semanticcraft.koe.BuildConfig
import com.semanticcraft.koe.core.HostSessionStore
import com.semanticcraft.koe.ui.components.KoeBadge
import com.semanticcraft.koe.ui.components.KoeCard
import com.semanticcraft.koe.ui.components.KoeInfoTip
import com.semanticcraft.koe.ui.components.KoeModalSheet
import com.semanticcraft.koe.ui.components.KoePrimaryButton
import com.semanticcraft.koe.ui.theme.KoeFontSizes
import com.semanticcraft.koe.ui.theme.KoeTheme

@Composable
fun SettingsSheet(
    store: HostSessionStore,
    onDismiss: () -> Unit,
) {
    val platform by store.platform.collectAsStateWithLifecycle()
    val settings by store.settings.collectAsStateWithLifecycle()
    val provider = settings.provider
    val speech = settings.speech
    val colors = KoeTheme.colors

    KoeModalSheet(onDismissRequest = onDismiss) {
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
                    SettingsKeyValueRow("本机语音引擎", platform.nativeSpeechLabel)

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
                            text = "模型与转写服务",
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

                    SettingsKeyValueRow("语音识别提供方", "${provider.asrProvider}  |  ${provider.asrModel}")
                    SettingsKeyValueRow("摘要对话提供方", "${provider.llmProvider}  |  ${provider.model}")
                    SettingsKeyValueRow("Qwen 凭据状态", credentialStateLabel(provider.credentialState))
                    SettingsKeyValueRow("DeepSeek 凭据状态", credentialStateLabel(provider.deepseekCredentialState))
                    SettingsKeyValueRow(
                        "凭据存储模式",
                        if (provider.isolated) "调试隔离存储" else "Android Keystore",
                    )
                }
            }

            KoeCard {
                Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    Text(
                        text = "本机语音识别",
                        color = colors.textPrimary,
                        fontSize = KoeFontSizes.md,
                        fontWeight = FontWeight.SemiBold,
                    )
                    SettingsKeyValueRow("当前引擎", speech.engine)
                    SettingsKeyValueRow("本机状态", speech.appleState)
                    val message = speech.appleMessage
                    if (!message.isNullOrBlank()) {
                        Text(
                            text = message,
                            color = colors.textMuted,
                            fontSize = KoeFontSizes.xs,
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun SettingsKeyValueRow(label: String, value: String) {
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

private fun credentialStateLabel(raw: String): String =
    when (raw) {
        "ready" -> "已就绪"
        "reopen_required" -> "需要重新授权"
        "unavailable" -> "暂不可用"
        else -> "未设置"
    }
