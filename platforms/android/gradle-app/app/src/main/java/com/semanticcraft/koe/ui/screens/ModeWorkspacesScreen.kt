package com.semanticcraft.koe.ui.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.KeyboardArrowRight
import androidx.compose.material.icons.outlined.Bolt
import androidx.compose.material.icons.outlined.GraphicEq
import androidx.compose.material.icons.outlined.Schedule
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.semanticcraft.koe.core.CaptureMode
import com.semanticcraft.koe.core.HostCommand
import com.semanticcraft.koe.core.HostSessionStore
import com.semanticcraft.koe.core.QuickNoteFilterSelection
import com.semanticcraft.koe.core.TimeLabel
import com.semanticcraft.koe.ui.components.KoeBadge
import com.semanticcraft.koe.ui.components.KoeCard
import com.semanticcraft.koe.ui.components.KoeEmptyState
import com.semanticcraft.koe.ui.components.KoeFilterChip
import com.semanticcraft.koe.ui.components.KoePrimaryButton
import com.semanticcraft.koe.ui.leaves.AndroidLiveMinutesCoverageSlot
import com.semanticcraft.koe.ui.theme.KoeFontSizes
import com.semanticcraft.koe.ui.theme.KoeTheme

enum class AndroidModeWorkspaceRoute(val title: String) {
    QUICK_NOTE(CaptureMode.QUICK_NOTE.title),
    ALL_DAY(CaptureMode.ALL_DAY.title),
    LIVE_MINUTES(CaptureMode.MEETING.title),
}

@Composable
fun ModeWorkspacesScreen(
    store: HostSessionStore,
    route: AndroidModeWorkspaceRoute,
    onSelectRecord: (String) -> Unit,
    modifier: Modifier = Modifier,
) {
    when (route) {
        AndroidModeWorkspaceRoute.QUICK_NOTE -> QuickNoteWorkspaceContent(store, onSelectRecord, modifier)
        AndroidModeWorkspaceRoute.ALL_DAY -> AllDayWorkspaceContent(store, onSelectRecord, modifier)
        AndroidModeWorkspaceRoute.LIVE_MINUTES -> LiveMinutesWorkspaceContent(store, onSelectRecord, modifier)
    }
}

