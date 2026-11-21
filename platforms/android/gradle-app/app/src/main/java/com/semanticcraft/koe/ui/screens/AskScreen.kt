package com.semanticcraft.koe.ui.screens

import android.content.ClipData
import android.content.ClipboardManager
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.OpenInNew
import androidx.compose.material.icons.automirrored.outlined.Send
import androidx.compose.material.icons.outlined.AutoAwesome
import androidx.compose.material.icons.outlined.PersonOutline
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Surface
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
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.semanticcraft.koe.core.AskMessageSnapshot
import com.semanticcraft.koe.core.HostCommand
import com.semanticcraft.koe.core.HostSessionStore
import com.semanticcraft.koe.core.SourceSnapshot
import com.semanticcraft.koe.core.TimeLabel
import com.semanticcraft.koe.ui.components.KoeBadge
import com.semanticcraft.koe.ui.components.KoeCard
import com.semanticcraft.koe.ui.components.KoeEmptyState
import com.semanticcraft.koe.ui.components.KoeFilterChip
import com.semanticcraft.koe.ui.components.KoeModalSheet
import com.semanticcraft.koe.ui.components.KoePrimaryButton
import com.semanticcraft.koe.ui.theme.KoeFontSizes
import com.semanticcraft.koe.ui.theme.KoeShapes
import com.semanticcraft.koe.ui.theme.KoeTheme

