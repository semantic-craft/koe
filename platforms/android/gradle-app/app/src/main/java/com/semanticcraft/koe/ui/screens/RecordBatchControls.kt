package com.semanticcraft.koe.ui.screens

import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.semanticcraft.koe.core.HostCommand
import com.semanticcraft.koe.core.HostSessionStore
import com.semanticcraft.koe.core.RecordSnapshot
import com.semanticcraft.koe.ui.components.KoeFilterChip
import com.semanticcraft.koe.ui.components.KoePrimaryButton
import com.semanticcraft.koe.ui.components.StableList

internal enum class RecordSort(val label: String, val order: Comparator<RecordSnapshot>) {
    NEWEST("最新", compareByDescending { it.createdAtEpochSec }),
    OLDEST("最早", compareBy { it.createdAtEpochSec }),
    LONGEST("最长", compareByDescending { it.durationMs }),
}

@Composable
internal fun RecordBatchControls(
    sort: RecordSort, onSort: (RecordSort) -> Unit,
    project: String?, projects: StableList<String>, onProject: (String?) -> Unit,
    selecting: Boolean, onToggle: () -> Unit, selected: StableList<RecordSnapshot>,
    savingId: String?, store: HostSessionStore,
) {
    var menu by remember { mutableStateOf<String?>(null) }
    var newProject by rememberSaveable { mutableStateOf(false) }
    val ids = selected.items.map { it.id }
    fun classify(name: String?) {
        store.send(HostCommand.BatchSetRecordProject(ids, name))
    }
    Row(Modifier.horizontalScroll(rememberScrollState()), verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        Box {
            KoeFilterChip(sort.label, false, { menu = "sort" })
            DropdownMenu(menu == "sort", { menu = null }) {
                RecordSort.entries.forEach { choice ->
                    DropdownMenuItem({ Text(choice.label) }, { menu = null; onSort(choice) })
                }
            }
        }
        Box {
            KoeFilterChip(project?.ifEmpty { "未归类" } ?: "全部项目", project != null, { menu = "filter" })
            DropdownMenu(menu == "filter", { menu = null }) {
                DropdownMenuItem({ Text("全部项目") }, { onProject(null); menu = null })
                DropdownMenuItem({ Text("未归类") }, { onProject(""); menu = null })
                projects.items.forEach { name -> DropdownMenuItem({ Text(name) }, { onProject(name); menu = null }) }
            }
        }
        KoeFilterChip(if (selecting) "退出多选" else "多选", selecting, onToggle)
        if (selecting) {
            Text("已选 " + ids.size)
            Box {
                KoePrimaryButton("批量操作", { menu = "batch" }, enabled = ids.isNotEmpty(), isPrimary = false)
                DropdownMenu(menu == "batch", { menu = null }) {
                    for (archive in listOf(true, false)) {
                        DropdownMenuItem({ Text(if (archive) "归档" else "取消归档") }, {
                            store.send(HostCommand.BatchSetRecordArchived(ids, archive))
                            menu = null
                        })
                    }
                    DropdownMenuItem({ Text("归类到项目") }, { menu = "classify" })
                    val trashable = selected.items.filter { it.canTrash && it.id != savingId }
                    DropdownMenuItem({ Text("移入回收站") }, {
                        store.send(HostCommand.BatchTrashRecords(trashable.map { it.id }))
                        menu = null
                    }, enabled = trashable.isNotEmpty())
                }
                DropdownMenu(menu == "classify", { menu = null }) {
                    DropdownMenuItem({ Text("移回收件箱") }, { classify(null); menu = null })
                    projects.items.forEach { name -> DropdownMenuItem({ Text(name) }, { classify(name); menu = null }) }
                    DropdownMenuItem({ Text("新建项目") }, { menu = null; newProject = true })
                }
            }
        }
    }
    if (newProject && ids.isNotEmpty()) TextEditorDialog("项目名称", "", { newProject = false }, { name ->
        store.sendReturningErrorAsync(HostCommand.BatchSetRecordProject(ids, name)) == null
    }, singleLine = true)
}
