package com.semanticcraft.koe.ui.screens

import androidx.compose.foundation.clickable
import androidx.compose.foundation.text.selection.SelectionContainer
import com.semanticcraft.koe.core.SourceSnapshot
import androidx.compose.foundation.background
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.Subject
import androidx.compose.material.icons.outlined.Description
import androidx.compose.material.icons.outlined.StarOutline
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.semanticcraft.koe.core.HostCommand
import com.semanticcraft.koe.core.HostSessionStore
import com.semanticcraft.koe.core.RecordDetailSnapshot
import com.semanticcraft.koe.core.TimeLabel
import com.semanticcraft.koe.ui.components.KoeBadge
import com.semanticcraft.koe.ui.components.KoeCard
import com.semanticcraft.koe.ui.components.KoeEmptyState
import com.semanticcraft.koe.ui.components.KoePrimaryButton
import com.semanticcraft.koe.ui.leaves.AndroidPlayerBar
import com.semanticcraft.koe.ui.theme.KoeFontSizes
import com.semanticcraft.koe.ui.theme.KoeTheme

private enum class DetailTab(val label: String) {
    SUMMARY("纪要"),
    TRANSCRIPT("原文"),
    HIGHLIGHTS("重点"),
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun RecordDetailScreen(
    store: HostSessionStore,
    recordId: String,
    modifier: Modifier = Modifier,
    onOpenSource: (SourceSnapshot) -> Unit = {},
    onTrashed: () -> Unit = {},
    onAsk: () -> Unit = {},
    compact: Boolean = false,
) {
    val slice by store.recordDetail.collectAsStateWithLifecycle()
    val records by store.records.collectAsStateWithLifecycle()
    val colors = KoeTheme.colors
    var selectedTab by rememberSaveable(recordId) { mutableStateOf(DetailTab.SUMMARY) }

    LaunchedEffect(recordId) {
        if (store.recordDetail.value.detail?.id != recordId) {
            store.send(HostCommand.SelectRecord(recordId))
        }
    }

    val detail = slice.detail?.takeIf { it.id == recordId }
    val listState = rememberLazyListState()
    val focusIndex = detail?.segments?.indexOfFirst { it.id == slice.focusSegmentId } ?: -1
    LaunchedEffect(recordId, slice.focusSegmentId, focusIndex) {
        if (focusIndex >= 0) {
            selectedTab = DetailTab.TRANSCRIPT
            listState.requestScrollToItem(focusIndex + 1) // The detail header precedes the segments.
        }
    }
    fun followSource(source: SourceSnapshot) {
        onOpenSource(source)
        if (source.recordId == recordId) {
            val index = detail?.segments?.indexOfFirst { it.id == source.segmentId } ?: -1
            if (index >= 0) {
                selectedTab = DetailTab.TRANSCRIPT
                listState.requestScrollToItem(index + 1)
            }
        }
    }
    val fallbackRecord = records.firstOrNull { it.id == recordId }

    Column(
        modifier = modifier
            .fillMaxSize()
            .background(colors.bgPanel),
    ) {
        SingleChoiceSegmentedButtonRow(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 16.dp, vertical = 10.dp),
        ) {
            DetailTab.entries.forEachIndexed { index, tab ->
                SegmentedButton(
                    selected = selectedTab == tab,
                    onClick = { selectedTab = tab },
                    shape = SegmentedButtonDefaults.itemShape(index = index, count = DetailTab.entries.size),
                    colors = SegmentedButtonDefaults.colors(
                        activeContainerColor = colors.accent,
                        activeContentColor = colors.onAccent,
                        inactiveContainerColor = colors.surface1,
                        inactiveContentColor = colors.textSecondary,
                        activeBorderColor = colors.accent,
                        inactiveBorderColor = colors.border,
                    ),
                ) {
                    Text(text = tab.label, fontSize = KoeFontSizes.xs, fontWeight = FontWeight.Medium)
                }
            }
        }

        LazyColumn(
            state = listState,
            modifier = Modifier.weight(1f),
            contentPadding = PaddingValues(start = 16.dp, end = 16.dp, bottom = 16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            if (detail != null) {
                item(key = "detail-header") {
                    DetailHeaderCard(detail, store, onTrashed, onAsk)
                }

                when (selectedTab) {
                    DetailTab.SUMMARY -> {
                        if (detail.minutesStale) item {
                            KoeCard {
                                Text("原文已更新，当前纪要已过期。")
                                KoePrimaryButton("重新整理", { store.send(HostCommand.Summarize(detail.id)) })
                            }
                        }
                        if (detail.summary.isEmpty()) {
                            item(key = "summary-empty") {
                                KoeEmptyState(
                                    icon = Icons.Outlined.Description,
                                    title = "暂无纪要摘要",
                                    detail = "可在原文中标记重点，或点击上方整理纪要生成结构化总结。",
                                )
                            }
                        } else {
                            items(detail.summary, key = { it.id }) { item ->
                                KoeCard {
                                    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                                        Text(
                                            text = item.title,
                                            color = colors.textPrimary,
                                            fontSize = KoeFontSizes.md,
                                            fontWeight = FontWeight.SemiBold,
                                        )
                                        SelectionContainer {
                                            Text(
                                                text = item.text,
                                                color = colors.textSecondary,
                                                fontSize = KoeFontSizes.sm,
                                            )
                                        }
                                        WorkspaceSources(item.sources, ::followSource, "summary")
                                    }
                                }
                            }
                        }

                        items(slice.recordTasks, key = { "task-" + it.id }) { task ->
                            TaskItemCard(task, store, ::followSource)
                        }
                        items(slice.recordMemories, key = { "memory-" + it.id }) { memory ->
                            MemoryItemCard(memory, store, ::followSource)
                        }
                    }

                    DetailTab.TRANSCRIPT -> {
                        if (detail.segments.isEmpty()) {
                            item(key = "transcript-empty") {
                                KoeEmptyState(
                                    icon = Icons.AutoMirrored.Outlined.Subject,
                                    title = "暂无原文段落",
                                    detail = "录音完成转写后将按时间顺序展示原文。",
                                )
                            }
                        } else {
                            items(detail.segments, key = { it.id }) { segment ->
                                val isFocused = slice.focusSegmentId == segment.id
                                KoeCard(
                                    borderColor = if (isFocused) colors.accent else colors.border,
                                ) {
                                    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                                        Row(
                                            verticalAlignment = Alignment.CenterVertically,
                                            horizontalArrangement = Arrangement.spacedBy(8.dp),
                                        ) {
                                            Text(
                                                text = TimeLabel.duration(segment.startMs),
                                                modifier = Modifier.testTag("segment-time-" + segment.id).clickable {
                                                    if (!store.navigation.value.hasPlayableDetailAsset) {
                                                        store.reportNativeError("这条记录没有可播放的音频。")
                                                    } else if (store.sendReturningError(HostCommand.Seek(segment.startMs)) == null) {
                                                        store.send(HostCommand.Playback(true))
                                                    }
                                                },
                                                color = colors.textMuted,
                                                fontSize = KoeFontSizes.xs,
                                                fontWeight = FontWeight.Medium,
                                            )
                                            val speaker = segment.speaker
                                            if (!speaker.isNullOrBlank()) {
                                                KoeBadge(text = speaker, tint = colors.textSecondary)
                                            }
                                            if (isFocused) {
                                                KoeBadge(text = "定位段落", tint = colors.accent)
                                            }
                                        }
                                        SelectionContainer {
                                            Text(
                                                text = segment.text,
                                                color = colors.textPrimary,
                                                fontSize = KoeFontSizes.sm,
                                            )
                                        }
                                        TranscriptEditors(store, detail, segment)
                                        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                                            KoePrimaryButton(
                                                title = "标重点",
                                                isPrimary = false,
                                                onClick = { store.send(HostCommand.AddHighlight(detail.id, segment.id)) },
                                            )
                                            KoePrimaryButton(
                                                title = "建待办",
                                                isPrimary = false,
                                                onClick = { store.send(HostCommand.CreateTask(detail.id, segment.id)) },
                                            )
                                            KoePrimaryButton(
                                                title = "存记忆",
                                                isPrimary = false,
                                                onClick = { store.send(HostCommand.SaveMemory(detail.id, segment.id)) },
                                            )
                                        }
                                    }
                                }
                            }
                        }
                    }

                    DetailTab.HIGHLIGHTS -> {
                        if (detail.highlights.isEmpty()) {
                            item(key = "highlights-empty") {
                                KoeEmptyState(
                                    icon = Icons.Outlined.StarOutline,
                                    title = "暂无重点摘录",
                                    detail = "在原文页签中点击标重点，将关键句收敛到这里。",
                                )
                            }
                        } else {
                            items(detail.highlights, key = { it.id }) { highlight ->
                                KoeCard {
                                    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                                        Text(
                                            text = TimeLabel.duration(highlight.startMs),
                                            color = colors.textMuted,
                                            fontSize = KoeFontSizes.xs,
                                            fontWeight = FontWeight.Medium,
                                        )
                                        SelectionContainer {
                                            Text(
                                                text = highlight.quote,
                                                color = colors.textPrimary,
                                                fontSize = KoeFontSizes.sm,
                                            )
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            } else if (fallbackRecord != null) {
                item(key = "fallback") {
                    KoeCard {
                        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                            Text(
                                text = fallbackRecord.title,
                                color = colors.textPrimary,
                                fontSize = KoeFontSizes.lg,
                                fontWeight = FontWeight.SemiBold,
                            )
                            Text(
                                text = fallbackRecord.preview.ifEmpty { "正在读取记录详情…" },
                                color = colors.textSecondary,
                                fontSize = KoeFontSizes.sm,
                            )
                        }
                    }
                }
            } else {
                item(key = "missing") {
                    KoeEmptyState(
                        icon = Icons.Outlined.Description,
                        title = "未找到记录详情",
                        detail = "该记录可能已移入回收站。",
                    )
                }
            }
        }

        AndroidPlayerBar(store = store, compact = compact)
    }
}

@Composable
private fun DetailHeaderCard(
    detail: RecordDetailSnapshot,
    store: HostSessionStore,
    onTrashed: () -> Unit,
    onAsk: () -> Unit,
) {
    val navigation by store.navigation.collectAsStateWithLifecycle()
    var renaming by rememberSaveable(detail.id) { mutableStateOf(false) }
    if (renaming) TextEditorDialog("记录名称", detail.title, { renaming = false }, { value ->
        store.sendReturningError(HostCommand.RenameRecord(detail.id, value)) == null
    }, singleLine = true)
    val colors = KoeTheme.colors
    KoeCard {
        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                KoeBadge(text = detail.modeLabel, tint = colors.accent)
                KoeBadge(text = detail.status, tint = colors.textSecondary)
                Spacer(modifier = Modifier.weight(1f))
                Text(
                    text = TimeLabel.duration(detail.durationMs),
                    color = colors.textMuted,
                    fontSize = KoeFontSizes.xs,
                    fontWeight = FontWeight.Medium,
                )
            }

            Text(
                text = detail.title,
                color = colors.textPrimary,
                fontSize = KoeFontSizes.lg,
                fontWeight = FontWeight.SemiBold,
            )

            Text(
                text = "${TimeLabel.date(detail.createdAtEpochSec)}  |  ${detail.source}  |  ${detail.segments.size} 段原文",
                color = colors.textMuted,
                fontSize = KoeFontSizes.xs,
            )

            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .horizontalScroll(rememberScrollState()),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                KoePrimaryButton("重命名", { renaming = true }, isPrimary = false)
                KoePrimaryButton("问这条记录", {
                    if (store.sendReturningError(HostCommand.SetAskScope("record", detail.id)) == null) onAsk()
                }, isPrimary = false)
                KoePrimaryButton("移入回收站", {
                    if (detail.canTrash && store.navigation.value.savingRecordId != detail.id &&
                        store.sendReturningError(HostCommand.TrashRecord(detail.id)) == null) onTrashed()
                }, enabled = detail.canTrash && navigation.savingRecordId != detail.id, isPrimary = false)
                if (detail.canRetranscribe) {
                    KoePrimaryButton(
                        title = "重新转写",
                        isPrimary = false,
                        onClick = { store.send(HostCommand.Transcribe(detail.id)) },
                    )
                }
                KoePrimaryButton(
                    title = "整理纪要",
                    isPrimary = false,
                    onClick = { store.send(HostCommand.Summarize(detail.id)) },
                )
                KoePrimaryButton(
                    title = "导出",
                    isPrimary = false,
                    onClick = { store.bridgeActions.requestExportWorkspace(detail.id, null, "${detail.title}.md") },
                    modifier = Modifier.testTag("detail-export-button"),
                )
                KoePrimaryButton(
                    title = if (detail.archived) "取消归档" else "归档",
                    isPrimary = false,
                    onClick = { store.send(HostCommand.SetRecordArchived(detail.id, !detail.archived)) },
                )
            }
        }
    }
}
