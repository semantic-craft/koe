package com.semanticcraft.koe.ui.screens

import android.os.Bundle
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ArrowBack
import androidx.compose.material.icons.outlined.AutoAwesome
import androidx.compose.material.icons.outlined.Checklist
import androidx.compose.material.icons.outlined.Close
import androidx.compose.material.icons.outlined.DeleteOutline
import androidx.compose.material.icons.outlined.GridView
import androidx.compose.material.icons.outlined.Inbox
import androidx.compose.material.icons.outlined.Settings
import androidx.compose.material.icons.outlined.WarningAmber
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.NavigationBarItemDefaults
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.Saver
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshots.SnapshotStateMap
import androidx.compose.ui.Alignment
import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.testTagsAsResourceId
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.semanticcraft.koe.core.HostCommand
import com.semanticcraft.koe.core.HostSessionStore
import com.semanticcraft.koe.core.SourceSnapshot
import com.semanticcraft.koe.ui.components.KoePrimaryButton
import com.semanticcraft.koe.ui.leaves.AndroidActiveCaptureBar
import com.semanticcraft.koe.ui.leaves.AndroidLiveCaptionBar
import com.semanticcraft.koe.ui.leaves.AndroidMiniPlayerBar
import com.semanticcraft.koe.ui.theme.KoeFontSizes
import com.semanticcraft.koe.ui.theme.KoeShapes
import com.semanticcraft.koe.ui.theme.KoeTheme
import kotlinx.coroutines.delay

enum class AndroidAppTab(val label: String, val icon: ImageVector) {
    TODAY("今天", Icons.Outlined.GridView),
    RECORDS("记录", Icons.Outlined.Inbox),
    ACTIONS("行动", Icons.Outlined.Checklist),
    ASK("问 AI", Icons.Outlined.AutoAwesome),
}

sealed interface AndroidDetailRoute {
    data class Record(val recordId: String) : AndroidDetailRoute
    data class Workspace(val route: AndroidModeWorkspaceRoute) : AndroidDetailRoute
}

private val tabStackSaver = Saver<SnapshotStateMap<AndroidAppTab, List<AndroidDetailRoute>>, Bundle>(
    save = { stacks ->
        Bundle().apply {
            stacks.forEach { (tab, routes) ->
                putStringArrayList(tab.name, ArrayList(routes.map { route ->
                    when (route) {
                        is AndroidDetailRoute.Record -> "record:" + route.recordId
                        is AndroidDetailRoute.Workspace -> "workspace:" + route.route.name
                    }
                }))
            }
        }
    },
    restore = { bundle ->
        mutableStateMapOf<AndroidAppTab, List<AndroidDetailRoute>>().apply {
            for (tab in AndroidAppTab.entries) {
                this[tab] = bundle.getStringArrayList(tab.name).orEmpty().mapNotNull { route ->
                    when {
                        route.startsWith("record:") -> AndroidDetailRoute.Record(route.removePrefix("record:"))
                        route.startsWith("workspace:") -> AndroidModeWorkspaceRoute.entries
                            .find { it.name == route.removePrefix("workspace:") }?.let(AndroidDetailRoute::Workspace)
                        else -> null
                    }
                }
            }
        }
    },
)

private enum class AndroidRootSheet {
    NONE,
    DEVICE,
    CAPTURE_SOURCE,
    SETTINGS,
}

