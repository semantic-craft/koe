package com.semanticcraft.koe.ui.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
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
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Clear
import androidx.compose.material.icons.outlined.DeleteOutline
import androidx.compose.material.icons.outlined.Inbox
import androidx.compose.material.icons.outlined.Restore
import androidx.compose.material.icons.outlined.Search
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.SwipeToDismissBox
import androidx.compose.material3.SwipeToDismissBoxValue
import androidx.compose.material3.Text
import androidx.compose.material3.rememberSwipeToDismissBoxState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.semanticcraft.koe.core.HostCommand
import com.semanticcraft.koe.core.HostSessionStore
import com.semanticcraft.koe.core.RecordFilterCategory
import com.semanticcraft.koe.core.RecordSnapshot
import com.semanticcraft.koe.core.TimeLabel
import com.semanticcraft.koe.core.TrashRecordSnapshot
import com.semanticcraft.koe.core.matches
import com.semanticcraft.koe.ui.components.KoeBadge
import com.semanticcraft.koe.ui.components.KoeCard
import com.semanticcraft.koe.ui.components.KoeEmptyState
import com.semanticcraft.koe.ui.components.KoeFilterChip
import com.semanticcraft.koe.ui.components.KoeModalSheet
import com.semanticcraft.koe.ui.components.KoePrimaryButton
import com.semanticcraft.koe.ui.theme.KoeFontSizes
import com.semanticcraft.koe.ui.theme.KoeShapes
import com.semanticcraft.koe.ui.theme.KoeTheme

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun RecordsScreen(
    store: HostSessionStore,
    onSelectRecord: (String) -> Unit,
    modifier: Modifier = Modifier,
) {
    val records by store.records.collectAsStateWithLifecycle()
    val navigation by store.navigation.collectAsStateWithLifecycle()
    val trashRecords by store.trashRecords.collectAsStateWithLifecycle()
    val colors = KoeTheme.colors
    val focusManager = LocalFocusManager.current
    val keyboardController = LocalSoftwareKeyboardController.current

    var searchQuery by rememberSaveable { mutableStateOf("") }
    var filterCategory by rememberSaveable { mutableStateOf(RecordFilterCategory.ALL) }
    var showTrashSheet by rememberSaveable { mutableStateOf(false) }

    val filteredRecords = records.filter { it.matches(filter = filterCategory, query = searchQuery) }

    Column(
        modifier = modifier
            .fillMaxSize()
            .background(colors.bgPanel),
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 16.dp, vertical = 12.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            OutlinedTextField(
                value = searchQuery,
                onValueChange = { searchQuery = it },
                placeholder = {
                    Text(
                        text = "搜索记录标题或内容…",
                        fontSize = KoeFontSizes.sm,
                        color = colors.textMuted,
                    )
                },
                leadingIcon = {
                    Icon(
                        imageVector = Icons.Outlined.Search,
                        contentDescription = null,
                        tint = colors.textMuted,
                        modifier = Modifier.size(18.dp),
                    )
                },
                trailingIcon = {
                    if (searchQuery.isNotEmpty()) {
                        IconButton(onClick = { searchQuery = "" }) {
                            Icon(
                                imageVector = Icons.Outlined.Clear,
                                contentDescription = "清空搜索",
                                tint = colors.textMuted,
                                modifier = Modifier.size(18.dp),
                            )
                        }
                    }
                },
                singleLine = true,
                shape = KoeShapes.control,
                colors = OutlinedTextFieldDefaults.colors(
                    focusedBorderColor = colors.accent,
                    unfocusedBorderColor = colors.border,
                    focusedContainerColor = colors.surface1,
                    unfocusedContainerColor = colors.surface1,
                    focusedTextColor = colors.textPrimary,
                    unfocusedTextColor = colors.textPrimary,
                ),
                keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search),
                keyboardActions = KeyboardActions(
                    onSearch = {
                        focusManager.clearFocus()
                        keyboardController?.hide()
                    },
                ),
                modifier = Modifier
                    .fillMaxWidth()
                    .testTag("records-search-input"),
            )

            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .horizontalScroll(rememberScrollState()),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                RecordFilterCategory.entries.forEach { category ->
                    KoeFilterChip(
                        label = category.title,
                        selected = filterCategory == category,
                        onClick = { filterCategory = category },
                    )
                }
            }

            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                Text(
                    text = "共 ${filteredRecords.size} 条记录",
                    color = colors.textMuted,
                    fontSize = KoeFontSizes.xs,
                    maxLines = 1,
                )
                Box(
                    modifier = Modifier.weight(1f),
                    contentAlignment = Alignment.CenterEnd,
                ) {
                    Row(
                        modifier = Modifier.horizontalScroll(rememberScrollState()),
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        KoePrimaryButton(
                            title = "导入",
                            isPrimary = false,
                            onClick = { store.bridgeActions.requestImportFile() },
                            modifier = Modifier.testTag("records-import-button"),
                        )
                        if (filteredRecords.isNotEmpty()) {
                            KoePrimaryButton(
                                title = "导出",
                                isPrimary = false,
                                onClick = { store.bridgeActions.requestExportRecords(filteredRecords.map { it.id }) },
                                modifier = Modifier.testTag("records-export-batch-button"),
                            )
                        }
                        KoePrimaryButton(
                            title = if (navigation.trashCount > 0) "回收站 (${navigation.trashCount})" else "回收站",
                            icon = Icons.Outlined.DeleteOutline,
                            isPrimary = false,
                            onClick = { showTrashSheet = true },
                            modifier = Modifier.testTag("records-trash-button"),
                        )
                    }
                }
            }
        }

        if (filteredRecords.isEmpty()) {
            KoeEmptyState(
                icon = Icons.Outlined.Inbox,
                title = "暂无匹配记录",
                detail = "切换筛选条件，或在今天页保存文字闪记与录音。",
            )
        } else {
            LazyColumn(
                modifier = Modifier.fillMaxSize(),
                contentPadding = PaddingValues(start = 16.dp, end = 16.dp, bottom = 16.dp),
                verticalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                items(filteredRecords, key = { it.id }) { record ->
                    val dismissState = rememberSwipeToDismissBoxState(
                        confirmValueChange = { value ->
                            if (value == SwipeToDismissBoxValue.EndToStart) {
                                store.send(HostCommand.TrashRecord(record.id))
                                true
                            } else {
                                false
                            }
                        },
                    )
                    SwipeToDismissBox(
                        state = dismissState,
                        enableDismissFromStartToEnd = false,
                        backgroundContent = {
                            Box(
                                modifier = Modifier
                                    .fillMaxSize()
                                    .clip(KoeShapes.card)
                                    .background(colors.danger.copy(alpha = 0.14f))
                                    .padding(horizontal = 20.dp),
                                contentAlignment = Alignment.CenterEnd,
                            ) {
                                Row(
                                    verticalAlignment = Alignment.CenterVertically,
                                    horizontalArrangement = Arrangement.spacedBy(6.dp),
                                ) {
                                    Icon(
                                        imageVector = Icons.Outlined.DeleteOutline,
                                        contentDescription = null,
                                        tint = colors.danger,
                                        modifier = Modifier.size(18.dp),
                                    )
                                    Text(
                                        text = "移入回收站",
                                        color = colors.danger,
                                        fontSize = KoeFontSizes.xs,
                                        fontWeight = FontWeight.SemiBold,
                                    )
                                }
                            }
                        },
                    ) {
                        RecordRowCard(
                            record = record,
                            onOpen = { onSelectRecord(record.id) },
                            onTrash = { store.send(HostCommand.TrashRecord(record.id)) },
                        )
                    }
                }
            }
        }
    }

    if (showTrashSheet) {
        TrashSheet(
            trashRecords = trashRecords,
            onRestore = { id -> store.send(HostCommand.RestoreRecord(id)) },
            onPurge = { id -> store.send(HostCommand.PurgeRecord(id)) },
            onEmptyTrash = { store.send(HostCommand.EmptyTrash) },
            onDismiss = { showTrashSheet = false },
        )
    }
}

