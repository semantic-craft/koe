package com.semanticcraft.koe.ui.screens

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material3.LinearProgressIndicator
import com.semanticcraft.koe.core.DeviceSnapshot
import kotlin.math.roundToInt
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
import com.semanticcraft.koe.core.HostCommand
import com.semanticcraft.koe.core.HostSessionStore
import com.semanticcraft.koe.core.TimeLabel
import com.semanticcraft.koe.ui.components.KoeBadge
import com.semanticcraft.koe.ui.components.KoePrimaryButton
import com.semanticcraft.koe.ui.theme.KoeFontSizes
import com.semanticcraft.koe.ui.theme.KoeShapes
import com.semanticcraft.koe.ui.theme.KoeTheme

@Composable
internal fun DeviceFilesSection(device: DeviceSnapshot, store: HostSessionStore, onOpenRecord: (String) -> Unit) {
    val colors = KoeTheme.colors
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.SpaceBetween,
        ) {
            Text(
                text = "离线录音文件 (${device.files.size})",
                color = colors.textPrimary,
                fontSize = KoeFontSizes.xs,
                fontWeight = FontWeight.SemiBold,
            )
            if (device.files.isNotEmpty()) {
                KoePrimaryButton(
                    title = "全部取回",
                    isPrimary = false,
                    enabled = !device.busy,
                    onClick = {
                        store.send(HostCommand.DeviceDownloadAll)
                        store.bridgeActions.flushBleOutbound()
                    },
                )
            }
        }

        if ((device.busy && device.transferPhase == "pulling_offline") || device.files.any { it.downloading }) {
            val ratio = device.progress.coerceIn(0.0, 1.0).toFloat()
            Text("${(ratio * 100).roundToInt()}%")
            DeviceProgress(ratio, "transfer-progress")
        }
        if (device.files.isEmpty()) {
            Text(
                text = "设备内暂无待取回的离线文件。",
                color = colors.textMuted,
                fontSize = KoeFontSizes.xs,
            )
        } else {
            device.files.forEach { file ->
                Surface(
                    shape = KoeShapes.control,
                    color = colors.bgSubtle,
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(10.dp),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(10.dp),
                    ) {
                        Column(
                            modifier = Modifier.weight(1f),
                            verticalArrangement = Arrangement.spacedBy(2.dp),
                        ) {
                            Text(
                                text = file.title,
                                color = colors.textPrimary,
                                fontSize = KoeFontSizes.xs,
                                fontWeight = FontWeight.Medium,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
                            )
                            Text(
                                text = TimeLabel.duration(file.durationMs),
                                color = colors.textMuted,
                                fontSize = KoeFontSizes.xs,
                            )
                        }
                        if (file.synced) {
                            KoeBadge(text = "已取回", tint = colors.success)
                            file.recordId?.takeIf { it.isNotBlank() }?.let { id ->
                                KoePrimaryButton("查看记录", { onOpenRecord(id) }, isPrimary = false)
                            }
                        } else {
                            KoePrimaryButton(
                                title = if (file.downloading) "取回中" else "取回",
                                isPrimary = false,
                                enabled = !file.downloading && !device.busy,
                                onClick = {
                                    store.send(HostCommand.DeviceDownload(file.id))
                                    store.bridgeActions.flushBleOutbound()
                                },
                            )
                        }
                    }
                }
            }
        }
    }
}

@Composable
internal fun DeviceProgress(ratio: Float, tag: String) {
    LinearProgressIndicator(progress = { ratio.coerceIn(0f, 1f) }, modifier = Modifier.fillMaxWidth().testTag(tag))
}
