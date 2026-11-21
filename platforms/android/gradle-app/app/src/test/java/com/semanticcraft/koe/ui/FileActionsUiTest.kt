package com.semanticcraft.koe.ui

import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.test.performSemanticsAction
import com.semanticcraft.koe.bridge.KoeNativeBridge
import com.semanticcraft.koe.core.AllDayWorkspaceSnapshot
import com.semanticcraft.koe.core.HostBridgeActions
import com.semanticcraft.koe.core.HostBridgeClient
import com.semanticcraft.koe.core.HostJson
import com.semanticcraft.koe.core.HostSessionStore
import com.semanticcraft.koe.core.HostSnapshot
import com.semanticcraft.koe.core.ModeWorkspacesSnapshot
import com.semanticcraft.koe.core.PcmIngestReceipt
import com.semanticcraft.koe.core.PcmIngestStatus
import com.semanticcraft.koe.core.PlaybackProgressReceipt
import com.semanticcraft.koe.core.RecordDetailSnapshot
import com.semanticcraft.koe.core.RecordSnapshot
import com.semanticcraft.koe.ui.screens.AndroidModeWorkspaceRoute
import com.semanticcraft.koe.ui.screens.ModeWorkspacesScreen
import com.semanticcraft.koe.ui.screens.RecordDetailScreen
import com.semanticcraft.koe.ui.screens.RecordsScreen
import com.semanticcraft.koe.ui.theme.KoeTheme
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], qualifiers = "w412dp-h915dp-xhdpi")
class FileActionsUiTest {
    @get:Rule
    val composeRule = createRobolectricComposeRule()

    private class StaticSnapshotBridge(
        private var current: HostSnapshot,
    ) : HostBridgeClient {
        override fun apiVersion(): Int = 2
        override fun sessionCreate(directory: String): Long = 303L
        override fun sessionCreateWithCredentials(
            directory: String,
            credentialBridge: KoeNativeBridge.CredentialBridge,
            isolated: Boolean,
        ): Long = 303L

        override fun sessionDestroy(handle: Long): Boolean = true
        override fun sessionGeneration(handle: Long): Long = current.generation
        override fun sessionSnapshotJson(handle: Long, nowEpochSec: Long): String =
            HostJson.json.encodeToString(HostSnapshot.serializer(), current)

        override fun sessionDispatchJson(handle: Long, commandJson: String, nowEpochSec: Long): String {
            current = current.copy(generation = current.generation + 1L)
            return sessionSnapshotJson(handle, nowEpochSec)
        }

        override fun sessionIngestBle(handle: Long, bytes: ByteArray, nowEpochSec: Long): Long = current.generation
        override fun sessionIngestPcm(
            handle: Long,
            recordId: String,
            sessionId: String,
            lane: String,
            sequence: Long,
            epoch: Long,
            capturedStartNs: Long?,
            samples: ShortArray,
            sampleCount: Int,
            nowEpochSec: Long,
        ): PcmIngestReceipt = PcmIngestReceipt(current.generation, 0L, PcmIngestStatus.REJECTED)

        override fun sessionReportPlaybackProgress(
            handle: Long,
            recordId: String,
            requestId: Long,
            positionMs: Long,
            isPlaying: Boolean,
            lastProjectedNowSec: Long,
            nowEpochSec: Long,
        ): PlaybackProgressReceipt = PlaybackProgressReceipt(
            current.generation, current.generation, positionMs, nowEpochSec, isPlaying, true, false,
        )

        override fun sessionDrainBleTx(handle: Long): ByteArray = ByteArray(0)
        override fun sessionDrainLocalAsr(handle: Long): ByteArray = ByteArray(0)
        override fun sessionPollTimers(handle: Long, elapsedMs: Long, nowEpochSec: Long): Long = current.generation
    }

    @Test
    fun recordsScreenImportAndBatchExportButtonsInvokeBridgeActions() {
        val records = listOf(
            RecordSnapshot(
                id = "rec-1",
                title = "周会纪要",
                createdAtEpochSec = 1763596800L,
                status = "已完成",
                mode = "meeting",
            ),
            RecordSnapshot(
                id = "rec-2",
                title = "灵感闪记",
                createdAtEpochSec = 1763597800L,
                status = "已保存",
                mode = "quick_note",
            ),
        )
        val store = HostSessionStore(
            workspacePath = "/tmp/koe-ui-records-files",
            bridge = StaticSnapshotBridge(HostSnapshot.empty.copy(generation = 1L, records = records)),
        )
        var importCalls = 0
        val exportedBatches = mutableListOf<List<String>>()
        store.bridgeActions = HostBridgeActions(
            requestImportFile = { importCalls += 1 },
            requestExportRecords = { ids -> exportedBatches.add(ids) },
        )

        composeRule.setContent {
            KoeTheme {
                RecordsScreen(store = store, onSelectRecord = {})
            }
        }

        composeRule.onNodeWithTag("records-import-button")
            .assertIsDisplayed()
            .performSemanticsAction(SemanticsActions.OnClick)
        composeRule.onNodeWithTag("records-export-batch-button")
            .assertIsDisplayed()
            .performSemanticsAction(SemanticsActions.OnClick)
        composeRule.waitForIdle()

        assertEquals(1, importCalls)
        assertEquals(listOf(listOf("rec-1", "rec-2")), exportedBatches)
    }

