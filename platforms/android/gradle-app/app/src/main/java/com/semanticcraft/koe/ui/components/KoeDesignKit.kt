package com.semanticcraft.koe.ui.components

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.HelpOutline
import androidx.compose.material.icons.automirrored.outlined.OpenInNew
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.BottomSheetDefaults
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.testTagsAsResourceId
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.semanticcraft.koe.core.SourceSnapshot
import com.semanticcraft.koe.core.TimeLabel
import com.semanticcraft.koe.ui.theme.KoeFontSizes
import com.semanticcraft.koe.ui.theme.KoeShapes
import com.semanticcraft.koe.ui.theme.KoeTheme

@Composable
fun KoeCard(
    modifier: Modifier = Modifier,
    shape: Shape = KoeShapes.card,
    containerColor: Color = KoeTheme.colors.surface1,
    borderColor: Color = KoeTheme.colors.border,
    contentPadding: PaddingValues = PaddingValues(16.dp),
    content: @Composable ColumnScope.() -> Unit,
) {
    Surface(
        modifier = modifier.fillMaxWidth(),
        shape = shape,
        color = containerColor,
        border = BorderStroke(1.dp, borderColor),
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(contentPadding),
            content = content,
        )
    }
}

@Composable
fun KoeBadge(
    text: String,
    modifier: Modifier = Modifier,
    tint: Color = KoeTheme.colors.accent,
) {
    Surface(
        modifier = modifier,
        shape = KoeShapes.pill,
        color = tint.copy(alpha = 0.12f),
    ) {
        Text(
            text = text,
            color = tint,
            fontSize = KoeFontSizes.xs,
            fontWeight = FontWeight.Medium,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.padding(horizontal = 8.dp, vertical = 4.dp),
        )
    }
}

@Composable
fun KoePrimaryButton(
    title: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    icon: ImageVector? = null,
    isPrimary: Boolean = true,
    enabled: Boolean = true,
) {
    val colors = KoeTheme.colors
    Button(
        onClick = onClick,
        enabled = enabled,
        modifier = modifier.heightIn(min = 38.dp),
        shape = KoeShapes.control,
        border = BorderStroke(1.dp, if (isPrimary) colors.accent else colors.border),
        colors = ButtonDefaults.buttonColors(
            containerColor = if (isPrimary) colors.accent else colors.bgSubtle,
            contentColor = if (isPrimary) colors.onAccent else colors.textPrimary,
            disabledContainerColor = (if (isPrimary) colors.accent else colors.bgSubtle).copy(alpha = 0.45f),
            disabledContentColor = (if (isPrimary) colors.onAccent else colors.textPrimary).copy(alpha = 0.6f),
        ),
        contentPadding = PaddingValues(horizontal = 14.dp, vertical = 8.dp),
        elevation = ButtonDefaults.buttonElevation(
            defaultElevation = 0.dp,
            pressedElevation = 0.dp,
            disabledElevation = 0.dp,
        ),
    ) {
        if (icon != null) {
            Icon(
                imageVector = icon,
                contentDescription = null,
                modifier = Modifier.size(16.dp),
            )
            Spacer(modifier = Modifier.width(6.dp))
        }
        Text(
            text = title,
            fontSize = KoeFontSizes.xs,
            fontWeight = FontWeight.SemiBold,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
    }
}

@OptIn(ExperimentalComposeUiApi::class)
@Composable
fun KoeInfoTip(
    title: String,
    message: String,
    modifier: Modifier = Modifier,
) {
    var expanded by remember { mutableStateOf(false) }
    val colors = KoeTheme.colors

    IconButton(
        onClick = { expanded = true },
        modifier = modifier.size(32.dp),
    ) {
        Icon(
            imageVector = Icons.AutoMirrored.Outlined.HelpOutline,
            contentDescription = "${title}的说明",
            tint = colors.textMuted,
            modifier = Modifier.size(18.dp),
        )
    }

    if (expanded) {
        AlertDialog(
            onDismissRequest = { expanded = false },
            modifier = Modifier.semantics { testTagsAsResourceId = true },
            containerColor = colors.surface1,
            titleContentColor = colors.textPrimary,
            textContentColor = colors.textSecondary,
            title = {
                Text(
                    text = title,
                    fontSize = KoeFontSizes.md,
                    fontWeight = FontWeight.SemiBold,
                )
            },
            text = {
                Text(
                    text = message,
                    fontSize = KoeFontSizes.sm,
                    color = colors.textSecondary,
                )
            },
            confirmButton = {
                TextButton(onClick = { expanded = false }) {
                    Text(
                        text = "知道了",
                        fontSize = KoeFontSizes.sm,
                        color = colors.accent,
                        fontWeight = FontWeight.SemiBold,
                    )
                }
            },
        )
    }
}

@OptIn(ExperimentalMaterial3Api::class, ExperimentalComposeUiApi::class)
@Composable
fun KoeModalSheet(
    onDismissRequest: () -> Unit,
    modifier: Modifier = Modifier,
    content: @Composable ColumnScope.() -> Unit,
) {
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    val colors = KoeTheme.colors

    ModalBottomSheet(
        onDismissRequest = onDismissRequest,
        sheetState = sheetState,
        shape = KoeShapes.sheetTop,
        containerColor = colors.surface0,
        contentColor = colors.textPrimary,
        dragHandle = { BottomSheetDefaults.DragHandle(color = colors.border) },
        modifier = modifier,
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .semantics { testTagsAsResourceId = true }
                .imePadding()
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 20.dp)
                .padding(bottom = 24.dp)
                .navigationBarsPadding(),
            content = content,
        )
    }
}

