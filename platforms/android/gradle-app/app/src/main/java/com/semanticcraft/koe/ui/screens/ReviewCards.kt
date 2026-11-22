package com.semanticcraft.koe.ui.screens

import androidx.compose.ui.platform.testTag
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.CheckCircle
import androidx.compose.material.icons.outlined.RadioButtonUnchecked
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.unit.dp
import com.semanticcraft.koe.core.ReviewDecision
import com.semanticcraft.koe.core.HostCommand
import com.semanticcraft.koe.core.HostSessionStore
import com.semanticcraft.koe.core.MemorySnapshot
import com.semanticcraft.koe.core.SourceSnapshot
import com.semanticcraft.koe.core.TaskSnapshot
import com.semanticcraft.koe.ui.components.KoeBadge
import com.semanticcraft.koe.ui.components.KoeCard
import com.semanticcraft.koe.ui.components.KoePrimaryButton
import com.semanticcraft.koe.ui.components.KoeSourceLink
import com.semanticcraft.koe.ui.components.StableList
import com.semanticcraft.koe.ui.theme.KoeFontSizes
import com.semanticcraft.koe.ui.theme.KoeTheme

@Composable
internal fun TaskItemCard(
    task: TaskSnapshot,
    store: HostSessionStore,
    onOpenSource: (SourceSnapshot) -> Unit,
) {
    val colors = KoeTheme.colors
    KoeCard {
        Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.Top,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                if (task.state == "accepted") {
                    IconButton(
                        onClick = { store.send(HostCommand.CompleteTask(task.id, !task.completed)) },
                        modifier = Modifier.size(32.dp),
                    ) {
                        Icon(
                            imageVector = if (task.completed) Icons.Outlined.CheckCircle else Icons.Outlined.RadioButtonUnchecked,
                            contentDescription = if (task.completed) "标记未完成" else "标记已完成",
                            tint = if (task.completed) colors.success else colors.textMuted,
                            modifier = Modifier.size(20.dp),
                        )
                    }
                }

                Column(
                    modifier = Modifier.weight(1f),
                    verticalArrangement = Arrangement.spacedBy(4.dp),
                ) {
                    Text(
                        text = task.text,
                        color = colors.textPrimary,
                        fontSize = KoeFontSizes.sm,
                        fontWeight = FontWeight.Medium,
                        textDecoration = if (task.completed) TextDecoration.LineThrough else TextDecoration.None,
                    )
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                    ) {
                        ReviewStateBadge(task.state, "已采纳")
                        val due = task.due
                        if (!due.isNullOrBlank()) {
                            Text(
                                text = "截止 $due",
                                color = colors.textMuted,
                                fontSize = KoeFontSizes.xs,
                            )
                        }
                    }
                }
            }

            ReviewControls(store, task.id, task.text, task.state, task.due.orEmpty())

            ReviewSources(StableList(task.sources), onOpenSource)
        }
    }
}

@Composable
internal fun MemoryItemCard(
    memory: MemorySnapshot,
    store: HostSessionStore,
    onOpenSource: (SourceSnapshot) -> Unit,
) {
    val colors = KoeTheme.colors
    KoeCard {
        Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.Top,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                Text(
                    text = memory.text,
                    color = colors.textPrimary,
                    fontSize = KoeFontSizes.sm,
                    modifier = Modifier.weight(1f),
                )
                ReviewStateBadge(memory.state, "已记住")
            }

            ReviewControls(store, memory.id, memory.text, memory.state, null)

            ReviewSources(StableList(memory.sources), onOpenSource)
        }
    }
}

@Composable
private fun ReviewStateBadge(state: String, accepted: String) {
    val colors = KoeTheme.colors
    when (state) {
        "proposed" -> KoeBadge("待确认", tint = colors.warning)
        "accepted" -> KoeBadge(accepted, tint = colors.success)
        "dismissed" -> KoeBadge("已忽略", tint = colors.textMuted)
        else -> KoeBadge(state, tint = colors.textMuted)
    }
}

@Composable
private fun ReviewSources(sources: StableList<SourceSnapshot>, onOpenSource: (SourceSnapshot) -> Unit) {
    if (sources.items.isEmpty()) return
    Row(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        sources.items.forEach { source -> KoeSourceLink(source, { onOpenSource(source) }) }
    }
}

@Composable
private fun ReviewControls(store: HostSessionStore, id: String, text: String, state: String, due: String?) {
    var editing by rememberSaveable(id) { mutableStateOf(false) }
    Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        if (state == "proposed") {
            KoePrimaryButton(if (due == null) "记住" else "采纳", {
                store.send(HostCommand.ReviewItem(id, ReviewDecision.ACCEPT))
            }, Modifier.testTag("review-accept-$id"))
        }
        if (state == "proposed" || (due == null && state == "accepted")) {
            KoePrimaryButton("忽略", { store.send(HostCommand.ReviewItem(id, ReviewDecision.DISMISS)) }, Modifier.testTag("review-dismiss-$id"), isPrimary = false)
        }
        if (state == "accepted" || state == "dismissed") {
            KoePrimaryButton("重新审核", { store.send(HostCommand.ReviewItem(id, ReviewDecision.RESET)) }, Modifier.testTag("review-reset-$id"), isPrimary = false)
        }
        KoePrimaryButton("编辑", { editing = true }, Modifier.testTag("review-edit-$id"), isPrimary = false)
    }
    if (editing) ItemEditorSheet(store, id, text, due) { editing = false }
}

@Composable
private fun ItemEditorSheet(store: HostSessionStore, id: String, text: String, due: String?, onDismiss: () -> Unit) {
    var dueDraft by rememberSaveable(id) { mutableStateOf(due) }
    TextEditorDialog("编辑内容", text, onDismiss, { value ->
        store.sendReturningError(HostCommand.EditItem(id, value, dueDraft?.trim()?.ifBlank { null })) == null
    }, due = dueDraft, onDueChange = { dueDraft = it })
}
