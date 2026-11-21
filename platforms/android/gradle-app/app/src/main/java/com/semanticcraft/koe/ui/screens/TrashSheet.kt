package com.semanticcraft.koe.ui.screens

import androidx.compose.ui.semantics.testTagsAsResourceId
import androidx.compose.ui.semantics.semantics
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.DeleteOutline
import androidx.compose.material.icons.outlined.Restore
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
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
import com.semanticcraft.koe.core.TrashRecordSnapshot
import com.semanticcraft.koe.ui.components.KoeBadge
import com.semanticcraft.koe.ui.components.KoeCard
import com.semanticcraft.koe.ui.components.KoeEmptyState
import com.semanticcraft.koe.ui.components.KoeModalSheet
import com.semanticcraft.koe.ui.components.KoePrimaryButton
import com.semanticcraft.koe.ui.theme.KoeFontSizes
import com.semanticcraft.koe.ui.theme.KoeTheme

@OptIn(androidx.compose.ui.ExperimentalComposeUiApi::class)
@Composable
internal fun TrashSheet(
    trashRecords: List<TrashRecordSnapshot>,
    onRestore: (String) -> Unit,
    onPurge: (String) -> Unit,
    onEmptyTrash: () -> Unit,
    onDismiss: () -> Unit,
) {
    val colors = KoeTheme.colors
    var confirmDeletion by remember { mutableStateOf<(() -> Unit)?>(null) }
    var deletionTitle by remember { mutableStateOf("") }
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
                    KoePrimaryButton(title = "清空", isPrimary = false, onClick = {
                        deletionTitle = "清空回收站？"
                        confirmDeletion = onEmptyTrash
                    })
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
                                    modifier = Modifier.testTag("trash-restore-${item.id}"),
                                    icon = Icons.Outlined.Restore,
                                    isPrimary = true,
                                    onClick = { onRestore(item.id) },
                                )
                                KoePrimaryButton(
                                    title = "彻底删除",
                                    modifier = Modifier.testTag("trash-purge-${item.id}"),
                                    icon = Icons.Outlined.DeleteOutline,
                                    isPrimary = false,
                                    onClick = {
                                        deletionTitle = "彻底删除「${item.title}」？"
                                        confirmDeletion = { onPurge(item.id) }
                                    },
                                )
                            }
                        }
                    }
                }
            }
        }
    }
    confirmDeletion?.let { delete ->
        AlertDialog(
            modifier = Modifier.semantics { testTagsAsResourceId = true },
            onDismissRequest = { confirmDeletion = null },
            title = { Text(deletionTitle) },
            text = { Text("记录及其音频文件将永久删除，无法恢复。") },
            dismissButton = { TextButton(modifier = Modifier.testTag("purge-cancel"), onClick = { confirmDeletion = null }) { Text("取消") } },
            confirmButton = {
                TextButton(modifier = Modifier.testTag("purge-confirm"), onClick = {
                    confirmDeletion = null
                    delete()
                }) { Text("确认删除") }
            },
        )
    }
}
