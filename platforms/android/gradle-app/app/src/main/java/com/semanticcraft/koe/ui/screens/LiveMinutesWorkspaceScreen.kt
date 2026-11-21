package com.semanticcraft.koe.ui.screens

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.GraphicEq
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
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
import com.semanticcraft.koe.ui.components.KoeInfoTip
import com.semanticcraft.koe.ui.components.KoePrimaryButton
import com.semanticcraft.koe.ui.leaves.AndroidLiveMinutesCoverageSlot
import com.semanticcraft.koe.ui.theme.KoeTheme

@Composable
internal fun LiveMinutesWorkspaceScreen(
    store: HostSessionStore, onSelectRecord: (String) -> Unit, onOpenSource: (SourceSnapshot) -> Unit,
    onOpenCaptureSource: () -> Unit, onOpenSettings: () -> Unit, modifier: Modifier,
) {
    val workspace by store.liveMinutesWorkspace.collectAsStateWithLifecycle()
    val recordId = workspace.selectedRecordId
    val title = workspace.selectedTitle ?: "当前会议"
    val hasFinal = workspace.finalSections.isNotEmpty()
    var showFinal by rememberSaveable(recordId, hasFinal) { mutableStateOf(hasFinal) }
    val sections = if (showFinal) workspace.finalSections else workspace.liveSections
    WorkspaceList(modifier) {
        item {
            WorkspaceHeader(store, CaptureMode.MEETING, title, workspace.sourceLabel, workspace.phaseBadgeLabel,
                workspace.isActive, workspace.canStart, onOpenCaptureSource)
        }
        workspace.error?.takeIf { it.isNotBlank() }?.let { error ->
            item { KoeCard { Text(error, color = KoeTheme.colors.danger) } }
        }
        if (!workspace.configured) item {
            KoeCard {
                WorkspaceTitle("未配置模型")
                Text("实时原文会继续保存。配置文字模型后即可整理会议纪要。")
                KoePrimaryButton("配置模型", onOpenSettings)
            }
        }
        item {
            Row(verticalAlignment = Alignment.CenterVertically) {
                WorkspaceTitle("实时覆盖率")
                KoeInfoTip("覆盖率", "转写覆盖率按已转写的录音时长计算，纪要覆盖率按已引用的原文段落计算。会后整理会生成终版纪要。")
            }
            AndroidLiveMinutesCoverageSlot(store)
        }
        item {
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                KoeFilterChip("实时纪要草稿", !showFinal, { showFinal = false })
                if (hasFinal) KoeFilterChip("终版纪要", showFinal, { showFinal = true })
            }
        }
        if (workspace.minutesStale && workspace.canSummarize && recordId != null) item {
            KoeCard {
                Text("原文已有更新，纪要需要重新生成。")
                KoePrimaryButton("重新生成", { store.send(HostCommand.Summarize(recordId)) })
            }
        }
        items(sections) { section ->
            KoeCard {
                WorkspaceTitle(section.title)
                Text(section.text)
                WorkspaceSources(section.sources, onOpenSource, "minutes")
            }
        }
        if (sections.isEmpty()) item {
            KoeEmptyState(Icons.Outlined.GraphicEq, "暂无实时纪要", "开始会议后，可在这里查看议题与待办。")
        }
        item { WorkspaceTitle("实时原文") }
        items(workspace.segments, key = { "segment-" + it.id }) { TranscriptSegment(it) }
        items(workspace.drafts) { draft ->
            KoeCard {
                KoeBadge("识别中")
                Text(draft)
            }
        }
        if (workspace.segments.isEmpty() && workspace.drafts.isEmpty()) item { Text("暂无会议原文") }
        if (workspace.actionItems.isNotEmpty()) item { WorkspaceTitle("行动项审核") }
        items(workspace.actionItems, key = { "action-" + it.id }) { WorkspaceReviewRow(store, it, onOpenSource) }
        if (recordId != null) {
            item { KoePrimaryButton("打开详情", { onSelectRecord(recordId) }, isPrimary = false) }
            item { WorkspaceExport(store, recordId, null, "$title.md", "导出会议 Markdown", "meeting-export-button") }
        }
        if (workspace.pastMeetings.isNotEmpty()) item { WorkspaceTitle("往期会议") }
        items(workspace.pastMeetings, key = { "meeting-" + it.id }) { meeting ->
            KoeCard(Modifier.clickable(enabled = !workspace.isActive) {
                store.send(HostCommand.SelectLiveMinutesRecord(meeting.id))
            }) {
                WorkspaceTitle(meeting.title)
                Text("${TimeLabel.duration(meeting.durationMs)}  |  ${meeting.segmentCount} 段原文")
            }
        }
    }
}
