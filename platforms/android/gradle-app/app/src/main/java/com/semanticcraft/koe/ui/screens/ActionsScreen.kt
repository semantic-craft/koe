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
import androidx.compose.material.icons.outlined.Checklist
import androidx.compose.material.icons.outlined.Psychology
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.semanticcraft.koe.core.HostSessionStore
import com.semanticcraft.koe.core.SourceSnapshot
import com.semanticcraft.koe.ui.components.KoeFilterChip
import com.semanticcraft.koe.ui.components.KoeEmptyState
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

    var filter by rememberSaveable(selectedSegment) { mutableStateOf("活跃") }
    val activeTasks = tasks.filter {
        when (filter) {
            "已忽略" -> it.state == "dismissed"
            "已完成" -> it.completed && it.state == "accepted"
            "待处理" -> !it.completed && it.state != "dismissed"
            else -> it.state != "dismissed"
        }
    }
    val activeMemories = memories.filter {
        when (filter) {
            "已忽略" -> it.state == "dismissed"
            "已记住" -> it.state == "accepted"
            "待确认" -> it.state == "proposed"
            else -> it.state != "dismissed"
        }
    }

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

        Row(Modifier.horizontalScroll(rememberScrollState()).padding(horizontal = 16.dp, vertical = 4.dp),
            horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            val labels = if (selectedSegment == ActionsSegment.TASKS) listOf("活跃", "待处理", "已完成", "已忽略")
                else listOf("活跃", "待确认", "已记住", "已忽略")
            labels.forEach { label -> KoeFilterChip(label, filter == label, { filter = label }) }
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
