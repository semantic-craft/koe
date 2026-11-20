package com.semanticcraft.koe.ui.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ArrowForward
import androidx.compose.material.icons.outlined.Bolt
import androidx.compose.material.icons.outlined.GraphicEq
import androidx.compose.material.icons.outlined.Schedule
import androidx.compose.material.icons.outlined.Summarize
import androidx.compose.material3.Icon
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.semanticcraft.koe.core.HostCommand
import com.semanticcraft.koe.core.HostSection
import com.semanticcraft.koe.core.HostSessionStore
import com.semanticcraft.koe.core.ModePickerCardSnapshot
import com.semanticcraft.koe.core.ModePickerSnapshot
import com.semanticcraft.koe.core.TodaySlice
import com.semanticcraft.koe.ui.components.KoeBadge
import com.semanticcraft.koe.ui.components.KoeCard
import com.semanticcraft.koe.ui.components.KoeInfoTip
import com.semanticcraft.koe.ui.components.KoePrimaryButton
import com.semanticcraft.koe.ui.theme.KoeFontSizes
import com.semanticcraft.koe.ui.theme.KoeShapes
import com.semanticcraft.koe.ui.theme.KoeTheme

@Composable
fun TodayScreen(
    store: HostSessionStore,
    onOpenWorkspace: (AndroidModeWorkspaceRoute) -> Unit,
    modifier: Modifier = Modifier,
) {
    val today by store.today.collectAsStateWithLifecycle()
    val navigation by store.navigation.collectAsStateWithLifecycle()
    val colors = KoeTheme.colors
    val focusManager = LocalFocusManager.current
    val keyboardController = LocalSoftwareKeyboardController.current
    var quickNoteDraft by rememberSaveable { mutableStateOf("") }

    val cards = today.picker?.cards?.takeIf { it.isNotEmpty() } ?: ModePickerSnapshot.defaultCards

    fun submitQuickNote() {
        val trimmed = quickNoteDraft.trim()
        if (trimmed.isEmpty()) return
        focusManager.clearFocus()
        keyboardController?.hide()
        val title = trimmed.take(24)
        store.send(HostCommand.CreateNote(title = title, text = trimmed, stayOnPage = true))
        if (store.navigation.value.effectiveError == null && navigation.effectiveError == null) {
            quickNoteDraft = ""
        }
    }

    LazyColumn(
        modifier = modifier
            .fillMaxSize()
            .background(colors.bgPanel),
        contentPadding = PaddingValues(16.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        item(key = "today-header") {
            TodayHeaderCard(today = today)
        }

        item(key = "quick-note-card") {
            KoeCard {
                Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(6.dp),
                    ) {
                        Icon(
                            imageVector = Icons.Outlined.Bolt,
                            contentDescription = null,
                            tint = colors.accent,
                            modifier = Modifier.size(18.dp),
                        )
                        Text(
                            text = "快速文字闪记",
                            color = colors.textPrimary,
                            fontSize = KoeFontSizes.sm,
                            fontWeight = FontWeight.SemiBold,
                        )
                        Spacer(modifier = Modifier.weight(1f))
                        KoeInfoTip(
                            title = "文字闪记",
                            message = "输入文字后按完成或点击保存，将直接写入本地 Rust 工作区。",
                        )
                    }

                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                    ) {
                        OutlinedTextField(
                            value = quickNoteDraft,
                            onValueChange = { quickNoteDraft = it },
                            placeholder = {
                                Text(
                                    text = "快速记下一段想法…",
                                    fontSize = KoeFontSizes.sm,
                                    color = colors.textMuted,
                                )
                            },
                            singleLine = true,
                            shape = KoeShapes.control,
                            colors = OutlinedTextFieldDefaults.colors(
                                focusedBorderColor = colors.accent,
                                unfocusedBorderColor = colors.border,
                                focusedContainerColor = colors.bgSubtle,
                                unfocusedContainerColor = colors.bgSubtle,
                                focusedTextColor = colors.textPrimary,
                                unfocusedTextColor = colors.textPrimary,
                            ),
                            keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done),
                            keyboardActions = KeyboardActions(onDone = { submitQuickNote() }),
                            modifier = Modifier
                                .weight(1f)
                                .testTag("quick-note-input"),
                        )

                        KoePrimaryButton(
                            title = "保存",
                            isPrimary = true,
                            enabled = quickNoteDraft.isNotBlank(),
                            onClick = { submitQuickNote() },
                            modifier = Modifier.testTag("quick-note-submit"),
                        )
                    }
                }
            }
        }

        items(cards, key = { it.id }) { card ->
            ModePickerCard(
                card = card,
                onToggle = { store.toggleModeSession(card) },
                onEnterWorkspace = { onOpenWorkspace(workspaceRouteFor(card.id)) },
            )
        }
    }
}