@Composable
private fun RecordRowCard(
    record: RecordSnapshot,
    onOpen: () -> Unit,
    onTrash: () -> Unit,
) {
    val colors = KoeTheme.colors
    KoeCard(modifier = Modifier.clickable(onClick = onOpen)) {
        Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                Text(
                    text = record.title,
                    color = colors.textPrimary,
                    fontSize = KoeFontSizes.md,
                    fontWeight = FontWeight.SemiBold,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f),
                )
                KoeBadge(text = record.modeLabel, tint = colors.textSecondary)
                IconButton(
                    onClick = onTrash,
                    modifier = Modifier.size(32.dp),
                ) {
                    Icon(
                        imageVector = Icons.Outlined.DeleteOutline,
                        contentDescription = "移入回收站",
                        tint = colors.textMuted,
                        modifier = Modifier.size(18.dp),
                    )
                }
            }

            if (record.preview.isNotEmpty()) {
                Text(
                    text = record.preview,
                    color = colors.textSecondary,
                    fontSize = KoeFontSizes.xs,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                )
            }

            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                val durationLabel = if (record.durationMs > 0L) {
                    TimeLabel.duration(record.durationMs)
                } else {
                    "${record.segmentCount} 段"
                }
                Text(
                    text = "${TimeLabel.date(record.createdAtEpochSec)}  |  $durationLabel  |  ${record.status}",
                    color = colors.textMuted,
                    fontSize = KoeFontSizes.xs,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f),
                )
                if (record.archived) {
                    KoeBadge(text = "已归档", tint = colors.textMuted)
                }
            }
        }
    }
}