@Composable
fun KoeFilterChip(
    label: String,
    selected: Boolean,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val colors = KoeTheme.colors
    Surface(
        onClick = onClick,
        modifier = modifier,
        shape = KoeShapes.pill,
        color = if (selected) colors.accent else colors.surface1,
        border = BorderStroke(1.dp, if (selected) colors.accent else colors.border),
    ) {
        Text(
            text = label,
            color = if (selected) colors.onAccent else colors.textSecondary,
            fontSize = KoeFontSizes.xs,
            fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Medium,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.padding(horizontal = 12.dp, vertical = 7.dp),
        )
    }
}

@Composable
fun KoeSourceLink(
    source: SourceSnapshot,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val colors = KoeTheme.colors
    Surface(
        onClick = onClick,
        modifier = modifier.semantics { contentDescription = "跳转来源 ${source.title}" },
        shape = KoeShapes.control,
        color = colors.accentSoft,
        border = BorderStroke(1.dp, colors.border),
    ) {
        Row(
            modifier = Modifier.padding(horizontal = 10.dp, vertical = 6.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            Icon(
                imageVector = Icons.AutoMirrored.Outlined.OpenInNew,
                contentDescription = null,
                tint = colors.accent,
                modifier = Modifier.size(14.dp),
            )
            Text(
                text = source.title,
                color = colors.accent,
                fontSize = KoeFontSizes.xs,
                fontWeight = FontWeight.Medium,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            Text(
                text = TimeLabel.duration(source.startMs),
                color = colors.textMuted,
                fontSize = KoeFontSizes.xs,
                fontWeight = FontWeight.Medium,
            )
        }
    }
}

@Composable
fun KoeEmptyState(
    icon: ImageVector,
    title: String,
    detail: String,
    modifier: Modifier = Modifier,
) {
    val colors = KoeTheme.colors
    Column(
        modifier = modifier
            .fillMaxWidth()
            .padding(horizontal = 20.dp, vertical = 32.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Icon(
            imageVector = icon,
            contentDescription = null,
            tint = colors.accent,
            modifier = Modifier.size(28.dp),
        )
        Text(
            text = title,
            color = colors.textPrimary,
            fontSize = KoeFontSizes.md,
            fontWeight = FontWeight.SemiBold,
            textAlign = TextAlign.Center,
        )
        Text(
            text = detail,
            color = colors.textMuted,
            fontSize = KoeFontSizes.xs,
            textAlign = TextAlign.Center,
        )
    }
}
