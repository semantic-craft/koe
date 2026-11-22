package com.semanticcraft.koe.ui.screens

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.selection.toggleable
import androidx.compose.material3.Checkbox
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.semanticcraft.koe.core.CaptureMode
import com.semanticcraft.koe.core.HostCommand
import com.semanticcraft.koe.core.HostSessionStore
import com.semanticcraft.koe.core.ReviewDecision
import com.semanticcraft.koe.core.SegmentSnapshot
import com.semanticcraft.koe.core.SourceSnapshot
import com.semanticcraft.koe.core.TimeLabel
import com.semanticcraft.koe.core.WorkspaceExportOptions
import com.semanticcraft.koe.core.WorkspaceSourcedItemSnapshot
import com.semanticcraft.koe.ui.components.KoeBadge
import com.semanticcraft.koe.ui.components.KoeCard
import com.semanticcraft.koe.ui.components.KoePrimaryButton
import com.semanticcraft.koe.ui.components.KoeSourceLink
import com.semanticcraft.koe.ui.components.StableList
import com.semanticcraft.koe.ui.leaves.WorkspaceCaptureActions
import com.semanticcraft.koe.ui.theme.KoeFontSizes
import com.semanticcraft.koe.ui.theme.KoeTheme

@Composable
internal fun WorkspaceList(modifier: Modifier = Modifier, content: LazyListScope.() -> Unit) {
    LazyColumn(
        modifier = modifier.fillMaxSize(),
        contentPadding = PaddingValues(16.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
        content = content,
    )
}

@Composable
internal fun WorkspaceTitle(text: String, modifier: Modifier = Modifier) {
    Text(text, modifier, color = KoeTheme.colors.textPrimary, fontSize = KoeFontSizes.md, fontWeight = FontWeight.SemiBold)
}

@Composable
internal fun WorkspaceHeader(
    store: HostSessionStore, mode: CaptureMode, title: String, source: String, status: String,
    isActive: Boolean, canStart: Boolean, onOpenCaptureSource: () -> Unit,
) {
    KoeCard {
        Row(verticalAlignment = Alignment.CenterVertically) {
            WorkspaceTitle(title, Modifier.weight(1f))
            KoeBadge(status, tint = if (isActive) KoeTheme.colors.success else KoeTheme.colors.textSecondary)
        }
        KoePrimaryButton(source, onOpenCaptureSource, Modifier.testTag("workspace-source-button"), isPrimary = false)
        if (isActive) {
            WorkspaceCaptureActions(store, mode)
        } else {
            KoePrimaryButton("开始" + mode.title, { store.startCapture(mode, stayOnPage = true) },
                enabled = canStart)
        }
    }
}

@Composable
internal fun WorkspaceExport(
    store: HostSessionStore, recordId: String?, date: String?, filename: String, title: String, tag: String,
) {
    var analysis by rememberSaveable(recordId, date) { mutableStateOf(true) }
    var sources by rememberSaveable(recordId, date) { mutableStateOf(true) }
    KoeCard {
        ExportSwitch("附带 AI 分析", analysis) { analysis = it }
        ExportSwitch("附带来源引用", sources) { sources = it }
        KoePrimaryButton(title, {
            store.bridgeActions.requestExportWorkspace(recordId, date, filename, WorkspaceExportOptions(analysis, sources))
        }, Modifier.testTag(tag), isPrimary = false)
    }
}

@Composable
private fun ExportSwitch(title: String, checked: Boolean, onChange: (Boolean) -> Unit) {
    Row(Modifier.fillMaxWidth().toggleable(checked, role = Role.Switch, onValueChange = onChange)
        .padding(vertical = 6.dp), verticalAlignment = Alignment.CenterVertically) {
        Text(title, Modifier.weight(1f))
        Switch(checked, onCheckedChange = null)
    }
}

@Composable
internal fun WorkspaceSources(sources: StableList<SourceSnapshot>, onOpenSource: (SourceSnapshot) -> Unit, tag: String = "item") {
    sources.items.forEach { source ->
        KoeSourceLink(source, { onOpenSource(source) }, Modifier.testTag(tag + "-source-" + source.id))
    }
}

@Composable
internal fun WorkspaceReviewRow(store: HostSessionStore, item: WorkspaceSourcedItemSnapshot, onOpenSource: (SourceSnapshot) -> Unit) {
    KoeCard {
        val status = when (item.state) {
            "proposed" -> "待确认"
            "accepted" -> if (item.completed) "已完成" else "已采纳"
            "dismissed" -> "已忽略"
            else -> item.state
        }
        KoeBadge((if (item.kind == "task") "待办" else "记忆") + "  |  " + status)
        Text(item.text)
        item.due?.let { Text(it, color = KoeTheme.colors.textSecondary) }
        WorkspaceSources(StableList(item.sources), onOpenSource)
        if (item.kind == "task" && item.state == "accepted") {
            Row(Modifier.testTag("complete-" + item.id).toggleable(item.completed, role = Role.Checkbox) {
                store.send(HostCommand.CompleteTask(item.id, it))
            }.padding(vertical = 8.dp), verticalAlignment = Alignment.CenterVertically) {
                Checkbox(item.completed, onCheckedChange = null)
                Text("已完成", Modifier.padding(start = 8.dp))
            }
        }
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            if (item.state == "proposed") {
                ReviewButton(store, item.id, ReviewDecision.ACCEPT, "采纳")
                ReviewButton(store, item.id, ReviewDecision.DISMISS, "忽略")
            } else if (item.state == "accepted" || item.state == "dismissed") {
                ReviewButton(store, item.id, ReviewDecision.RESET, "重新审核")
            }
        }
    }
}

@Composable
private fun ReviewButton(store: HostSessionStore, id: String, decision: ReviewDecision, label: String) {
    KoePrimaryButton(label, { store.send(HostCommand.ReviewItem(id, decision)) },
        Modifier.testTag("review-" + decision.name.lowercase() + "-" + id), isPrimary = decision == ReviewDecision.ACCEPT)
}

@Composable
internal fun TranscriptSegment(segment: SegmentSnapshot) {
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Text(listOfNotNull(segment.speaker, TimeLabel.duration(segment.startMs)).joinToString("  |  "),
            color = KoeTheme.colors.textMuted, fontSize = KoeFontSizes.xs)
        Text(segment.text)
    }
}
