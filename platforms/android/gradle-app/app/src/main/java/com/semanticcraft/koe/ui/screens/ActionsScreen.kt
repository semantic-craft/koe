package com.semanticcraft.koe.ui.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Check
import androidx.compose.material.icons.outlined.CheckCircle
import androidx.compose.material.icons.outlined.Checklist
import androidx.compose.material.icons.outlined.Close
import androidx.compose.material.icons.outlined.Psychology
import androidx.compose.material.icons.outlined.RadioButtonUnchecked
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
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
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.semanticcraft.koe.core.HostCommand
import com.semanticcraft.koe.core.HostSessionStore
import com.semanticcraft.koe.core.MemorySnapshot
import com.semanticcraft.koe.core.SourceSnapshot
import com.semanticcraft.koe.core.TaskSnapshot
import com.semanticcraft.koe.ui.components.KoeBadge
import com.semanticcraft.koe.ui.components.KoeCard
import com.semanticcraft.koe.ui.components.KoeEmptyState
import com.semanticcraft.koe.ui.components.KoePrimaryButton
import com.semanticcraft.koe.ui.components.KoeSourceLink
import com.semanticcraft.koe.ui.theme.KoeFontSizes
import com.semanticcraft.koe.ui.theme.KoeTheme

private enum class ActionsSegment(val label: String) {
    TASKS("待办"),
    MEMORIES("记忆"),
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ActionsScreen(
    store: HostSessionStore,
    onOpenSource: (SourceSnapshot) -> Unit,
    modifier: Modifier = Modifier,
) {
    val tasks by store.tasks.collectAsStateWithLifecycle()
    val memories by store.memories.collectAsStateWithLifecycle()
    val colors = KoeTheme.colors
    var selectedSegment by rememberSaveable { mutableStateOf(ActionsSegment.TASKS) }

    val activeTasks = tasks.filter { it.state != "dismissed" }
    val activeMemories = memories.filter { it.state != "dismissed" }

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
            ActionsSegment.entries.forEachIndexed { index, segment ->
                SegmentedButton(
                    selected = selectedSegment == segment,
                    onClick = { selectedSegment = segment },
                    shape = SegmentedButtonDefaults.itemShape(index = index, count = ActionsSegment.entries.size),
                    colors = SegmentedButtonDefaults.colors(
                        activeContainerColor = colors.accent,
                        activeContentColor = colors.onAccent,
                        inactiveContainerColor = colors.surface1,
                        inactiveContentColor = colors.textSecondary,
                        activeBorderColor = colors.accent,
                        inactiveBorderColor = colors.border,
                    ),
                ) {
                    Text(text = segment.label, fontSize = KoeFontSizes.xs, fontWeight = FontWeight.Medium)
                }
            }
        }

        LazyColumn(
            modifier = Modifier.fillMaxSize(),
            contentPadding = PaddingValues(start = 16.dp, end = 16.dp, bottom = 16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            when (selectedSegment) {
                ActionsSegment.TASKS -> {
                    if (activeTasks.isEmpty()) {
                        item(key = "tasks-empty") {
                            KoeEmptyState(
                                icon = Icons.Outlined.Checklist,
                                title = "暂无待办事项",
                                detail = "会议纪要或原文中提取的待办会汇总到这里供你确认。",
                            )
                        }
                    } else {
                        items(activeTasks, key = { it.id }) { task ->
                            TaskItemCard(
                                task = task,
                                store = store,
                                onOpenSource = onOpenSource,
                            )
                        }
                    }
                }

                ActionsSegment.MEMORIES -> {
                    if (activeMemories.isEmpty()) {
                        item(key = "memories-empty") {
                            KoeEmptyState(
                                icon = Icons.Outlined.Psychology,
                                title = "暂无记忆条目",
                                detail = "需要长期记住的事实与约定会保留来源出处。",
                            )
                        }
                    } else {
                        items(activeMemories, key = { it.id }) { memory ->
                            MemoryItemCard(
                                memory = memory,
                                store = store,
                                onOpenSource = onOpenSource,
                            )
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun TaskItemCard(
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
                        KoeBadge(
                            text = if (task.state == "proposed") "待确认" else "已采纳",
                            tint = if (task.state == "proposed") colors.warning else colors.success,
                        )
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

            if (task.state == "proposed") {
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    KoePrimaryButton(
                        title = "采纳",
                        icon = Icons.Outlined.Check,
                        isPrimary = true,
                        onClick = { store.send(HostCommand.ReviewItem(task.id, "accepted")) },
                    )
                    KoePrimaryButton(
                        title = "忽略",
                        icon = Icons.Outlined.Close,
                        isPrimary = false,
                        onClick = { store.send(HostCommand.ReviewItem(task.id, "dismissed")) },
                    )
                }
            }

            if (task.sources.isNotEmpty()) {
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .horizontalScroll(rememberScrollState()),
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    task.sources.forEach { source ->
                        KoeSourceLink(source = source, onClick = { onOpenSource(source) })
                    }
                }
            }
        }
    }
}

@Composable
private fun MemoryItemCard(
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
                KoeBadge(
                    text = if (memory.state == "proposed") "待确认" else "已记住",
                    tint = if (memory.state == "proposed") colors.warning else colors.success,
                )
            }

            if (memory.state == "proposed") {
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    KoePrimaryButton(
                        title = "记住",
                        icon = Icons.Outlined.Check,
                        isPrimary = true,
                        onClick = { store.send(HostCommand.ReviewItem(memory.id, "accepted")) },
                    )
                    KoePrimaryButton(
                        title = "忽略",
                        icon = Icons.Outlined.Close,
                        isPrimary = false,
                        onClick = { store.send(HostCommand.ReviewItem(memory.id, "dismissed")) },
                    )
                }
            }

            if (memory.sources.isNotEmpty()) {
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .horizontalScroll(rememberScrollState()),
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    memory.sources.forEach { source ->
                        KoeSourceLink(source = source, onClick = { onOpenSource(source) })
                    }
                }
            }
        }
    }
}
