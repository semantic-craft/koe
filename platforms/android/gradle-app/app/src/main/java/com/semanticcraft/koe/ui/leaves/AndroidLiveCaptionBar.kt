package com.semanticcraft.koe.ui.leaves

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Subtitles
import androidx.compose.material3.Icon
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.semanticcraft.koe.core.HostSessionStore
import com.semanticcraft.koe.ui.components.KoePrimaryButton
import com.semanticcraft.koe.ui.theme.KoeFontSizes
import com.semanticcraft.koe.ui.theme.KoeShapes
import com.semanticcraft.koe.ui.theme.KoeTheme

@Composable
fun AndroidLiveCaptionBar(
    store: HostSessionStore,
    onOpenRecord: (String) -> Unit,
    modifier: Modifier = Modifier,
) {
    val captionState by store.liveCaption.collectAsStateWithLifecycle()
    val caption = captionState ?: return
    val colors = KoeTheme.colors

    Surface(
        modifier = modifier
            .fillMaxWidth()
            .testTag("live-caption-bar"),
        shape = KoeShapes.card,
        color = colors.accentSoft,
        border = BorderStroke(1.dp, colors.border),
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 14.dp, vertical = 10.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Icon(
                imageVector = Icons.Outlined.Subtitles,
                contentDescription = null,
                tint = colors.accent,
                modifier = Modifier.size(18.dp),
            )

            Column(
                modifier = Modifier.weight(1f),
                verticalArrangement = Arrangement.spacedBy(2.dp),
            ) {
                Text(
                    text = caption.status,
                    color = colors.textMuted,
                    fontSize = KoeFontSizes.xs,
                    fontWeight = FontWeight.Medium,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                Text(
                    text = caption.text.ifBlank { "开始说话，字幕会显示在这里" },
                    color = colors.textPrimary,
                    fontSize = KoeFontSizes.sm,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.testTag("live-caption-text"),
                )
            }

            KoePrimaryButton(
                title = "查看",
                isPrimary = false,
                onClick = { onOpenRecord(caption.recordId) },
            )
        }
    }
}
