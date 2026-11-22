package com.semanticcraft.koe.ui.screens

import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Schedule
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.semanticcraft.koe.core.CaptureMode
import com.semanticcraft.koe.core.HostCommand
import com.semanticcraft.koe.core.HostSessionStore
import com.semanticcraft.koe.core.SourceSnapshot
import com.semanticcraft.koe.core.TimeLabel
import com.semanticcraft.koe.ui.components.KoeBadge
import com.semanticcraft.koe.ui.components.KoeCard
import com.semanticcraft.koe.ui.components.KoeEmptyState
import com.semanticcraft.koe.ui.components.KoeFilterChip
import com.semanticcraft.koe.ui.components.KoePrimaryButton
import com.semanticcraft.koe.ui.components.StableList
import com.semanticcraft.koe.ui.theme.KoeFontSizes
import com.semanticcraft.koe.ui.theme.KoeTheme

@Composable
internal fun AllDayWorkspaceScreen(
    store: HostSessionStore, onSelectRecord: (String) -> Unit, onOpenSource: (SourceSnapshot) -> Unit,
    onOpenCaptureSource: () -> Unit, modifier: Modifier = Modifier,
) {
    val workspace by store.allDayWorkspace.collectAsStateWithLifecycle()
    val date = workspace.selectedDate
    val status = when {
        workspace.isPaused -> "已暂停"
        workspace.isActive -> "记录中"
        else -> "待机"
    }
    WorkspaceList(modifier) {
        item {
            WorkspaceHeader(store, CaptureMode.ALL_DAY, date, workspace.sourceLabel, status,
                workspace.isActive, workspace.canStart, onOpenCaptureSource)
        }
        item { Text("事件 ${workspace.eventCount}  |  已录 ${TimeLabel.duration(workspace.totalRecordedMs)}  |  暂停 ${workspace.pauseCount}  |  空档 ${workspace.gapCount}") }
        if (workspace.availableDates.isNotEmpty()) item {
            Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                workspace.availableDates.forEach { day ->
                    KoeFilterChip(day, day == date, { store.send(HostCommand.SelectAllDayDate(day)) })
                }
            }
        }
        if (date.isNotBlank()) item {
            WorkspaceExport(store, null, date, "Koe-$date.md", "导出当日", "all-day-export-button")
        }
        workspace.dailyReview?.let { review ->
            item {
                KoeCard {
                    WorkspaceTitle("每日回顾")
                    Text(review.overview)
                    review.highlights.forEach { Text(it) }
                    WorkspaceSources(StableList(review.sources), onOpenSource)
                }
            }
        }
        if (workspace.reviewDecisions.isNotEmpty()) item { WorkspaceTitle("当日决定") }
        items(workspace.reviewDecisions, key = { "decision-" + it.id }) { decision ->
            KoeCard {
                Text(decision.text)
                WorkspaceSources(StableList(decision.sources), onOpenSource)
            }
        }
        if (workspace.reviewTasks.isNotEmpty() || workspace.reviewMemories.isNotEmpty()) item { WorkspaceTitle("待办与记忆") }
        items(workspace.reviewTasks, key = { "task-" + it.id }) { WorkspaceReviewRow(store, it, onOpenSource) }
        items(workspace.reviewMemories, key = { "memory-" + it.id }) { WorkspaceReviewRow(store, it, onOpenSource) }
        item { WorkspaceTitle("当日时间线") }
        if (workspace.spans.isEmpty()) item {
            KoeEmptyState(Icons.Outlined.Schedule, "当日暂无时间线", "全天听记会按对话事件与空档整理当日回顾。")
        }
        items(workspace.spans, key = { "span-" + it.id }) { span ->
            if (span.kind == "pause" || span.kind == "unrecorded_gap") {
                Column(Modifier.fillMaxWidth().testTag("span-" + span.id)) {
                    HorizontalDivider()
                    Text(span.statusSummaryLabel(), Modifier.padding(vertical = 4.dp),
                        color = KoeTheme.colors.textMuted, fontSize = KoeFontSizes.xs)
                }
            } else {
                KoeCard {
                    WorkspaceTitle(span.title ?: "对话事件")
                    Text(span.statusSummaryLabel())
                    if (span.speakers.isNotEmpty()) Text(span.speakers.joinToString("、"))
                    span.sliceBadgeText?.let { KoeBadge(it) }
                    span.summaryPoints.forEach { Text(it) }
                    if (span.preview.isNotBlank()) Text(span.preview, color = KoeTheme.colors.textSecondary)
                    val source = span.firstSegment
                    val recordId = span.primaryRecordId ?: span.recordId
                    if (source != null || recordId != null) {
                        KoePrimaryButton("定位原文", {
                            if (source != null) onOpenSource(source) else recordId?.let(onSelectRecord)
                        }, isPrimary = false)
                    }
                }
            }
        }
    }
}
