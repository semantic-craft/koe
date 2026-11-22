package com.semanticcraft.koe.ui.screens

import android.os.Bundle
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.consumeWindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.ime
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ArrowBack
import androidx.compose.material.icons.outlined.AutoAwesome
import androidx.compose.material.icons.outlined.Checklist
import androidx.compose.material.icons.outlined.GridView
import androidx.compose.material.icons.outlined.Inbox
import androidx.compose.material.icons.outlined.Settings
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.NavigationBarItemDefaults
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.Saver
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshots.SnapshotStateMap
import androidx.compose.ui.Alignment
import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalDensity
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
import com.semanticcraft.koe.ui.leaves.AndroidMiniPlayerBar
import com.semanticcraft.koe.ui.theme.KoeFontSizes
import com.semanticcraft.koe.ui.theme.KoeTheme

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
        if (topRoute != AndroidDetailRoute.Record(source.recordId)) pushRoute(AndroidDetailRoute.Record(source.recordId))
    }

    val topTitle = when (topRoute) {
        is AndroidDetailRoute.Record -> navigation.detailTitle ?: "记录详情"
        is AndroidDetailRoute.Workspace -> topRoute.route.title
        null -> selectedTab.label
    }

    BoxWithConstraints(modifier = modifier.fillMaxSize().semantics { testTagsAsResourceId = true }) {
        val compactLandscape = maxWidth >= 600.dp && maxHeight < 600.dp
        val landscapeKeyboard = rememberLandscapeKeyboardVisible(
            compactLandscape && selectedTab == AndroidAppTab.ASK && topRoute == null,
        )
        Scaffold(
            containerColor = colors.bgPanel,
            topBar = {
                if (landscapeKeyboard) return@Scaffold
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
                                store = store,
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
                val openTab: (AndroidAppTab) -> Unit = { tab ->
                    if (selectedTab == tab) tabStacks[tab] = emptyList() else selectedTab = tab
                }
                val captureWorkspace = (topRoute as? AndroidDetailRoute.Workspace)?.route
                val visibleRecord = (topRoute as? AndroidDetailRoute.Record)?.recordId
                val showDock = (navigation.activeCaptureMode != null && navigation.activeCaptureMode != captureWorkspace?.mode) ||
                    navigation.hasLiveCaption ||
                    navigation.effectiveError != null || navigation.notice != null || navigation.undoTrash != null
                if (landscapeKeyboard) return@Scaffold
                if (compactLandscape && showDock) {
                    Row(Modifier.fillMaxWidth().navigationBarsPadding(), verticalAlignment = Alignment.Bottom) {
                        Box(Modifier.weight(2f)) { DockedBottomChrome(store, navigation, ::openRecord, captureWorkspace, compact = true) }
                        Column(Modifier.weight(1f)) {
                            AndroidMiniPlayerBar(store, visibleRecord, ::openRecord)
                            TabNavigationBar(selectedTab, openTab)
                        }
                    }
                } else {
                    Column(modifier = Modifier.fillMaxWidth()) {
                        AndroidMiniPlayerBar(store, visibleRecord, ::openRecord)
                        DockedBottomChrome(store, navigation, ::openRecord, captureWorkspace)
                        HorizontalDivider(color = colors.border)
                        TabNavigationBar(selectedTab, openTab)
                    }
                }
            },
        ) { innerPadding ->
            Box(Modifier.fillMaxSize().padding(innerPadding).consumeWindowInsets(innerPadding), contentAlignment = Alignment.TopCenter) {
                val liveMeeting = (topRoute as? AndroidDetailRoute.Workspace)?.route == AndroidModeWorkspaceRoute.LIVE_MINUTES
                val readingWidth = if (liveMeeting) Modifier else Modifier.widthIn(max = 840.dp)
                Box(readingWidth.fillMaxSize()) {
                    when (topRoute) {
                        is AndroidDetailRoute.Record -> RecordDetailScreen(
                            store, topRoute.recordId, compact = compactLandscape, onOpenSource = ::openSource, onTrashed = ::popCurrentTab,
                            onAsk = {
                                tabStacks[AndroidAppTab.ASK] = emptyList()
                                selectedTab = AndroidAppTab.ASK
                            },
                        )
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
                            AndroidAppTab.ASK -> AskScreen(store, ::openSource, compact = compactLandscape)
                        }
                    }
                }
            }
        }

        when (activeSheet) {
            AndroidRootSheet.DEVICE -> DeviceSheet(store, onDismiss = { activeSheet = AndroidRootSheet.NONE }, onOpenRecord = ::openRecord)
            AndroidRootSheet.SETTINGS -> SettingsSheet(store = store, onDismiss = { activeSheet = AndroidRootSheet.NONE })
            AndroidRootSheet.CAPTURE_SOURCE -> CaptureSourceSheet(store) { activeSheet = AndroidRootSheet.NONE }
            AndroidRootSheet.NONE -> Unit
        }
    }
}

@Composable
private fun TabNavigationBar(selectedTab: AndroidAppTab, onSelect: (AndroidAppTab) -> Unit) {
    val colors = KoeTheme.colors
    NavigationBar(containerColor = colors.surface0, tonalElevation = 0.dp) {
        AndroidAppTab.entries.forEach { tab ->
            val selected = selectedTab == tab
            NavigationBarItem(
                modifier = Modifier.testTag("tab-" + tab.name.lowercase()),
                selected = selected,
                onClick = {
                    onSelect(tab)
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

@Composable
private fun rememberLandscapeKeyboardVisible(enabled: Boolean): Boolean {
    if (!enabled) return false
    val density = LocalDensity.current
    val ime = WindowInsets.ime
    return remember(ime, density) {
        derivedStateOf { ime.getBottom(density) > 0 }
    }.value
}
