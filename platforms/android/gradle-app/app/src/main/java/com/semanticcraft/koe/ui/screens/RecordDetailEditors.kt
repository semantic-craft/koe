package com.semanticcraft.koe.ui.screens

import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.testTagsAsResourceId
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import com.semanticcraft.koe.core.HostCommand
import com.semanticcraft.koe.core.HostSessionStore
import com.semanticcraft.koe.core.RecordDetailSnapshot
import com.semanticcraft.koe.core.SegmentSnapshot
import com.semanticcraft.koe.ui.components.KoePrimaryButton
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.launch

@OptIn(ExperimentalComposeUiApi::class)
@Composable
internal fun TextEditorDialog(
    title: String,
    initial: String,
    onDismiss: () -> Unit,
    onSave: suspend (String) -> Boolean,
    due: String? = null,
    onDueChange: (String) -> Unit = {},
    singleLine: Boolean = false,
    allowEmpty: Boolean = false,
    saveLabel: String = "保存",
    onSaveAll: (suspend (String) -> Boolean)? = null,
) {
    var value by rememberSaveable(initial) { mutableStateOf(initial) }
    var saving by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    fun submit(action: suspend (String) -> Boolean) {
        if (saving) return
        saving = true
        scope.launch(start = CoroutineStart.UNDISPATCHED) {
            try {
                if (action(value.trim())) onDismiss()
            } finally {
                saving = false
            }
        }
    }
    AlertDialog(
        onDismissRequest = onDismiss,
        modifier = Modifier.semantics { testTagsAsResourceId = true },
        title = { Text(title) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlinedTextField(value, { value = it }, singleLine = singleLine, maxLines = if (singleLine) 1 else 5,
                    label = { Text(title) }, modifier = Modifier.testTag("editor-value"))
                if (due != null) OutlinedTextField(due, onDueChange, singleLine = true,
                    label = { Text("截止日期") }, modifier = Modifier.testTag("editor-due"))
            }
        },
        confirmButton = {
            Row {
                if (onSaveAll != null) TextButton(modifier = Modifier.testTag("editor-save-all"), enabled = !saving && value.isNotBlank(), onClick = {
                    submit(onSaveAll)
                }) { Text("整条记录") }
                TextButton(modifier = Modifier.testTag("editor-save"), enabled = !saving && (allowEmpty || value.isNotBlank()), onClick = {
                    submit(onSave)
                }) { Text(saveLabel) }
            }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text("取消") } },
    )
}

@Composable
internal fun TranscriptEditors(store: HostSessionStore, detail: RecordDetailSnapshot, segment: SegmentSnapshot) {
    var originalExpanded by rememberSaveable(segment.id) { mutableStateOf(false) }
    var editor by rememberSaveable(segment.id) { mutableStateOf<String?>(null) }
    Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        if (detail.canEditTranscript) {
            KoePrimaryButton("编辑原文", { editor = "text" }, Modifier.testTag("segment-edit-${segment.id}"), isPrimary = false)
            KoePrimaryButton("说话人", { editor = "speaker" }, Modifier.testTag("segment-speaker-${segment.id}"), isPrimary = false)
        }
        if (segment.isEdited && !segment.originalText.isNullOrBlank()) {
            KoePrimaryButton(if (originalExpanded) "收起改前原文" else "改前原文",
                { originalExpanded = !originalExpanded }, Modifier.testTag("segment-original-${segment.id}"), isPrimary = false)
        }
    }
    if (originalExpanded && segment.isEdited && !segment.originalText.isNullOrBlank()) {
        SelectionContainer { Text(segment.originalText) }
    }
    when (editor) {
        "text" -> TextEditorDialog("编辑原文", segment.text, { editor = null }, { text ->
            store.sendReturningErrorAsync(HostCommand.EditSegmentText(detail.id, segment.id, text)) == null
        })
        "speaker" -> {
            val from = segment.speaker
            TextEditorDialog("说话人姓名", from.orEmpty(), { editor = null }, { name ->
                store.sendReturningErrorAsync(HostCommand.SetSegmentSpeaker(detail.id, segment.id, name.ifBlank { null })) == null
            }, singleLine = true, allowEmpty = true, saveLabel = "仅此段",
                onSaveAll = if (from.isNullOrBlank()) null else { name ->
                    store.sendReturningErrorAsync(HostCommand.RenameSpeaker(detail.id, from, name)) == null
                })
        }
    }
}
