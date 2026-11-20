package com.semanticcraft.koe.ui.leaves

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
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
import com.semanticcraft.koe.core.TimeLabel
import com.semanticcraft.koe.ui.components.KoeBadge
import com.semanticcraft.koe.ui.components.KoeCard
import com.semanticcraft.koe.ui.theme.KoeFontSizes
import com.semanticcraft.koe.ui.theme.KoeTheme

@Composable
fun AndroidLiveMinutesCoverageSlot(
    store: HostSessionStore,
    modifier: Modifier = Modifier,
) {
    val coverageState by store.liveMinutesCoverage.collectAsStateWithLifecycle()
    val coverage = coverageState ?: return
    val colors = KoeTheme.colors

    Column(
        modifier = modifier
            .fillMaxWidth()
            .testTag("live-minutes-coverage"),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            CoverageMetricCard(
                title = "转写覆盖",
                primary = "${coverage.transcriptPercent}%",
                detail = "${TimeLabel.duration(coverage.transcribedDurationMs)} / ${TimeLabel.duration(coverage.audioDurationMs)}",
                modifier = Modifier.weight(1f),
            )
            CoverageMetricCard(
                title = "纪要覆盖",
                primary = "${coverage.minutesPercent}%",
                detail = "${coverage.groundedSegments} / ${coverage.totalSegments} 句原文",
                modifier = Modifier.weight(1f),
            )
        }

        KoeCard {
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.SpaceBetween,
            ) {
                Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    Text(
                        text = "会后整理阶段",
                        color = colors.textMuted,
                        fontSize = KoeFontSizes.xs,
                    )
                    Text(
                        text = coverage.consolidationLabel,
                        color = colors.textPrimary,
                        fontSize = KoeFontSizes.sm,
                        fontWeight = FontWeight.SemiBold,
                    )
                }
                KoeBadge(text = "仅引用原文", tint = colors.textSecondary)
            }
        }
    }
}

@Composable
private fun CoverageMetricCard(
    title: String,
    primary: String,
    detail: String,
    modifier: Modifier = Modifier,
) {
    val colors = KoeTheme.colors
    KoeCard(modifier = modifier) {
        Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Text(
                text = title,
                color = colors.textMuted,
                fontSize = KoeFontSizes.xs,
            )
            Text(
                text = primary,
                color = colors.textPrimary,
                fontSize = KoeFontSizes.md,
                fontWeight = FontWeight.SemiBold,
            )
            Text(
                text = detail,
                color = colors.textSecondary,
                fontSize = KoeFontSizes.xs,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
    }
}
