package com.semanticcraft.koe.ui.screens

import android.text.format.Formatter
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.launch
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.semanticcraft.koe.core.HostCommand
import com.semanticcraft.koe.core.HostSessionStore
import com.semanticcraft.koe.ui.components.KoeModalSheet
import com.semanticcraft.koe.ui.components.KoePrimaryButton
import com.semanticcraft.koe.ui.theme.KoeTheme

@Composable
internal fun CaptureSourceSheet(store: HostSessionStore, onDismiss: () -> Unit) {
    val capture by store.captureStudio.collectAsStateWithLifecycle()
    val today by store.today.collectAsStateWithLifecycle()
    val studio = capture.studio
    val enabled = !capture.isRecordingLocked
    val effective = studio.activeSource ?: studio.selectedSource
    val scope = rememberCoroutineScope()
    var error by remember { mutableStateOf<String?>(null) }
    fun select(key: String) {
        scope.launch(start = CoroutineStart.UNDISPATCHED) {
            error = store.sendReturningErrorAsync(HostCommand.SelectCaptureSource(key))
        }
    }

    KoeModalSheet(onDismiss) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            WorkspaceTitle("录音输入源", Modifier.weight(1f))
            KoePrimaryButton("完成", onDismiss, Modifier.testTag("source-sheet-close"), isPrimary = false)
        }
        if (!enabled) Text("正在录音，请先结束当前录音再切换输入源。", color = KoeTheme.colors.warning)
        error?.let { Text(it, color = KoeTheme.colors.danger) }
        Column(Modifier.selectableGroup()) {
            SourceOption("auto", "自动选择", studio.selectedLabel, studio.selectionMode == "auto", enabled, ::select)
            val beanStatus = today.picker?.beanBadge ?: if (today.deviceConnected) "已连接" else "未连接"
            SourceOption("bean", "Soundcore Work 录音豆", beanStatus, studio.selectionMode != "auto" && effective == "bean",
                enabled, ::select)
            studio.inputs.forEach { input ->
                val selected = effective == input.sourceKey || (effective == "system_default" && input.isDefault)
                SourceOption(input.sourceKey, input.name, if (input.isDefault) input.badge + "  |  默认" else input.badge,
                    studio.selectionMode != "auto" && selected, enabled, ::select)
            }
        }
        WorkspaceTitle("本地音频缓存")
        studio.audioStorage?.let { storage ->
            val size = Formatter.formatFileSize(LocalContext.current, storage.totalBytes)
            Text("${storage.fileCount} 个文件  |  $size")
        } ?: Text("暂无音频存储统计")
    }
}

@Composable
private fun SourceOption(
    key: String, title: String, detail: String, selected: Boolean, enabled: Boolean, onSelect: (String) -> Unit,
) {
    Row(Modifier.fillMaxWidth().testTag("source-" + key)
        .selectable(selected, enabled, Role.RadioButton) { onSelect(key) }
        .padding(vertical = 10.dp), verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.weight(1f)) {
            Text(title)
            Text(detail, color = KoeTheme.colors.textSecondary)
        }
        RadioButton(selected, onClick = null, enabled = enabled)
    }
}
