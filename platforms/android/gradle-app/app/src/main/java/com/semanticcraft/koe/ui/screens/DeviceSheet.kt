package com.semanticcraft.koe.ui.screens

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.BluetoothSearching
import androidx.compose.material.icons.automirrored.outlined.HelpOutline
import androidx.compose.material.icons.outlined.Mic
import androidx.compose.material.icons.outlined.Refresh
import androidx.compose.material3.Icon
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.semanticcraft.koe.core.HostCommand
import com.semanticcraft.koe.core.HostSessionStore
import com.semanticcraft.koe.core.TimeLabel
import com.semanticcraft.koe.ui.components.KoeBadge
import com.semanticcraft.koe.ui.components.KoeCard
import com.semanticcraft.koe.ui.components.KoeModalSheet
import com.semanticcraft.koe.ui.components.KoePrimaryButton
import com.semanticcraft.koe.ui.theme.KoeFontSizes
import com.semanticcraft.koe.ui.theme.KoeShapes
import com.semanticcraft.koe.ui.theme.KoeTheme

@Composable
fun DeviceSheet(
    store: HostSessionStore,
    onDismiss: () -> Unit,
) {
    val device by store.device.collectAsStateWithLifecycle()
    val navigation by store.navigation.collectAsStateWithLifecycle()
    val today by store.today.collectAsStateWithLifecycle()
    val colors = KoeTheme.colors
    val isReleased = today.beanControlState == "released"

    KoeModalSheet(onDismissRequest = onDismiss) {
        Column(verticalArrangement = Arrangement.spacedBy(14.dp)) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                Row(
                    modifier = Modifier.weight(1f),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(6.dp),
                ) {
                    Icon(
                        imageVector = Icons.Outlined.Mic,
                        contentDescription = null,
                        tint = colors.accent,
                        modifier = Modifier.size(18.dp),
                    )
                    Text(
                        text = device.deviceName,
                        color = colors.textPrimary,
                        fontSize = KoeFontSizes.md,
                        fontWeight = FontWeight.SemiBold,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.weight(1f, fill = false),
                    )
                    KoeBadge(
                        text = if (isReleased) "已让出" else device.state,
                        tint = when {
                            isReleased -> colors.textMuted
                            device.connected -> colors.success
                            else -> colors.warning
                        },
                    )
                }
                KoePrimaryButton(
                    title = "完成",
                    isPrimary = false,
                    onClick = onDismiss,
                    modifier = Modifier.testTag("device-sheet-close"),
                )
            }

            navigation.effectiveError?.let { message ->
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(message, color = colors.danger, modifier = Modifier.weight(1f))
                    KoePrimaryButton(title = "知道了", isPrimary = false, onClick = store::clearError)
                }
            }

            Text(
                text = device.statusDetail,
                color = colors.textSecondary,
                fontSize = KoeFontSizes.xs,
            )

            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.spacedBy(10.dp),
                ) {
                    DeviceTelemetryTile(
                        label = "录音豆电量",
                        value = device.batteryPercent?.let {
                            if (device.charging) "$it% 充电中" else "$it%"
                        } ?: "-",
                        modifier = Modifier.weight(1f),
                    )
                    DeviceTelemetryTile(
                        label = "充电仓电量",
                        value = device.boxBatteryPercent?.let {
                            if (device.boxCharging) "$it% 充电中" else "$it%"
                        } ?: "-",
                        modifier = Modifier.weight(1f),
                    )
                }

                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.spacedBy(10.dp),
                ) {
                    DeviceTelemetryTile(
                        label = "固件版本",
                        value = device.firmwareVersion.ifBlank { "-" },
                        modifier = Modifier.weight(1f),
                    )
                    DeviceTelemetryTile(
                        label = "设备存储",
                        value = device.storageLabel,
                        modifier = Modifier.weight(1f),
                    )
                }
            }

            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(
                    text = "蓝牙控制权",
                    color = colors.textPrimary,
                    fontSize = KoeFontSizes.xs,
                    fontWeight = FontWeight.SemiBold,
                )
                Surface(
                    shape = KoeShapes.control,
                    color = colors.bgSubtle,
                    border = BorderStroke(1.dp, colors.border),
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(4.dp),
                        horizontalArrangement = Arrangement.spacedBy(6.dp),
                    ) {
                        ControlModeButton(
                            title = "当前 Android 连接",
                            active = !isReleased,
                            enabled = !device.busy,
                            onClick = {
                                if (isReleased) {
                                    store.send(HostCommand.DeviceOpenGuide)
                                    store.bridgeActions.requestBleScan()
                                }
                            },
                            modifier = Modifier.weight(1f),
                        )
                        ControlModeButton(
                            title = "让出控制权",
                            active = isReleased,
                            enabled = !isReleased && store.canReleaseToPhone,
                            onClick = {
                                if (!isReleased) {
                                    store.send(HostCommand.DeviceRelease)
                                    store.bridgeActions.flushBleOutbound()
                                }
                            },
                            modifier = Modifier.weight(1f),
                        )
                    }
                }
            }

            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.SpaceBetween,
            ) {
                Text(
                    text = "启动时自动连接录音豆",
                    color = colors.textPrimary,
                    fontSize = KoeFontSizes.xs,
                    fontWeight = FontWeight.Medium,
                )
                Switch(
                    checked = device.autoConnect,
                    onCheckedChange = { enabled -> store.send(HostCommand.SetBleAutoConnect(enabled)) },
                    colors = SwitchDefaults.colors(
                        checkedThumbColor = colors.onAccent,
                        checkedTrackColor = colors.accent,
                        uncheckedThumbColor = colors.textMuted,
                        uncheckedTrackColor = colors.bgSubtle,
                    ),
                )
            }

            val guide = device.guide
            if (guide != null) {
                KoeCard {
                    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.SpaceBetween,
                        ) {
                            Text(
                                text = if (guide.mode == "onboarding") {
                                    "连接引导  ${guide.step + 1} / ${maxOf(guide.totalSteps, 1)}"
                                } else "连接引导",
                                color = colors.textMuted,
                                fontSize = KoeFontSizes.xs,
                                fontWeight = FontWeight.SemiBold,
                            )
                            KoePrimaryButton(
                                title = "关闭引导",
                                isPrimary = false,
                                onClick = { store.send(HostCommand.DeviceCloseGuide) },
                            )
                        }
                        Text(
                            text = guide.title,
                            color = colors.textPrimary,
                            fontSize = KoeFontSizes.sm,
                            fontWeight = FontWeight.SemiBold,
                        )
                        Text(
                            text = guide.subtitle,
                            color = colors.textSecondary,
                            fontSize = KoeFontSizes.xs,
                        )
                        if (guide.primaryLabel.isNotBlank()) {
                            KoePrimaryButton(
                                title = guide.primaryLabel,
                                isPrimary = true,
                                onClick = {
                                    if (guide.mode == "connect_guide") {
                                        store.bridgeActions.requestBleScan()
                                    } else {
                                        store.send(HostCommand.DeviceOnboardingNext)
                                    }
                                },
                            )
                        }
                    }
                }
            }

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

            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                if (device.connected) {
                    KoePrimaryButton(
                        title = "刷新状态",
                        icon = Icons.Outlined.Refresh,
                        isPrimary = false,
                        enabled = !device.busy,
                        onClick = {
                            store.send(HostCommand.DeviceRefresh)
                            store.bridgeActions.flushBleOutbound()
                        },
                    )
                    KoePrimaryButton(
                        title = "连接引导",
                        icon = Icons.AutoMirrored.Outlined.HelpOutline,
                        isPrimary = false,
                        onClick = { store.send(HostCommand.DeviceOpenGuide) },
                    )
                } else {
                    KoePrimaryButton(
                        title = "连接录音豆",
                        icon = Icons.AutoMirrored.Outlined.BluetoothSearching,
                        isPrimary = true,
                        enabled = !device.busy,
                        modifier = Modifier.testTag("device-connect-button"),
                        onClick = {
                            store.send(HostCommand.DeviceOpenGuide)
                            store.bridgeActions.requestBleScan()
                        },
                    )
                    KoePrimaryButton(
                        title = "重新扫描",
                        icon = Icons.Outlined.Refresh,
                        isPrimary = false,
                        enabled = !device.busy,
                        modifier = Modifier.testTag("device-rescan-button"),
                        onClick = { store.bridgeActions.requestBleScan() },
                    )
                }
            }
        }
    }
}