@Composable
private fun QuickNoteWorkspaceContent(
    store: HostSessionStore,
    onSelectRecord: (String) -> Unit,
    modifier: Modifier = Modifier,
) {
    val workspace by store.quickNoteWorkspace.collectAsStateWithLifecycle()
    val colors = KoeTheme.colors
    var filter by remember { mutableStateOf<QuickNoteFilterSelection>(QuickNoteFilterSelection.All) }
    val filtered = workspace.filteredCards(filter)

    LazyColumn(
        modifier = modifier.fillMaxSize().background(colors.bgPanel),
        contentPadding = PaddingValues(16.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        item(key = "qn-summary") {
            KoeCard {
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.SpaceBetween,
                ) {
                    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                        Text(
                            text = "收件箱 ${workspace.inboxCount}  |  共 ${workspace.totalCount} 条",
                            color = colors.textPrimary,
                            fontSize = KoeFontSizes.sm,
                            fontWeight = FontWeight.SemiBold,
                        )
                        Text(text = workspace.sourceLabel, color = colors.textMuted, fontSize = KoeFontSizes.xs)
                    }
                    KoeBadge(
                        text = if (workspace.isActive) "记录中" else "就绪",
                        tint = if (workspace.isActive) colors.success else colors.textSecondary,
                    )
                }
            }
        }

        item(key = "qn-filters") {
            Row(
                modifier = Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                KoeFilterChip("全部", filter == QuickNoteFilterSelection.All, { filter = QuickNoteFilterSelection.All })
                KoeFilterChip(
                    "收件箱 (${workspace.inboxCount})",
                    filter == QuickNoteFilterSelection.Inbox,
                    { filter = QuickNoteFilterSelection.Inbox },
                )
                workspace.projects.forEach { project ->
                    val target = QuickNoteFilterSelection.Project(project.name)
                    KoeFilterChip("${project.name} (${project.count})", filter == target, { filter = target })
                }
            }
        }

        if (filtered.isEmpty()) {
            item(key = "qn-empty") {
                KoeEmptyState(Icons.Outlined.Bolt, "暂无随心闪记", "可在今天页输入文字闪记，或通过麦克风记录想法。")
            }
        } else {
            items(filtered, key = { it.id }) { card ->
                KoeCard(
                    modifier = Modifier.clickable {
                        store.send(HostCommand.SelectQuickNoteRecord(card.id))
                        onSelectRecord(card.id)
                    },
                ) {
                    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(8.dp),
                        ) {
                            Text(
                                text = card.title,
                                color = colors.textPrimary,
                                fontSize = KoeFontSizes.sm,
                                fontWeight = FontWeight.SemiBold,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
                                modifier = Modifier.weight(1f),
                            )
                            card.project?.takeIf { it.isNotBlank() }?.let {
                                KoeBadge(text = it, tint = colors.textSecondary)
                            }
                        }
                        card.gist?.takeIf { it.isNotBlank() }?.let {
                            Text(
                                text = it,
                                color = colors.textSecondary,
                                fontSize = KoeFontSizes.xs,
                                maxLines = 2,
                                overflow = TextOverflow.Ellipsis,
                            )
                        }
                        Text(
                            text = "${TimeLabel.date(card.createdAtEpochSec)}  |  ${card.status}",
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
private fun AllDayWorkspaceContent(
    store: HostSessionStore,
    onSelectRecord: (String) -> Unit,
    modifier: Modifier = Modifier,
) {
    val workspace by store.allDayWorkspace.collectAsStateWithLifecycle()
    val colors = KoeTheme.colors

    LazyColumn(
        modifier = modifier.fillMaxSize().background(colors.bgPanel),
        contentPadding = PaddingValues(16.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        item(key = "ad-summary") {
            KoeCard {
                Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.SpaceBetween,
                    ) {
                        Text(
                            text = workspace.selectedDate,
                            color = colors.textPrimary,
                            fontSize = KoeFontSizes.md,
                            fontWeight = FontWeight.SemiBold,
                        )
                        KoeBadge(
                            text = when {
                                workspace.isActive && workspace.isPaused -> "已暂停"
                                workspace.isActive -> "记录中"
                                else -> "待机"
                            },
                            tint = if (workspace.isActive) colors.success else colors.textSecondary,
                        )
                    }
                    Text(
                        text = "事件 ${workspace.eventCount}  |  已录 ${TimeLabel.duration(workspace.totalRecordedMs)}  |  空档 ${workspace.gapCount}",
                        color = colors.textMuted,
                        fontSize = KoeFontSizes.xs,
                    )
                    if (workspace.selectedDate.isNotBlank()) {
                        KoePrimaryButton(
                            title = "导出当日",
                            isPrimary = false,
                            onClick = {
                                store.bridgeActions.requestExportWorkspace(
                                    null,
                                    workspace.selectedDate,
                                    "Koe-${workspace.selectedDate}.md",
                                )
                            },
                            modifier = Modifier.testTag("all-day-export-button"),
                        )
                    }
                }
            }
        }

        if (workspace.availableDates.isNotEmpty()) {
            item(key = "ad-dates") {
                Row(
                    modifier = Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()),
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    workspace.availableDates.forEach { day ->
                        KoeFilterChip(day, day == workspace.selectedDate, { store.send(HostCommand.SelectAllDayDate(day)) })
                    }
                }
            }
        }

        if (workspace.spans.isEmpty()) {
            item(key = "ad-empty") {
                KoeEmptyState(Icons.Outlined.Schedule, "当日暂无时间线", "全天听记会按对话事件与空档自动整理当日回顾。")
            }
        } else {
            items(workspace.spans, key = { it.id }) { span ->
                KoeCard {
                    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(8.dp),
                        ) {
                            Text(
                                text = span.title ?: if (span.kind == "pause") "暂停区间" else "未录音空档",
                                color = colors.textPrimary,
                                fontSize = KoeFontSizes.sm,
                                fontWeight = FontWeight.SemiBold,
                                modifier = Modifier.weight(1f),
                            )
                            span.sliceBadgeText?.let { KoeBadge(text = it, tint = colors.textSecondary) }
                        }
                        Text(text = span.statusSummaryLabel(), color = colors.textMuted, fontSize = KoeFontSizes.xs)
                        if (span.preview.isNotEmpty()) {
                            Text(
                                text = span.preview,
                                color = colors.textSecondary,
                                fontSize = KoeFontSizes.xs,
                                maxLines = 3,
                                overflow = TextOverflow.Ellipsis,
                            )
                        }
                        (span.primaryRecordId ?: span.recordId)?.let { targetId ->
                            KoePrimaryButton(title = "打开记录", isPrimary = false, onClick = { onSelectRecord(targetId) })
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun LiveMinutesWorkspaceContent(
    store: HostSessionStore,
    onSelectRecord: (String) -> Unit,
    modifier: Modifier = Modifier,
) {
    val workspace by store.liveMinutesWorkspace.collectAsStateWithLifecycle()
    val colors = KoeTheme.colors
    val sections = workspace.finalSections.ifEmpty { workspace.liveSections }

    LazyColumn(
        modifier = modifier.fillMaxSize().background(colors.bgPanel),
        contentPadding = PaddingValues(16.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        item(key = "lm-header") {
            KoeCard {
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.SpaceBetween,
                ) {
                    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                        Text(
                            text = workspace.selectedTitle ?: "实时会议纪要",
                            color = colors.textPrimary,
                            fontSize = KoeFontSizes.md,
                            fontWeight = FontWeight.SemiBold,
                        )
                        Text(text = workspace.sourceLabel, color = colors.textMuted, fontSize = KoeFontSizes.xs)
                    }
                    KoeBadge(
                        text = workspace.phaseBadgeLabel,
                        tint = if (workspace.isActive) colors.success else colors.textSecondary,
                    )
                }
            }
        }

        item(key = "lm-coverage-slot") {
            AndroidLiveMinutesCoverageSlot(store = store)
        }

        if (sections.isNotEmpty()) {
            items(sections, key = { it.id }) { section ->
                KoeCard {
                    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                        Text(
                            text = section.title,
                            color = colors.textPrimary,
                            fontSize = KoeFontSizes.sm,
                            fontWeight = FontWeight.SemiBold,
                        )
                        Text(text = section.text, color = colors.textSecondary, fontSize = KoeFontSizes.xs)
                    }
                }
            }
        } else if (workspace.segments.isEmpty()) {
            item(key = "lm-empty") {
                KoeEmptyState(Icons.Outlined.GraphicEq, "暂无实时纪要", "开始实时纪要后，将边听边整理议题与待办。")
            }
        }

        if (workspace.pastMeetings.isNotEmpty()) {
            item(key = "lm-past-title") {
                Text(
                    text = "往期会议",
                    color = colors.textPrimary,
                    fontSize = KoeFontSizes.sm,
                    fontWeight = FontWeight.SemiBold,
                )
            }
            items(workspace.pastMeetings, key = { it.id }) { meeting ->
                KoeCard(
                    modifier = Modifier.clickable {
                        store.send(HostCommand.SelectLiveMinutesRecord(meeting.id))
                        onSelectRecord(meeting.id)
                    },
                ) {
                    Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                        Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                            Text(
                                text = meeting.title,
                                color = colors.textPrimary,
                                fontSize = KoeFontSizes.sm,
                                fontWeight = FontWeight.SemiBold,
                            )
                            Text(
                                text = "${TimeLabel.duration(meeting.durationMs)}  |  ${meeting.segmentCount} 段原文",
                                color = colors.textMuted,
                                fontSize = KoeFontSizes.xs,
                            )
                        }
                        Spacer(modifier = Modifier.size(8.dp))
                        Icon(
                            imageVector = Icons.AutoMirrored.Outlined.KeyboardArrowRight,
                            contentDescription = null,
                            tint = colors.textMuted,
                            modifier = Modifier.size(18.dp),
                        )
                    }
                }
            }
        }
    }
}
