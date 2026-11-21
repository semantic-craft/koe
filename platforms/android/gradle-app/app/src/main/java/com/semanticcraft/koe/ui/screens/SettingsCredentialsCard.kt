package com.semanticcraft.koe.ui.screens

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.ExpandLess
import androidx.compose.material.icons.outlined.ExpandMore
import androidx.compose.material.icons.outlined.WarningAmber
import androidx.compose.material3.Icon
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.LocalSaveableStateRegistry
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.unit.dp
import com.semanticcraft.koe.core.ModelSettingsDraft
import com.semanticcraft.koe.core.ProviderSnapshot
import com.semanticcraft.koe.ui.components.KoeBadge
import com.semanticcraft.koe.ui.components.KoeCard
import com.semanticcraft.koe.ui.components.KoePrimaryButton
import com.semanticcraft.koe.ui.theme.KoeFontSizes
import com.semanticcraft.koe.ui.theme.KoeShapes
import com.semanticcraft.koe.ui.theme.KoeTheme

@Composable
fun SettingsCredentialsCard(
    provider: ProviderSnapshot,
    draft: ModelSettingsDraft,
    onDraftChange: (ModelSettingsDraft) -> Unit,
    onClearCredential: (String) -> Unit,
    onRetryCredentials: () -> Unit,
    onSave: () -> Unit,
) {
    val colors = KoeTheme.colors
    var showAdvancedEndpoints by rememberSaveable { mutableStateOf(false) }

    KoeCard {
        Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                Text(
                    text = "服务商凭证",
                    color = colors.textPrimary,
                    fontSize = KoeFontSizes.md,
                    fontWeight = FontWeight.SemiBold,
                )
                Spacer(modifier = Modifier.weight(1f))
                KoeBadge(
                    text = if (provider.isolated) "隔离会话仅内存有效" else "Android Keystore 存储",
                    tint = colors.textMuted,
                )
            }

            credentialWarningText(provider)?.let { warning ->
                Surface(
                    shape = KoeShapes.control,
                    color = colors.warning.copy(alpha = 0.08f),
                    border = BorderStroke(1.dp, colors.warning.copy(alpha = 0.35f)),
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    Column(
                        modifier = Modifier.padding(10.dp),
                        verticalArrangement = Arrangement.spacedBy(8.dp),
                    ) {
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(6.dp),
                        ) {
                            Icon(
                                imageVector = Icons.Outlined.WarningAmber,
                                contentDescription = null,
                                tint = colors.warning,
                                modifier = Modifier.size(16.dp),
                            )
                            Text(
                                text = warning,
                                color = colors.warning,
                                fontSize = KoeFontSizes.xs,
                                modifier = Modifier.weight(1f),
                            )
                        }
                        KoePrimaryButton(
                            title = "重试读取安全配置",
                            isPrimary = false,
                            onClick = onRetryCredentials,
                            modifier = Modifier.testTag("settings-retry-credentials"),
                        )
                    }
                }
            }

            CredentialSectionBox(
                title = "Qwen（阿里云百炼）",
                configured = provider.qwenConfigured,
                active = draft.asrProvider == "qwen",
                apiKeyValue = draft.qwenApiKey,
                apiKeyPlaceholder = if (provider.qwenConfigured) "已安全保存，留空保持不变" else "粘贴阿里云百炼 API Key",
                apiKeyTestTag = "settings-qwen-key-input",
                clearTestTag = "settings-qwen-clear",
                onApiKeyChange = { onDraftChange(draft.copy(qwenApiKey = it)) },
                onClear = {
                    onDraftChange(draft.copy(qwenApiKey = ""))
                    onClearCredential("qwen")
                },
                onSave = onSave,
            ) {
                Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    Row(modifier = Modifier.fillMaxWidth()) {
                        Text(
                            text = "业务空间 ID（可选）",
                            color = colors.textSecondary,
                            fontSize = KoeFontSizes.xs,
                        )
                        Spacer(modifier = Modifier.weight(1f))
                        Text(
                            text = "华北 2 北京",
                            color = colors.textMuted,
                            fontSize = KoeFontSizes.xs,
                        )
                    }
                    SettingsTextField(
                        value = draft.qwenWorkspaceId,
                        onValueChange = { onDraftChange(draft.copy(qwenWorkspaceId = it)) },
                        placeholder = "留空使用 dashscope.aliyuncs.com",
                        onDone = onSave,
                        modifier = Modifier
                            .fillMaxWidth()
                            .testTag("settings-qwen-workspace-input"),
                    )
                }
            }

            CredentialSectionBox(
                title = "DeepSeek（官方 API）",
                configured = provider.deepseekConfigured,
                active = draft.asrProvider == "deepseek" || draft.llmProvider == "deepseek",
                apiKeyValue = draft.deepseekApiKey,
                apiKeyPlaceholder = if (provider.deepseekConfigured) "已安全保存，留空保持不变" else "粘贴 DeepSeek 官方 API Key",
                apiKeyTestTag = "settings-deepseek-key-input",
                clearTestTag = "settings-deepseek-clear",
                onApiKeyChange = { onDraftChange(draft.copy(deepseekApiKey = it)) },
                onClear = {
                    onDraftChange(draft.copy(deepseekApiKey = ""))
                    onClearCredential("deepseek")
                },
                onSave = onSave,
            )

            Surface(
                onClick = { showAdvancedEndpoints = !showAdvancedEndpoints },
                shape = KoeShapes.control,
                color = colors.bgSubtle,
                border = BorderStroke(1.dp, colors.border),
                modifier = Modifier
                    .fillMaxWidth()
                    .testTag("settings-advanced-toggle"),
            ) {
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = 12.dp, vertical = 10.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text(
                        text = "高级：自定义兼容或本机地址",
                        color = colors.textSecondary,
                        fontSize = KoeFontSizes.xs,
                        fontWeight = FontWeight.Medium,
                        modifier = Modifier.weight(1f),
                    )
                    Icon(
                        imageVector = if (showAdvancedEndpoints) Icons.Outlined.ExpandLess else Icons.Outlined.ExpandMore,
                        contentDescription = null,
                        tint = colors.textMuted,
                        modifier = Modifier.size(18.dp),
                    )
                }
            }

            if (showAdvancedEndpoints) {
                Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                        Text(
                            text = "对话接口地址（支持 http://127.0.0.1）",
                            color = colors.textSecondary,
                            fontSize = KoeFontSizes.xs,
                        )
                        SettingsTextField(
                            value = draft.customChatEndpoint,
                            onValueChange = { onDraftChange(draft.copy(customChatEndpoint = it)) },
                            placeholder = "https://your-host/v1/chat/completions",
                            keyboardType = KeyboardType.Uri,
                            onDone = onSave,
                            modifier = Modifier
                                .fillMaxWidth()
                                .testTag("settings-custom-chat-endpoint"),
                        )
                    }
                    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                        Text(
                            text = "语音识别 WebSocket / HTTP 地址",
                            color = colors.textSecondary,
                            fontSize = KoeFontSizes.xs,
                        )
                        SettingsTextField(
                            value = draft.customAsrEndpoint,
                            onValueChange = { onDraftChange(draft.copy(customAsrEndpoint = it)) },
                            placeholder = "wss://your-host/api-ws/v1/inference",
                            keyboardType = KeyboardType.Uri,
                            onDone = onSave,
                            modifier = Modifier
                                .fillMaxWidth()
                                .testTag("settings-custom-asr-endpoint"),
                        )
                    }
                    Text(
                        text = "本机 http://127.0.0.1 服务免填密钥；远程自定义 HTTPS 服务复用上方已保存的 API Key。",
                        color = colors.textMuted,
                        fontSize = KoeFontSizes.xs,
                    )
                }
            }
        }
    }
}

