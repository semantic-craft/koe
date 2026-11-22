package com.semanticcraft.koe.ui.screens

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Close
import androidx.compose.material.icons.outlined.DeleteOutline
import androidx.compose.material.icons.outlined.WarningAmber
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.semanticcraft.koe.core.HostCommand
import com.semanticcraft.koe.core.HostSessionStore
import com.semanticcraft.koe.core.NavigationChromeSlice
import com.semanticcraft.koe.core.UndoTrashSnapshot
import com.semanticcraft.koe.ui.components.KoePrimaryButton
import com.semanticcraft.koe.ui.leaves.AndroidActiveCaptureBar
import com.semanticcraft.koe.ui.leaves.AndroidLiveCaptionBar
import com.semanticcraft.koe.ui.theme.KoeFontSizes
import com.semanticcraft.koe.ui.theme.KoeShapes
import com.semanticcraft.koe.ui.theme.KoeTheme
import kotlinx.coroutines.delay

@Composable
internal fun DeviceStatusPill(
    store: HostSessionStore,
    onClick: () -> Unit,
) {
    val device by store.device.collectAsStateWithLifecycle()
    val today by store.today.collectAsStateWithLifecycle()
    val connected = device.connected
    val phase = device.phase
    val batteryPercent = device.batteryPercent
    val isReleased = today.beanControlState == "released"
    val colors = KoeTheme.colors
    val label = when {
        isReleased -> "录音豆 已让出"
        connected && batteryPercent != null -> "录音豆 ${batteryPercent}%"
        connected -> "录音豆 已连接"
        else -> "录音豆"
    }
    val dotColor = when {
        isReleased -> colors.textMuted
        connected -> colors.success
        phase == "disconnected" -> colors.textMuted
        else -> colors.warning
    }

    Surface(
        onClick = onClick,
        shape = KoeShapes.pill,
        color = colors.bgSubtle,
        border = BorderStroke(1.dp, colors.border),
        modifier = Modifier.testTag("device-status-pill"),
    ) {
        Row(
            modifier = Modifier.padding(horizontal = 10.dp, vertical = 6.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            Box(modifier = Modifier.size(7.dp).clip(KoeShapes.pill).background(dotColor))
            Text(
                text = label,
                color = colors.textPrimary,
                fontSize = KoeFontSizes.xs,
                fontWeight = FontWeight.SemiBold,
                maxLines = 1,
            )
        }
    }
}

@Composable
internal fun DockedBottomChrome(
    store: HostSessionStore,
    navigation: NavigationChromeSlice,
    onOpenRecord: (String) -> Unit,
    workspace: AndroidModeWorkspaceRoute?,
    compact: Boolean = false,
) {
    val colors = KoeTheme.colors

    Column(modifier = Modifier.fillMaxWidth().background(colors.bgPanel)) {
        navigation.effectiveError?.let { errorMessage ->
            Surface(
                shape = KoeShapes.card,
                color = colors.surface1,
                border = BorderStroke(1.dp, colors.danger.copy(alpha = 0.4f)),
                modifier = Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 4.dp),
            ) {
                Row(
                    modifier = Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 10.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    Icon(Icons.Outlined.WarningAmber, contentDescription = null, tint = colors.danger, modifier = Modifier.size(18.dp))
                    Text(
                        text = errorMessage,
                        color = colors.textPrimary,
                        fontSize = KoeFontSizes.xs,
                        maxLines = 2,
                        overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.weight(1f),
                    )
                    KoePrimaryButton(title = "知道了", isPrimary = false, onClick = { store.clearError() })
                }
            }
        }

        val notice = navigation.notice
        var dismissed by rememberSaveable(notice) { mutableStateOf(false) }
        if (!notice.isNullOrBlank() && !dismissed) {
            Row(
                modifier = Modifier.fillMaxWidth().padding(start = 16.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(notice, modifier = Modifier.weight(1f), color = colors.success, fontSize = KoeFontSizes.xs)
                IconButton(onClick = { dismissed = true }) {
                    Icon(Icons.Outlined.Close, contentDescription = "关闭提示")
                }
            }
        }

        val barPadding = Modifier.padding(horizontal = 12.dp, vertical = 4.dp)
        if (compact && navigation.hasLiveCaption && navigation.activeCaptureMode != null &&
            navigation.activeCaptureMode != workspace?.mode
        ) {
            Row(verticalAlignment = Alignment.Bottom) {
                AndroidLiveCaptionBar(store, onOpenRecord, Modifier.weight(1f).then(barPadding))
                AndroidActiveCaptureBar(store, Modifier.weight(1f).then(barPadding), workspace?.mode)
            }
        } else {
            AndroidLiveCaptionBar(store, onOpenRecord, barPadding)
            AndroidActiveCaptureBar(store, barPadding, workspace?.mode)
        }
        UndoTrashBar(store = store, undo = navigation.undoTrash)
    }
}

@Composable
private fun UndoTrashBar(store: HostSessionStore, undo: UndoTrashSnapshot?) {
    if (undo == null) return
    val colors = KoeTheme.colors

    LaunchedEffect(undo.recordId) {
        delay(8_000L)
        if (store.navigation.value.undoTrash?.recordId == undo.recordId) {
            store.send(HostCommand.DismissUndoTrash)
        }
    }

    Surface(
        shape = KoeShapes.card,
        color = colors.surface1,
        border = BorderStroke(1.dp, colors.border),
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 12.dp, vertical = 4.dp)
            .testTag("undo-trash-bar"),
    ) {
        Row(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 10.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Icon(Icons.Outlined.DeleteOutline, contentDescription = null, tint = colors.textSecondary, modifier = Modifier.size(18.dp))
            Text(
                text = "已移入回收站  ${undo.title}",
                color = colors.textPrimary,
                fontSize = KoeFontSizes.xs,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.weight(1f),
            )
            KoePrimaryButton(
                title = "撤销",
                modifier = Modifier.testTag("trash-undo"),
                isPrimary = true,
                onClick = {
                    val ids = undo.effectiveRecordIds
                    if (ids.size > 1) store.send(HostCommand.BatchRestoreRecords(ids))
                    else store.send(HostCommand.RestoreRecord(undo.recordId))
                },
            )
        }
    }
}