@Composable
private fun TodayHeaderCard(today: TodaySlice) {
    val colors = KoeTheme.colors
    KoeCard(shape = KoeShapes.largeCard) {
        Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(6.dp),
            ) {
                Text(
                    text = "模式选择",
                    color = colors.textPrimary,
                    fontSize = KoeFontSizes.lg,
                    fontWeight = FontWeight.SemiBold,
                )
                KoeInfoTip(
                    title = "模式说明",
                    message = "三种模式共享本地录音与转写引擎，按场景独立组织内容。进入工作区不会自动开始录音。",
                )
                Spacer(modifier = Modifier.weight(1f))
                KoeBadge(
                    text = today.picker?.sourceBadge ?: today.captureSelectedBadge,
                    tint = colors.accent,
                )
            }

            Text(
                text = today.picker?.sourceLabel ?: today.captureSelectedLabel,
                color = colors.textSecondary,
                fontSize = KoeFontSizes.sm,
                fontWeight = FontWeight.Medium,
            )

            Text(
                text = "共 ${today.recordCount} 条记录  |  待确认行动 ${today.proposedActionCount} 项",
                color = colors.textMuted,
                fontSize = KoeFontSizes.xs,
            )
        }
    }
}

@Composable
private fun ModePickerCard(
    card: ModePickerCardSnapshot,
    onToggle: () -> Unit,
    onEnterWorkspace: () -> Unit,
) {
    val colors = KoeTheme.colors
    KoeCard {
        Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                Surface(
                    shape = KoeShapes.control,
                    color = colors.bgSubtle,
                    modifier = Modifier.size(36.dp),
                ) {
                    Box(contentAlignment = Alignment.Center) {
                        Icon(
                            imageVector = modeIconFor(card.id),
                            contentDescription = null,
                            tint = colors.accent,
                            modifier = Modifier.size(20.dp),
                        )
                    }
                }

                Column(
                    modifier = Modifier.weight(1f),
                    verticalArrangement = Arrangement.spacedBy(2.dp),
                ) {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(6.dp),
                    ) {
                        Text(
                            text = card.title,
                            color = colors.textPrimary,
                            fontSize = KoeFontSizes.md,
                            fontWeight = FontWeight.SemiBold,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                        )
                        KoeBadge(
                            text = card.statusBadge,
                            tint = if (card.isSessionActive) colors.success else colors.textSecondary,
                        )
                    }
                    Text(
                        text = card.metricText,
                        color = colors.textMuted,
                        fontSize = KoeFontSizes.xs,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                }

                KoeInfoTip(title = card.title, message = card.subtitle)
            }

            Text(
                text = card.subtitle,
                color = colors.textSecondary,
                fontSize = KoeFontSizes.xs,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
            )

            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.SpaceBetween,
            ) {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    Switch(
                        checked = card.isSessionActive,
                        onCheckedChange = { onToggle() },
                        enabled = card.canToggleSession,
                        colors = SwitchDefaults.colors(
                            checkedThumbColor = colors.onAccent,
                            checkedTrackColor = colors.accent,
                            uncheckedThumbColor = colors.textMuted,
                            uncheckedTrackColor = colors.bgSubtle,
                        ),
                        modifier = Modifier.semantics {
                            contentDescription = "${card.title}录音开关"
                        },
                    )
                    Text(
                        text = if (card.isSessionActive) "录音中" else "待机",
                        color = colors.textSecondary,
                        fontSize = KoeFontSizes.xs,
                        fontWeight = FontWeight.Medium,
                    )
                }

                KoePrimaryButton(
                    title = "进入工作区",
                    icon = Icons.AutoMirrored.Outlined.ArrowForward,
                    isPrimary = card.isSessionActive,
                    onClick = onEnterWorkspace,
                )
            }
        }
    }
}

private fun workspaceRouteFor(cardId: String): AndroidModeWorkspaceRoute =
    when (cardId) {
        HostSection.ALL_DAY.rawValue -> AndroidModeWorkspaceRoute.ALL_DAY
        HostSection.LIVE_MINUTES.rawValue -> AndroidModeWorkspaceRoute.LIVE_MINUTES
        else -> AndroidModeWorkspaceRoute.QUICK_NOTE
    }

private fun modeIconFor(cardId: String): ImageVector =
    when (cardId) {
        HostSection.NOTES.rawValue -> Icons.Outlined.Bolt
        HostSection.ALL_DAY.rawValue -> Icons.Outlined.Schedule
        HostSection.LIVE_MINUTES.rawValue -> Icons.Outlined.Summarize
        else -> Icons.Outlined.GraphicEq
    }
