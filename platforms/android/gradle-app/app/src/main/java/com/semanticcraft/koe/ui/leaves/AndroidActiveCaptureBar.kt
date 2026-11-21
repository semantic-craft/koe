package com.semanticcraft.koe.ui.leaves

import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.GraphicEq
import androidx.compose.material3.Icon
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.semanticcraft.koe.core.CaptureMode
import com.semanticcraft.koe.core.CaptureAction
import com.semanticcraft.koe.core.HostSessionStore
import com.semanticcraft.koe.core.TimeLabel
import com.semanticcraft.koe.ui.components.KoePrimaryButton
import com.semanticcraft.koe.ui.theme.KoeFontSizes
import com.semanticcraft.koe.ui.theme.KoeShapes
import com.semanticcraft.koe.ui.theme.KoeTheme

@Composable
fun AndroidActiveCaptureBar(
    store: HostSessionStore,
    modifier: Modifier = Modifier,
    workspaceMode: CaptureMode? = null,
) {
    val capture by store.activeCapture.collectAsStateWithLifecycle()
    val active = capture ?: return
    if (active.mode == workspaceMode) return
    val colors = KoeTheme.colors

    Surface(
        modifier = modifier
            .fillMaxWidth()
            .testTag("active-capture-bar"),
        shape = KoeShapes.card,
        color = colors.bgSubtle,
        border = BorderStroke(1.dp, colors.border),
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 14.dp, vertical = 10.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Icon(
                imageVector = Icons.Outlined.GraphicEq,
                contentDescription = null,
                tint = if (active.phase == "recording") colors.danger else colors.textSecondary,
                modifier = Modifier.size(18.dp),
            )

            Column(
                modifier = Modifier.weight(1f),
                verticalArrangement = Arrangement.spacedBy(2.dp),
            ) {
                Text(
                    text = "${active.mode.title}  ${capturePhaseLabel(active.phase)}",
                    color = colors.textPrimary,
                    fontSize = KoeFontSizes.xs,
                    fontWeight = FontWeight.SemiBold,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                Text(
                    text = active.error ?: "${active.sourceLabel}  ${TimeLabel.duration(active.durationMs)}",
                    color = colors.textSecondary,
                    fontSize = KoeFontSizes.xs,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }

            Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                active.actions.forEach { action ->
                    KoePrimaryButton(
                        title = captureActionTitle(action),
                        isPrimary = action == CaptureAction.END,
                        onClick = { store.performCaptureAction(action) },
                        modifier = Modifier.testTag("capture-action-${action.name.lowercase()}"),
                    )
                }
            }
        }
    }
}

private fun capturePhaseLabel(phase: String): String =
    when (phase) {
        "starting" -> "正在启动"
        "recording" -> "正在记录"
        "pausing" -> "正在暂停"
        "paused" -> "已暂停"
        "cancelling" -> "正在取消"
        else -> "正在保存"
    }

@Composable
internal fun WorkspaceCaptureActions(store: HostSessionStore, mode: CaptureMode) {
    val capture by store.activeCapture.collectAsStateWithLifecycle()
    val active = capture?.takeIf { it.mode == mode } ?: return
    Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        active.actions.forEach { action ->
            KoePrimaryButton(captureActionTitle(action), { store.performCaptureAction(action) },
                Modifier.testTag("workspace-capture-" + action.name.lowercase()), isPrimary = action == CaptureAction.END)
        }
    }
}

private fun captureActionTitle(action: CaptureAction): String =
    when (action) {
        CaptureAction.PAUSE -> "暂停"
        CaptureAction.RESUME -> "继续"
        CaptureAction.END -> "结束"
        CaptureAction.RETRY_STOP -> "重试停止"
        CaptureAction.RETRY_SAVE -> "重试保存"
        CaptureAction.CANCEL -> "取消"
    }