@OptIn(ExperimentalMaterial3Api::class, ExperimentalComposeUiApi::class)
@Composable
fun KoeRootScreen(
    store: HostSessionStore,
    modifier: Modifier = Modifier,
) {
    val colors = KoeTheme.colors
    val navigation by store.navigation.collectAsStateWithLifecycle()
    val device by store.device.collectAsStateWithLifecycle()
    val today by store.today.collectAsStateWithLifecycle()

    var selectedTab by rememberSaveable { mutableStateOf(AndroidAppTab.TODAY) }
    var activeSheet by rememberSaveable { mutableStateOf(AndroidRootSheet.NONE) }
    val tabStacks = rememberSaveable(saver = tabStackSaver) {
        mutableStateMapOf<AndroidAppTab, List<AndroidDetailRoute>>()
    }

    val currentStack = tabStacks[selectedTab].orEmpty()
    val topRoute = currentStack.lastOrNull()

    fun pushRoute(route: AndroidDetailRoute) {
        tabStacks[selectedTab] = currentStack + route
    }

    fun popCurrentTab() {
        if (currentStack.isNotEmpty()) tabStacks[selectedTab] = currentStack.dropLast(1)
    }

    BackHandler(enabled = activeSheet != AndroidRootSheet.NONE || currentStack.isNotEmpty()) {
        if (activeSheet != AndroidRootSheet.NONE) activeSheet = AndroidRootSheet.NONE else popCurrentTab()
    }

    fun openRecord(recordId: String) {
        store.send(HostCommand.SelectRecord(recordId))
        pushRoute(AndroidDetailRoute.Record(recordId))
    }

    fun openSource(source: SourceSnapshot) {
        store.send(HostCommand.OpenSource(recordId = source.recordId, segmentId = source.segmentId))
        pushRoute(AndroidDetailRoute.Record(source.recordId))
    }

    val topTitle = when (topRoute) {
        is AndroidDetailRoute.Record -> navigation.detailTitle ?: "记录详情"
        is AndroidDetailRoute.Workspace -> topRoute.route.title
        null -> selectedTab.label
    }

    Box(modifier = modifier.fillMaxSize().semantics { testTagsAsResourceId = true }) {
        Scaffold(
            containerColor = colors.bgPanel,
            topBar = {
                Column {
                    TopAppBar(
                        colors = TopAppBarDefaults.topAppBarColors(
                            containerColor = colors.surface0,
                            titleContentColor = colors.textPrimary,
                            navigationIconContentColor = colors.textPrimary,
                            actionIconContentColor = colors.textPrimary,
                        ),
                        navigationIcon = {
                            if (topRoute != null) {
                                IconButton(onClick = { popCurrentTab() }) {
                                    Icon(Icons.AutoMirrored.Outlined.ArrowBack, contentDescription = "返回")
                                }
                            }
                        },
                        title = {
                            Text(
                                text = topTitle,
                                fontSize = KoeFontSizes.md,
                                fontWeight = FontWeight.SemiBold,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
                            )
                        },
                        actions = {
                            DeviceStatusPill(
                                connected = device.connected,
                                phase = device.phase,
                                batteryPercent = device.batteryPercent,
                                isReleased = today.beanControlState == "released",
                                onClick = { activeSheet = AndroidRootSheet.DEVICE },
                            )
                            Spacer(modifier = Modifier.width(6.dp))
                            IconButton(
                                onClick = { activeSheet = AndroidRootSheet.SETTINGS },
                                modifier = Modifier.testTag("settings-button"),
                            ) {
                                Icon(
                                    imageVector = Icons.Outlined.Settings,
                                    contentDescription = "设置",
                                    tint = colors.textPrimary,
                                    modifier = Modifier.size(20.dp),
                                )
                            }
                        },
                    )
                    HorizontalDivider(color = colors.border)
                }
            },
            bottomBar = {
                Column(modifier = Modifier.fillMaxWidth()) {
                    AndroidMiniPlayerBar(store, (topRoute as? AndroidDetailRoute.Record)?.recordId, ::openRecord)
                    DockedBottomChrome(store, ::openRecord, (topRoute as? AndroidDetailRoute.Workspace)?.route)
                    HorizontalDivider(color = colors.border)
                    NavigationBar(containerColor = colors.surface0, tonalElevation = 0.dp) {
                        AndroidAppTab.entries.forEach { tab ->
                            val selected = selectedTab == tab
                            NavigationBarItem(
                                selected = selected,
                                onClick = {
                                    if (selectedTab == tab) tabStacks[tab] = emptyList() else selectedTab = tab
                                },
                                icon = { Icon(tab.icon, contentDescription = null, modifier = Modifier.size(20.dp)) },
                                label = {
                                    Text(
                                        text = tab.label,
                                        fontSize = KoeFontSizes.xs,
                                        fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Medium,
                                        maxLines = 1,
                                    )
                                },
                                colors = NavigationBarItemDefaults.colors(
                                    selectedIconColor = colors.accent,
                                    selectedTextColor = colors.accent,
                                    unselectedIconColor = colors.textMuted,
                                    unselectedTextColor = colors.textMuted,
                                    indicatorColor = colors.accentSoft,
                                ),
                            )
                        }
                    }
                }
            },
        ) { innerPadding ->
            Box(modifier = Modifier.fillMaxSize().padding(innerPadding)) {
                when (topRoute) {
                    is AndroidDetailRoute.Record -> RecordDetailScreen(store = store, recordId = topRoute.recordId)
                    is AndroidDetailRoute.Workspace -> ModeWorkspacesScreen(
                        store = store,
                        route = topRoute.route,
                        onSelectRecord = ::openRecord,
                        onOpenSource = ::openSource,
                        onOpenCaptureSource = { activeSheet = AndroidRootSheet.CAPTURE_SOURCE },
                        onOpenSettings = { activeSheet = AndroidRootSheet.SETTINGS },
                    )
                    null -> when (selectedTab) {
                        AndroidAppTab.TODAY -> TodayScreen(
                            store = store,
                            onOpenCaptureSource = { activeSheet = AndroidRootSheet.CAPTURE_SOURCE },
                            onOpenWorkspace = { route -> pushRoute(AndroidDetailRoute.Workspace(route)) },
                        )
                        AndroidAppTab.RECORDS -> RecordsScreen(store = store, onSelectRecord = ::openRecord)
                        AndroidAppTab.ACTIONS -> ActionsScreen(store = store, onOpenSource = ::openSource)
                        AndroidAppTab.ASK -> AskScreen(store = store, onOpenSource = ::openSource)
                    }
                }
            }
        }

        when (activeSheet) {
            AndroidRootSheet.DEVICE -> DeviceSheet(store = store, onDismiss = { activeSheet = AndroidRootSheet.NONE })
            AndroidRootSheet.SETTINGS -> SettingsSheet(store = store, onDismiss = { activeSheet = AndroidRootSheet.NONE })
            AndroidRootSheet.CAPTURE_SOURCE -> CaptureSourceSheet(store) { activeSheet = AndroidRootSheet.NONE }
            AndroidRootSheet.NONE -> Unit
        }
    }
}