    @Test
    fun recordsScreenHidesBatchExportWhenEmptyButKeepsImportVisible() {
        val store = HostSessionStore(
            workspacePath = "/tmp/koe-ui-records-empty",
            bridge = StaticSnapshotBridge(HostSnapshot.empty.copy(generation = 1L, records = emptyList())),
        )

        composeRule.setContent {
            KoeTheme {
                RecordsScreen(store = store, onSelectRecord = {})
            }
        }

        composeRule.onNodeWithTag("records-import-button").assertIsDisplayed()
        composeRule.onNodeWithTag("records-export-batch-button").assertDoesNotExist()
    }

    @Test
    fun recordDetailScreenExportButtonInvokesWorkspaceExport() {
        val detail = RecordDetailSnapshot(
            id = "rec-42",
            title = "季度复盘",
            createdAtEpochSec = 1763596800L,
            durationMs = 120_000L,
            source = "本机麦克风",
            status = "已完成",
            mode = "meeting",
        )
        val store = HostSessionStore(
            workspacePath = "/tmp/koe-ui-detail-export",
            bridge = StaticSnapshotBridge(HostSnapshot.empty.copy(generation = 1L, detail = detail)),
        )
        val calls = mutableListOf<Triple<String?, String?, String>>()
        store.bridgeActions = HostBridgeActions(
            requestExportWorkspace = { recordId, date, filename, _ ->
                calls.add(Triple(recordId, date, filename))
            },
        )

        composeRule.setContent {
            KoeTheme {
                RecordDetailScreen(store = store, recordId = "rec-42")
            }
        }

        composeRule.onNodeWithTag("detail-export-button")
            .performScrollTo()
            .assertIsDisplayed()
            .performSemanticsAction(SemanticsActions.OnClick)
        composeRule.waitForIdle()

        assertEquals(listOf(Triple("rec-42", null, "季度复盘.md")), calls)
    }

    @Test
    fun allDayWorkspaceExportButtonInvokesDateExportAndHidesWhenDateBlank() {
        val store = HostSessionStore(
            workspacePath = "/tmp/koe-ui-allday-export",
            bridge = StaticSnapshotBridge(
                HostSnapshot.empty.copy(
                    generation = 1L,
                    workspaces = ModeWorkspacesSnapshot.empty.copy(
                        allDay = AllDayWorkspaceSnapshot(selectedDate = "2026-11-20", eventCount = 2),
                    ),
                ),
            ),
        )
        val calls = mutableListOf<Triple<String?, String?, String>>()
        store.bridgeActions = HostBridgeActions(
            requestExportWorkspace = { recordId, date, filename, _ ->
                calls.add(Triple(recordId, date, filename))
            },
        )

        composeRule.setContent {
            KoeTheme {
                ModeWorkspacesScreen(
                    store = store,
                    route = AndroidModeWorkspaceRoute.ALL_DAY,
                    onSelectRecord = {},
                )
            }
        }

        composeRule.onNodeWithTag("all-day-export-button")
            .assertIsDisplayed()
            .performSemanticsAction(SemanticsActions.OnClick)
        composeRule.waitForIdle()

        assertEquals(listOf(Triple(null, "2026-11-20", "Koe-2026-11-20.md")), calls)
    }

    @Test
    fun allDayWorkspaceHidesExportButtonWhenSelectedDateBlank() {
        val store = HostSessionStore(
            workspacePath = "/tmp/koe-ui-allday-blank",
            bridge = StaticSnapshotBridge(
                HostSnapshot.empty.copy(
                    generation = 1L,
                    workspaces = ModeWorkspacesSnapshot.empty.copy(
                        allDay = AllDayWorkspaceSnapshot(selectedDate = "   "),
                    ),
                ),
            ),
        )

        composeRule.setContent {
            KoeTheme {
                ModeWorkspacesScreen(
                    store = store,
                    route = AndroidModeWorkspaceRoute.ALL_DAY,
                    onSelectRecord = {},
                )
            }
        }

        composeRule.onNodeWithTag("all-day-export-button").assertDoesNotExist()
    }
}