@Composable
private fun DeviceTelemetryTile(
    label: String,
    value: String,
    modifier: Modifier = Modifier,
) {
    val colors = KoeTheme.colors
    Surface(
        modifier = modifier,
        shape = KoeShapes.control,
        color = colors.bgSubtle,
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(12.dp),
            verticalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            Text(
                text = label,
                color = colors.textMuted,
                fontSize = KoeFontSizes.xs,
            )
            Text(
                text = value,
                color = colors.textPrimary,
                fontSize = KoeFontSizes.sm,
                fontWeight = FontWeight.SemiBold,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
    }
}

@Composable
private fun ControlModeButton(
    title: String,
    active: Boolean,
    enabled: Boolean,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val colors = KoeTheme.colors
    Surface(
        onClick = onClick,
        enabled = enabled,
        modifier = modifier.heightIn(min = 36.dp),
        shape = KoeShapes.control,
        color = if (active) colors.accent else colors.bgSubtle,
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 8.dp, vertical = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.Center,
        ) {
            Text(
                text = title,
                color = if (active) colors.onAccent else colors.textSecondary,
                fontSize = KoeFontSizes.xs,
                fontWeight = if (active) FontWeight.SemiBold else FontWeight.Medium,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                textAlign = TextAlign.Center,
            )
        }
    }
}
