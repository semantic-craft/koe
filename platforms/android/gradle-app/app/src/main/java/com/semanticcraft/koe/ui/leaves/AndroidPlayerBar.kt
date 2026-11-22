package com.semanticcraft.koe.ui.leaves

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Slider
import androidx.compose.material3.SliderDefaults
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.semanticcraft.koe.core.HostCommand
import com.semanticcraft.koe.core.HostSessionStore
import com.semanticcraft.koe.core.TimeLabel
import com.semanticcraft.koe.ui.components.KoeBadge
import com.semanticcraft.koe.ui.theme.KoeFontSizes
import com.semanticcraft.koe.ui.theme.KoeShapes
import com.semanticcraft.koe.ui.theme.KoeTheme

@Composable
fun AndroidPlayerBar(
    store: HostSessionStore,
    modifier: Modifier = Modifier,
    compact: Boolean = false,
) {
    val playback by store.playback.collectAsStateWithLifecycle()
    val nav by store.navigation.collectAsStateWithLifecycle()
    if (playback.asset == null || playback.recordId != nav.detailId) return

    val colors = KoeTheme.colors
    val durationMs = nav.detailDurationMs.coerceAtLeast(1L)
    var dragPosition by remember(playback.recordId, playback.lane) { mutableStateOf<Long?>(null) }
    val position = dragPosition ?: playback.positionMs
    var laneMenuExpanded by remember { mutableStateOf(false) }

    val seekSlider: @Composable (Modifier) -> Unit = { sliderModifier ->
        Slider(
            value = position.coerceIn(0L, durationMs).toFloat(),
            onValueChange = { dragPosition = it.toLong() },
            onValueChangeFinished = {
                dragPosition?.let { store.send(HostCommand.Seek(it)) }
                dragPosition = null
            },
            valueRange = 0f..durationMs.toFloat(),
            colors = SliderDefaults.colors(
                thumbColor = colors.accent,
                activeTrackColor = colors.accent,
                inactiveTrackColor = colors.border,
            ),
            modifier = sliderModifier.testTag("player-seek").semantics { contentDescription = "播放进度" },
        )
    }

    Surface(
        modifier = modifier
            .fillMaxWidth()
            .testTag("android-player-bar"),
        color = colors.surface1,
        border = BorderStroke(1.dp, colors.border),
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 16.dp, vertical = 10.dp),
            verticalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                Surface(
                    onClick = { store.send(HostCommand.Playback(isPlaying = !playback.isPlaying)) },
                    modifier = Modifier
                        .size(36.dp)
                        .testTag("player-toggle-button")
                        .semantics {
                            contentDescription = if (playback.isPlaying) "暂停播放" else "开始播放"
                        },
                    shape = KoeShapes.pill,
                    color = colors.accent,
                ) {
                    Box(contentAlignment = Alignment.Center) {
                        Icon(
                            imageVector = if (playback.isPlaying) Icons.Filled.Pause else Icons.Filled.PlayArrow,
                            contentDescription = null,
                            tint = colors.onAccent,
                            modifier = Modifier.size(20.dp),
                        )
                    }
                }

                Column(
                    modifier = Modifier.weight(1f),
                    verticalArrangement = Arrangement.spacedBy(2.dp),
                ) {
                    Text(
                        text = nav.detailTitle ?: "录音回放",
                        color = colors.textPrimary,
                        fontSize = KoeFontSizes.xs,
                        fontWeight = FontWeight.SemiBold,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                    Text(
                        text = "${TimeLabel.duration(position)} / ${TimeLabel.duration(nav.detailDurationMs)}",
                        color = colors.textMuted,
                        fontSize = KoeFontSizes.xs,
                        modifier = Modifier.testTag("player-position-label"),
                    )
                }

                if (compact) seekSlider(Modifier.weight(2f))

                if (playback.lanes.size > 1) {
                    Box {
                        val activeLaneLabel = playback.lanes
                            .firstOrNull { it.id == playback.lane }
                            ?.label ?: "音源"
                        Surface(
                            onClick = { laneMenuExpanded = true },
                            color = colors.surface1,
                        ) {
                            KoeBadge(text = activeLaneLabel, tint = colors.textSecondary)
                        }
                        DropdownMenu(
                            expanded = laneMenuExpanded,
                            onDismissRequest = { laneMenuExpanded = false },
                        ) {
                            playback.lanes.forEach { lane ->
                                DropdownMenuItem(
                                    text = { Text(text = lane.label, fontSize = KoeFontSizes.xs) },
                                    enabled = lane.available,
                                    onClick = {
                                        laneMenuExpanded = false
                                        store.send(HostCommand.SelectPlaybackLane(lane.id))
                                    },
                                )
                            }
                        }
                    }
                }
            }

            if (!compact) seekSlider(Modifier)
        }
    }
}

@Composable
fun AndroidMiniPlayerBar(
    store: HostSessionStore,
    visibleRecordId: String?,
    onOpenRecord: (String) -> Unit,
    modifier: Modifier = Modifier,
) {
    val playback by store.playback.collectAsStateWithLifecycle()
    val asset = playback.asset ?: return
    val id = playback.recordId ?: return
    if (id == visibleRecordId) return
    val records by store.records.collectAsStateWithLifecycle()
    val record = records.firstOrNull { it.id == id }
    val duration = record?.durationMs?.takeIf { it > 0 } ?: asset.durationNs / 1_000_000
    Surface(onClick = { onOpenRecord(id) }, color = KoeTheme.colors.surface1,
        modifier = modifier.fillMaxWidth().testTag("mini-player-bar")) {
        Row(modifier = Modifier.padding(horizontal = 12.dp), verticalAlignment = Alignment.CenterVertically) {
            IconButton(onClick = { store.send(HostCommand.Playback(!playback.isPlaying)) }) {
                Icon(if (playback.isPlaying) Icons.Filled.Pause else Icons.Filled.PlayArrow,
                    contentDescription = if (playback.isPlaying) "暂停播放" else "开始播放")
            }
            Text(record?.title ?: "录音回放", modifier = Modifier.weight(1f), maxLines = 1,
                overflow = TextOverflow.Ellipsis, fontSize = KoeFontSizes.sm)
            Text("${TimeLabel.duration(playback.positionMs)} / ${TimeLabel.duration(duration)}",
                fontSize = KoeFontSizes.xs)
        }
    }
}