@Composable
fun AskScreen(
    store: HostSessionStore,
    onOpenSource: (SourceSnapshot) -> Unit,
    modifier: Modifier = Modifier,
    compact: Boolean = false,
) {
    val ask by store.ask.collectAsStateWithLifecycle()
    val records by store.records.collectAsStateWithLifecycle()
    val navigation by store.navigation.collectAsStateWithLifecycle()
    val settings by store.settings.collectAsStateWithLifecycle()
    val colors = KoeTheme.colors
    val focusManager = LocalFocusManager.current
    val keyboardController = LocalSoftwareKeyboardController.current

    var questionDraft by rememberSaveable { mutableStateOf("") }
    var inspectedSource by remember { mutableStateOf<SourceSnapshot?>(null) }

    val scopedRecord = (ask.recordId ?: navigation.selectedRecordId)
        ?.let { id -> records.firstOrNull { it.id == id } }

    var picking by rememberSaveable { mutableStateOf(false) }
    val listState = rememberLazyListState()
    LaunchedEffect(ask.messages.size, ask.phase) {
        val last = ask.messages.size.coerceAtLeast(1) - 1 + if (ask.phase == "pending") 1 else 0
        listState.scrollToItem(last)
    }
    if (picking) AlertDialog(
        onDismissRequest = { picking = false },
        title = { Text("选择问答记录") },
        text = {
            LazyColumn {
                item {
                    TextButton(onClick = {
                        if (store.sendReturningError(HostCommand.SetAskScope("all")) == null) picking = false
                    }) { Text("全部记录") }
                }
                items(records, key = { it.id }) { record ->
                    TextButton(onClick = {
                        if (store.sendReturningError(HostCommand.SetAskScope("record", record.id)) == null) picking = false
                    }, modifier = Modifier.fillMaxWidth()) { Text(record.title) }
                }
            }
        },
        confirmButton = { TextButton(onClick = { picking = false }) { Text("关闭") } },
    )

    fun submitQuestion() {
        val trimmed = questionDraft.trim()
        if (trimmed.isEmpty() || ask.phase == "pending") return
        focusManager.clearFocus()
        keyboardController?.hide()
        if (store.sendReturningError(HostCommand.Ask(trimmed, ask.scope, ask.recordId)) == null) {
            questionDraft = ""
        }
    }

    Column(
        modifier = modifier
            .fillMaxSize()
            .background(colors.bgPanel),
    ) {
        if (!compact) Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 16.dp, vertical = if (compact) 2.dp else 10.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Row(
                modifier = Modifier
                    .weight(1f)
                    .horizontalScroll(rememberScrollState()),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                KoeFilterChip(
                    label = "全部记录",
                    selected = ask.scope == "all",
                    onClick = { store.send(HostCommand.SetAskScope(scope = "all", recordId = null)) },
                )
                if (records.isNotEmpty()) KoeFilterChip("选择记录", false, { picking = true })
                if (scopedRecord != null) {
                    KoeFilterChip(
                        label = scopedRecord.title,
                        selected = ask.scope == "record" && ask.recordId == scopedRecord.id,
                        onClick = {
                            store.send(HostCommand.SetAskScope(scope = "record", recordId = scopedRecord.id))
                        },
                    )
                }
            }

            if (!settings.provider.configured) {
                KoeBadge(text = "本地检索", tint = colors.textMuted)
            }
        }

        LazyColumn(
            state = listState,
            modifier = Modifier.weight(1f),
            contentPadding = PaddingValues(if (compact) 6.dp else 16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            if (ask.messages.isEmpty()) {
                item(key = "ask-empty") {
                    KoeEmptyState(
                        icon = Icons.Outlined.AutoAwesome,
                        title = "向已保存的记录提问",
                        detail = "提问讨论结论、待办或决定，回答将附带可追溯的原文出处。",
                    )
                }
            } else {
                items(ask.messages, key = { it.id }) { message ->
                    AskMessageCard(
                        message = message,
                        compact = compact,
                        onOpenSource = onOpenSource,
                        onInspectSource = { source -> inspectedSource = source },
                    )
                }
            }

            if (ask.phase == "pending") {
                item(key = "ask-pending") {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                        modifier = Modifier.padding(horizontal = 4.dp),
                    ) {
                        CircularProgressIndicator(
                            modifier = Modifier.size(16.dp),
                            strokeWidth = 2.dp,
                            color = colors.accent,
                        )
                        Text(
                            text = "正在查阅相关记录…",
                            color = colors.textMuted,
                            fontSize = KoeFontSizes.xs,
                        )
                    }
                }
            }
        }

        HorizontalDivider(color = colors.border)

        Row(
            modifier = Modifier
                .fillMaxWidth()
                .imePadding()
                .background(colors.surface0)
                .padding(horizontal = 16.dp, vertical = if (compact) 2.dp else 10.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            if (compact && records.isNotEmpty()) {
                KoeFilterChip(
                    label = scopedRecord?.title?.takeIf { ask.scope == "record" } ?: "选择记录",
                    selected = ask.scope == "record",
                    modifier = Modifier.widthIn(max = 168.dp),
                    onClick = { picking = true },
                )
            }
            val inputModifier = Modifier.weight(1f).testTag("ask-question-input")
            if (compact) {
                // A landscape IME can leave less than the Material field's vertical padding.
                BasicTextField(
                    value = questionDraft,
                    onValueChange = { questionDraft = it },
                    singleLine = false,
                    maxLines = 4,
                    textStyle = TextStyle(color = colors.textPrimary, fontSize = KoeFontSizes.sm),
                    cursorBrush = SolidColor(colors.accent),
                    modifier = inputModifier,
                    decorationBox = { field ->
                        Box(
                            Modifier.fillMaxWidth().heightIn(min = 40.dp)
                                .background(colors.surface1, KoeShapes.control)
                                .border(1.dp, colors.border, KoeShapes.control)
                                .padding(horizontal = 12.dp, vertical = 2.dp),
                            contentAlignment = Alignment.CenterStart,
                        ) {
                            if (questionDraft.isEmpty()) Text("问问你记下来的事…", color = colors.textMuted, fontSize = KoeFontSizes.sm)
                            field()
                        }
                    },
                )
            } else OutlinedTextField(
                value = questionDraft,
                onValueChange = { questionDraft = it },
                placeholder = {
                    Text(
                        text = "问问你记下来的事…",
                        fontSize = KoeFontSizes.sm,
                        color = colors.textMuted,
                    )
                },
                singleLine = false,
                maxLines = 4,
                shape = KoeShapes.control,
                colors = OutlinedTextFieldDefaults.colors(
                    focusedBorderColor = colors.accent,
                    unfocusedBorderColor = colors.border,
                    focusedContainerColor = colors.surface1,
                    unfocusedContainerColor = colors.surface1,
                    focusedTextColor = colors.textPrimary,
                    unfocusedTextColor = colors.textPrimary,
                ),
                modifier = inputModifier,
            )

            KoePrimaryButton(
                title = "发送",
                icon = Icons.AutoMirrored.Outlined.Send,
                isPrimary = true,
                enabled = questionDraft.isNotBlank() && ask.phase != "pending",
                onClick = { submitQuestion() },
                modifier = Modifier.testTag("ask-question-submit"),
            )
        }
    }

    val currentSource = inspectedSource
    if (currentSource != null) {
        SourceEvidenceSheet(
            source = currentSource,
            onDismiss = { inspectedSource = null },
            onJumpToRecord = {
                inspectedSource = null
                onOpenSource(currentSource)
            },
        )
    }
}

