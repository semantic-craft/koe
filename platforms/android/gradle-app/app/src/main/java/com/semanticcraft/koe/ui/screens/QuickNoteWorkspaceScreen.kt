package com.semanticcraft.koe.ui.screens

import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.material3.Checkbox
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.semanticcraft.koe.core.CaptureMode
import com.semanticcraft.koe.core.HostCommand
import com.semanticcraft.koe.core.HostSessionStore
import com.semanticcraft.koe.core.QuickNoteCardSnapshot
import com.semanticcraft.koe.core.QuickNoteFilterSelection
import com.semanticcraft.koe.core.QuickNoteProjectCountSnapshot
import com.semanticcraft.koe.core.SourceSnapshot
import com.semanticcraft.koe.core.TimeLabel
import com.semanticcraft.koe.ui.components.KoeCard
import com.semanticcraft.koe.ui.components.KoeFilterChip
import com.semanticcraft.koe.ui.components.KoeModalSheet
import com.semanticcraft.koe.ui.components.KoePrimaryButton
import com.semanticcraft.koe.ui.theme.KoeTheme

@Composable
internal fun QuickNoteWorkspaceScreen(
    store: HostSessionStore, onSelectRecord: (String) -> Unit, onOpenSource: (SourceSnapshot) -> Unit,
    onOpenCaptureSource: () -> Unit, modifier: Modifier,
) {
    val workspace by store.quickNoteWorkspace.collectAsStateWithLifecycle()
    var filter by remember { mutableStateOf<QuickNoteFilterSelection>(QuickNoteFilterSelection.All) }
    var selection by remember(filter) { mutableStateOf<Set<String>?>(null) }
    var assignIds by remember(filter) { mutableStateOf<List<String>?>(null) }
    val cards = workspace.filteredCards(filter)
    val inspected = workspace.resolvedSelectedCard(filter)
    val selectedIds = cards.map { it.id }.filter { selection?.contains(it) == true }
    LaunchedEffect(workspace.projects) {
        val project = filter as? QuickNoteFilterSelection.Project
        if (project != null && workspace.projects.none { it.name == project.name }) filter = QuickNoteFilterSelection.All
    }
    WorkspaceList(modifier) {
        item {
            WorkspaceHeader(store, CaptureMode.QUICK_NOTE, "收件箱 ${workspace.inboxCount}  |  共 ${workspace.totalCount} 条",
                workspace.sourceLabel, if (workspace.isActive) "记录中" else "就绪",
                workspace.isActive, workspace.canStart, onOpenCaptureSource)
        }
        item { QuickNoteComposer(store) }
        item {
            Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                KoeFilterChip("全部", filter == QuickNoteFilterSelection.All, { filter = QuickNoteFilterSelection.All })
                KoeFilterChip("收件箱 (${workspace.inboxCount})", filter == QuickNoteFilterSelection.Inbox,
                    { filter = QuickNoteFilterSelection.Inbox })
                workspace.projects.forEach { project ->
                    val target = QuickNoteFilterSelection.Project(project.name)
                    KoeFilterChip("${project.name} (${project.count})", filter == target, { filter = target })
                }
            }
        }
        item {
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                KoePrimaryButton(if (selection == null) "批量归类" else "取消多选", {
                    selection = if (selection == null) emptySet() else null
                }, isPrimary = false)
                if (selection != null) KoePrimaryButton("归类所选", { assignIds = selectedIds }, enabled = selectedIds.isNotEmpty())
            }
        }
        if (cards.isEmpty()) item { Text("此分类暂无闪记") }
        cards.forEach { card ->
            item(key = "card-" + card.id) {
                KoeCard {
                    Row(Modifier.fillMaxWidth().clickable {
                        val ids = selection
                        if (ids == null) store.send(HostCommand.SelectQuickNoteRecord(card.id))
                        else selection = if (card.id in ids) ids - card.id else ids + card.id
                    }.padding(vertical = 8.dp), verticalAlignment = Alignment.CenterVertically) {
                        Column(Modifier.weight(1f)) {
                            WorkspaceTitle(card.title)
                            Text(listOf(TimeLabel.date(card.createdAtEpochSec), card.project ?: "收件箱", card.status)
                                .filter { it.isNotBlank() }.joinToString("  |  "), color = KoeTheme.colors.textSecondary)
                        }
                        selection?.let { Checkbox(card.id in it, onCheckedChange = null) }
                    }
                    if (selection == null) KoePrimaryButton("项目归类", { assignIds = listOf(card.id) },
                        Modifier.testTag("assign-" + card.id), isPrimary = false)
                }
            }
            if (selection == null && inspected?.id == card.id) quickNoteDetail(card, store, onSelectRecord, onOpenSource)
        }
    }
    assignIds?.let { targets ->
        ProjectSheet(workspace.projects, onDismiss = { assignIds = null }) { project ->
            val ids = cards.map { it.id }.filter { it in targets }
            if (ids.isNotEmpty()) {
                val command = if (selection == null) HostCommand.SetRecordProject(ids.single(), project)
                    else HostCommand.BatchSetRecordProject(ids, project)
                if (store.sendReturningError(command) == null) selection = null
            }
            assignIds = null
        }
    }
}

private fun LazyListScope.quickNoteDetail(
    card: QuickNoteCardSnapshot, store: HostSessionStore, onSelectRecord: (String) -> Unit,
    onOpenSource: (SourceSnapshot) -> Unit,
) {
    item { WorkspaceTitle("原文") }
    items(card.segments, key = { "segment-${card.id}-${it.id}" }) { TranscriptSegment(it) }
    if (card.segments.isEmpty()) item { Text("暂无原文") }
    item {
        WorkspaceTitle("AI 分析")
        card.gist?.let { Text(it) }
        if (card.gist.isNullOrBlank() && card.topics.isEmpty()) Text("尚未生成分析")
    }
    items(card.topics) { topic ->
        KoeCard {
            WorkspaceTitle(topic.title)
            Text(topic.summary)
            WorkspaceSources(topic.sources, onOpenSource, "topic")
        }
    }
    if (card.nextSteps.isNotEmpty()) item { WorkspaceTitle("下一步") }
    items(card.nextSteps, key = { "step-" + it.id }) { WorkspaceReviewRow(store, it, onOpenSource) }
    item {
        if (card.minutesStale) Text("原文已有更新，分析需要重新整理。")
        if (card.canSummarize) KoePrimaryButton("重新整理", { store.send(HostCommand.Summarize(card.id)) })
        KoePrimaryButton("打开详情", { onSelectRecord(card.id) }, isPrimary = false)
    }
    item(key = "export-" + card.id) {
        WorkspaceExport(store, card.id, null, "${card.title}.md", "导出闪记 Markdown", "note-export-button")
    }
}

@Composable
private fun ProjectSheet(projects: List<QuickNoteProjectCountSnapshot>, onDismiss: () -> Unit, assign: (String?) -> Unit) {
    var name by rememberSaveable { mutableStateOf("") }
    KoeModalSheet(onDismiss) {
        WorkspaceTitle("项目归类")
        TextButton({ assign(null) }) { Text("移回收件箱") }
        projects.forEach { project ->
            TextButton({ assign(project.name) }) { Text(project.name) }
        }
        OutlinedTextField(name, { name = it }, label = { Text("新项目名称") }, singleLine = true,
            modifier = Modifier.fillMaxWidth().testTag("project-name"))
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            KoePrimaryButton("使用新项目", { assign(name.trim()) }, Modifier.testTag("project-confirm"), enabled = name.isNotBlank())
            KoePrimaryButton("取消", onDismiss, isPrimary = false)
        }
    }
}