@Composable
private fun CredentialSectionBox(
    title: String,
    configured: Boolean,
    active: Boolean,
    apiKeyValue: String,
    apiKeyPlaceholder: String,
    apiKeyTestTag: String,
    clearTestTag: String,
    onApiKeyChange: (String) -> Unit,
    onClear: () -> Unit,
    onSave: () -> Unit,
    extraContent: (@Composable () -> Unit)? = null,
) {
    val colors = KoeTheme.colors
    Surface(
        shape = KoeShapes.control,
        color = if (active) colors.surface0 else colors.bgSubtle,
        border = BorderStroke(1.dp, if (active) colors.accent.copy(alpha = 0.45f) else colors.border),
        modifier = Modifier.fillMaxWidth(),
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(12.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    text = title,
                    color = colors.textPrimary,
                    fontSize = KoeFontSizes.sm,
                    fontWeight = FontWeight.SemiBold,
                )
                Spacer(modifier = Modifier.weight(1f))
                KoeBadge(
                    text = if (configured) "已配置" else "未配置",
                    tint = if (configured) colors.success else colors.textMuted,
                )
            }

            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                // Also exclude the text field's internal editing state from the Bundle.
                CompositionLocalProvider(LocalSaveableStateRegistry provides null) {
                    SettingsTextField(
                        value = apiKeyValue,
                        onValueChange = onApiKeyChange,
                        placeholder = apiKeyPlaceholder,
                        isSecret = true,
                        keyboardType = KeyboardType.Password,
                        onDone = onSave,
                        modifier = Modifier
                            .weight(1f)
                            .testTag(apiKeyTestTag),
                    )
                }
                KoePrimaryButton(
                    title = "清除",
                    isPrimary = false,
                    enabled = configured || apiKeyValue.isNotEmpty(),
                    onClick = onClear,
                    modifier = Modifier.testTag(clearTestTag),
                )
            }

            extraContent?.invoke()
        }
    }
}

