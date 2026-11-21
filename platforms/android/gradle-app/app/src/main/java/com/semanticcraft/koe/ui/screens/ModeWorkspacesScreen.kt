package com.semanticcraft.koe.ui.screens

import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import com.semanticcraft.koe.core.CaptureMode
import com.semanticcraft.koe.core.HostSessionStore
import com.semanticcraft.koe.core.SourceSnapshot

enum class AndroidModeWorkspaceRoute(val mode: CaptureMode) {
    QUICK_NOTE(CaptureMode.QUICK_NOTE),
    ALL_DAY(CaptureMode.ALL_DAY),
    LIVE_MINUTES(CaptureMode.MEETING);

    val title: String get() = mode.title
}

@Composable
fun ModeWorkspacesScreen(
    store: HostSessionStore,
    route: AndroidModeWorkspaceRoute,
    onSelectRecord: (String) -> Unit,
    modifier: Modifier = Modifier,
    onOpenSource: (SourceSnapshot) -> Unit = {},
    onOpenCaptureSource: () -> Unit = {},
    onOpenSettings: () -> Unit = {},
) {
    when (route) {
        AndroidModeWorkspaceRoute.QUICK_NOTE -> QuickNoteWorkspaceScreen(
            store, onSelectRecord, onOpenSource, onOpenCaptureSource, modifier)
        AndroidModeWorkspaceRoute.ALL_DAY -> AllDayWorkspaceScreen(
            store, onSelectRecord, onOpenSource, onOpenCaptureSource, modifier)
        AndroidModeWorkspaceRoute.LIVE_MINUTES -> LiveMinutesWorkspaceScreen(
            store, onSelectRecord, onOpenSource, onOpenCaptureSource, onOpenSettings, modifier)
    }
}