@Composable
private fun AskMessageCard(
    message: AskMessageSnapshot,
    compact: Boolean,
    onOpenSource: (SourceSnapshot) -> Unit,
    onInspectSource: (SourceSnapshot) -> Unit,
) {
    val colors = KoeTheme.colors
    val isUser = message.role == "user"

    val body: @Composable () -> Unit = {
        SelectionContainer { Text(message.text, color = colors.textPrimary, fontSize = KoeFontSizes.sm) }
    }
    KoeCard(contentPadding = PaddingValues(if (compact) 8.dp else 16.dp)) {
        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            if (compact) body()
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(6.dp),
            ) {
                Icon(
                    imageVector = if (isUser) Icons.Outlined.PersonOutline else Icons.Outlined.AutoAwesome,
                    contentDescription = null,
                    tint = colors.textMuted,
                    modifier = Modifier.size(16.dp),
                )
                Text(
                    text = if (isUser) "你" else "Koe",
                    color = colors.textMuted,
                    fontSize = KoeFontSizes.xs,
                    fontWeight = FontWeight.SemiBold,
                )
                if (!isUser && message.mode == "retrieval") {
                    KoeBadge(text = "原文检索", tint = colors.textMuted)
                }
                if (!isUser) {
                    val clipboard = LocalContext.current.getSystemService(ClipboardManager::class.java)
                    TextButton(onClick = {
                        clipboard.setPrimaryClip(ClipData.newPlainText("Koe", message.text))
                    }, modifier = Modifier.testTag("copy-" + message.id)) { Text("复制") }
                }
            }

            if (!compact) body()

            if (message.sources.isNotEmpty()) {
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .horizontalScroll(rememberScrollState()),
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    message.sources.forEachIndexed { index, source ->
                        val rank = index + 1
                        Surface(
                            onClick = { onOpenSource(source) },
                            shape = KoeShapes.pill,
                            color = colors.accentSoft,
                            border = BorderStroke(1.dp, colors.border),
                            modifier = Modifier.testTag("ask-source-chip-$rank"),
                        ) {
                            Text(
                                text = "[S$rank]",
                                color = colors.accent,
                                fontSize = KoeFontSizes.xs,
                                fontWeight = FontWeight.SemiBold,
                                modifier = Modifier.padding(horizontal = 10.dp, vertical = 6.dp),
                            )
                        }
                        KoePrimaryButton(title = "查看摘录", isPrimary = false, onClick = { onInspectSource(source) })
                    }
                }
            }
        }
    }
}

@Composable
private fun SourceEvidenceSheet(
    source: SourceSnapshot,
    onDismiss: () -> Unit,
    onJumpToRecord: () -> Unit,
) {
    val colors = KoeTheme.colors
    KoeModalSheet(onDismissRequest = onDismiss) {
        Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    text = "原文来源",
                    color = colors.textPrimary,
                    fontSize = KoeFontSizes.md,
                    fontWeight = FontWeight.SemiBold,
                )
                Spacer(modifier = Modifier.weight(1f))
                KoePrimaryButton(
                    title = "关闭",
                    isPrimary = false,
                    onClick = onDismiss,
                    modifier = Modifier.testTag("source-evidence-close"),
                )
            }

            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                Text(
                    text = source.title,
                    color = colors.textPrimary,
                    fontSize = KoeFontSizes.sm,
                    fontWeight = FontWeight.SemiBold,
                    modifier = Modifier.weight(1f),
                )
                KoeBadge(text = TimeLabel.duration(source.startMs), tint = colors.textSecondary)
            }

            Surface(
                shape = KoeShapes.control,
                color = colors.bgSubtle,
                modifier = Modifier.fillMaxWidth(),
            ) {
                Text(
                    text = source.quote,
                    color = colors.textSecondary,
                    fontSize = KoeFontSizes.sm,
                    modifier = Modifier.padding(12.dp),
                )
            }

            KoePrimaryButton(
                title = "打开完整记录",
                icon = Icons.AutoMirrored.Outlined.OpenInNew,
                isPrimary = true,
                onClick = onJumpToRecord,
            )
        }
    }
}