@Composable
internal fun SettingsTextField(
    value: String,
    onValueChange: (String) -> Unit,
    placeholder: String,
    modifier: Modifier = Modifier,
    isSecret: Boolean = false,
    keyboardType: KeyboardType = KeyboardType.Text,
    onDone: () -> Unit = {},
) {
    val colors = KoeTheme.colors
    OutlinedTextField(
        value = value,
        onValueChange = onValueChange,
        placeholder = {
            Text(
                text = placeholder,
                fontSize = KoeFontSizes.xs,
                color = colors.textMuted,
            )
        },
        singleLine = true,
        visualTransformation = if (isSecret) PasswordVisualTransformation() else VisualTransformation.None,
        textStyle = TextStyle(fontSize = KoeFontSizes.xs, fontFamily = FontFamily.Monospace),
        shape = KoeShapes.control,
        colors = OutlinedTextFieldDefaults.colors(
            focusedBorderColor = colors.accent,
            unfocusedBorderColor = colors.border,
            focusedContainerColor = colors.surface1,
            unfocusedContainerColor = colors.surface1,
            focusedTextColor = colors.textPrimary,
            unfocusedTextColor = colors.textPrimary,
        ),
        keyboardOptions = KeyboardOptions(
            capitalization = KeyboardCapitalization.None,
            autoCorrectEnabled = false,
            keyboardType = keyboardType,
            imeAction = ImeAction.Done,
        ),
        keyboardActions = KeyboardActions(onDone = { onDone() }),
        modifier = modifier,
    )
}

private fun credentialWarningText(provider: ProviderSnapshot): String? {
    for (state in listOf(provider.credentialState, provider.deepseekCredentialState)) {
        when (state) {
            "reopen_required" -> return "工作区保存结果尚未确认，请退出并重新打开 Koe。"
            "missing_saved" -> return "已保存的密钥在当前安全存储中不存在，请重新输入或清除。"
            "unavailable" -> return "安全凭据暂不可读取，云端处理已停用。"
        }
    }
    return null
}