@Composable
private fun TrashSheet(
    trashRecords: List<TrashRecordSnapshot>,
    onRestore: (String) -> Unit,
    onPurge: (String) -> Unit,
    onEmptyTrash: () -> Unit,
    onDismiss: () -> Unit,
) {
    val colors = KoeTheme.colors
    KoeModalSheet(onDismissRequest = onDismiss) {
        Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                Text(
                    text = "回收站",
                    color = colors.textPrimary,
                    fontSize = KoeFontSizes.md,
                    fontWeight = FontWeight.SemiBold,
                )
                Spacer(modifier = Modifier.weight(1f))
                if (trashRecords.isNotEmpty()) {
                    KoePrimaryButton(title = "清空", isPrimary = false, onClick = onEmptyTrash)
                }
                KoePrimaryButton(
                    title = "完成",
                    isPrimary = false,
                    onClick = onDismiss,
                    modifier = Modifier.testTag("trash-sheet-close"),
                )
            }

            if (trashRecords.isEmpty()) {
                KoeEmptyState(
                    icon = Icons.Outlined.DeleteOutline,
                    title = "回收站为空",
                    detail = "左滑或轻点移入回收站后，可在 30 天内随时恢复。",
                )
            } else {
                trashRecords.forEach { item ->
                    KoeCard {
                        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                            Row(
                                modifier = Modifier.fillMaxWidth(),
                                verticalAlignment = Alignment.CenterVertically,
                                horizontalArrangement = Arrangement.SpaceBetween,
                            ) {
                                Text(
                                    text = item.title,
                                    color = colors.textPrimary,
                                    fontSize = KoeFontSizes.sm,
                                    fontWeight = FontWeight.SemiBold,
                                    maxLines = 1,
                                    overflow = TextOverflow.Ellipsis,
                                    modifier = Modifier.weight(1f),
                                )
                                KoeBadge(text = "剩余 ${item.remainingDays} 天", tint = colors.textMuted)
                            }
                            if (item.preview.isNotEmpty()) {
                                Text(
                                    text = item.preview,
                                    color = colors.textSecondary,
                                    fontSize = KoeFontSizes.xs,
                                    maxLines = 2,
                                    overflow = TextOverflow.Ellipsis,
                                )
                            }
                            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                                KoePrimaryButton(
                                    title = "恢复",
                                    icon = Icons.Outlined.Restore,
                                    isPrimary = true,
                                    onClick = { onRestore(item.id) },
                                )
                                KoePrimaryButton(
                                    title = "彻底删除",
                                    icon = Icons.Outlined.DeleteOutline,
                                    isPrimary = false,
                                    onClick = { onPurge(item.id) },
                                )
                            }
                        }
                    }
                }
            }
        }
    }
}