@Composable
private fun DeviceStatusPill(
    connected: Boolean,
    phase: String,
    batteryPercent: Int?,
    isReleased: Boolean,
    onClick: () -> Unit,
) {
    val colors = KoeTheme.colors
    val label = when {
        isReleased -> "录音豆 已让出"
        connected && batteryPercent != null -> "录音豆 ${batteryPercent}%"
        connected -> "录音豆 已连接"
        else -> "录音豆"
    }
    val dotColor = when {
        isReleased -> colors.textMuted
        connected -> colors.success
        phase == "disconnected" -> colors.textMuted
        else -> colors.warning
    }

    Surface(
        onClick = onClick,
        shape = KoeShapes.pill,
        color = colors.bgSubtle,
        border = BorderStroke(1.dp, colors.border),
        modifier = Modifier.testTag("device-status-pill"),
    ) {
        Row(
            modifier = Modifier.padding(horizontal = 10.dp, vertical = 6.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            Box(modifier = Modifier.size(7.dp).clip(KoeShapes.pill).background(dotColor))
            Text(
                text = label,
                color = colors.textPrimary,
                fontSize = KoeFontSizes.xs,
                fontWeight = FontWeight.SemiBold,
                maxLines = 1,
            )
        }
    }
}

@Composable
private fun DockedBottomChrome(
    store: HostSessionStore,
    onOpenRecord: (String) -> Unit,
    workspace: AndroidModeWorkspaceRoute?,
) {
    val navigation by store.navigation.collectAsStateWithLifecycle()
    val colors = KoeTheme.colors

    Column(modifier = Modifier.fillMaxWidth().background(colors.bgPanel)) {
        navigation.effectiveError?.let { errorMessage ->
            Surface(
                shape = KoeShapes.card,
                color = colors.surface1,
                border = BorderStroke(1.dp, colors.danger.copy(alpha = 0.4f)),
                modifier = Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 4.dp),
            ) {
                Row(
                    modifier = Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 10.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    Icon(Icons.Outlined.WarningAmber, contentDescription = null, tint = colors.danger, modifier = Modifier.size(18.dp))
                    Text(
                        text = errorMessage,
                        color = colors.textPrimary,
                        fontSize = KoeFontSizes.xs,
                        maxLines = 2,
                        overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.weight(1f),
                    )
                    KoePrimaryButton(title = "知道了", isPrimary = false, onClick = { store.clearError() })
                }
            }
        }

        val notice = navigation.notice
        var dismissed by rememberSaveable(notice) { mutableStateOf(false) }
        if (!notice.isNullOrBlank() && !dismissed) {
            Row(
                modifier = Modifier.fillMaxWidth().padding(start = 16.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(notice, modifier = Modifier.weight(1f), color = colors.success, fontSize = KoeFontSizes.xs)
                IconButton(onClick = { dismissed = true }) {
                    Icon(Icons.Outlined.Close, contentDescription = "关闭提示")
                }
            }
        }

        AndroidLiveCaptionBar(
            store = store,
            onOpenRecord = onOpenRecord,
            modifier = Modifier.padding(horizontal = 12.dp, vertical = 4.dp),
        )
        AndroidActiveCaptureBar(
            store = store,
            workspaceMode = workspace?.mode,
            modifier = Modifier.padding(horizontal = 12.dp, vertical = 4.dp),
        )
        UndoTrashBar(store = store)
    }
}

@Composable
private fun UndoTrashBar(store: HostSessionStore) {
    val navigation by store.navigation.collectAsStateWithLifecycle()
    val undo = navigation.undoTrash ?: return
    val colors = KoeTheme.colors

    LaunchedEffect(undo.recordId) {
        delay(8_000L)
        if (store.navigation.value.undoTrash?.recordId == undo.recordId) {
            store.send(HostCommand.DismissUndoTrash)
        }
    }

    Surface(
        shape = KoeShapes.card,
        color = colors.surface1,
        border = BorderStroke(1.dp, colors.border),
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 12.dp, vertical = 4.dp)
            .testTag("undo-trash-bar"),
    ) {
        Row(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 10.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Icon(Icons.Outlined.DeleteOutline, contentDescription = null, tint = colors.textSecondary, modifier = Modifier.size(18.dp))
            Text(
                text = "已移入回收站  ${undo.title}",
                color = colors.textPrimary,
                fontSize = KoeFontSizes.xs,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.weight(1f),
            )
            KoePrimaryButton(
                title = "撤销",
                isPrimary = true,
                onClick = {
                    val ids = undo.effectiveRecordIds
                    if (ids.size > 1) store.send(HostCommand.BatchRestoreRecords(ids))
                    else store.send(HostCommand.RestoreRecord(undo.recordId))
                },
            )
        }
    }
}
