package com.semanticcraft.koe.ui

import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.hasAnyAncestor
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.isDialog
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.test.performSemanticsAction
import com.semanticcraft.koe.bridge.KoeNativeBridge
import com.semanticcraft.koe.core.DeviceGuideSnapshot
import com.semanticcraft.koe.core.DeviceSnapshot
import com.semanticcraft.koe.core.HostBridgeActions
import com.semanticcraft.koe.core.HostBridgeClient
import com.semanticcraft.koe.core.HostJson
import com.semanticcraft.koe.core.HostSessionStore
import com.semanticcraft.koe.core.HostSnapshot
import com.semanticcraft.koe.core.PcmIngestReceipt
import com.semanticcraft.koe.core.PcmIngestStatus
import com.semanticcraft.koe.core.PlaybackProgressReceipt
import com.semanticcraft.koe.ui.screens.DeviceSheet
import com.semanticcraft.koe.ui.theme.KoeTheme
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], qualifiers = "w412dp-h915dp-xhdpi")
class DeviceSheetBleActionsTest {
    @get:Rule
    val composeRule = createComposeRule()

    private class RecordingBridgeClient(
        private var current: HostSnapshot,
    ) : HostBridgeClient {
        val dispatchedTypes = mutableListOf<String>()

        override fun apiVersion(): Int = 2
        override fun sessionCreate(directory: String): Long = 202L
        override fun sessionCreateWithCredentials(
            directory: String,
            credentialBridge: KoeNativeBridge.CredentialBridge,
            isolated: Boolean,
        ): Long = 202L

        override fun sessionDestroy(handle: Long): Boolean = true
        override fun sessionGeneration(handle: Long): Long = current.generation
        override fun sessionSnapshotJson(handle: Long, nowEpochSec: Long): String =
            HostJson.json.encodeToString(HostSnapshot.serializer(), current)

        override fun sessionDispatchJson(handle: Long, commandJson: String, nowEpochSec: Long): String {
            val obj = HostJson.json.parseToJsonElement(commandJson) as JsonObject
            obj["type"]?.jsonPrimitive?.content?.let { dispatchedTypes.add(it) }
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
    fun disconnectedDeviceSheetConnectAndRescanButtonsTriggerBleScan() {
        val bridge = RecordingBridgeClient(
            HostSnapshot.empty.copy(
                generation = 1L,
                device = DeviceSnapshot.empty.copy(connected = false, busy = false),
            ),
        )
        val store = HostSessionStore(workspacePath = "/tmp/koe-device-sheet-test", bridge = bridge)
        var scanRequests = 0
        store.bridgeActions = HostBridgeActions(requestBleScan = { scanRequests += 1 })

        composeRule.setContent {
            KoeTheme {
                DeviceSheet(store = store, onDismiss = {})
            }
        }

        composeRule.onNodeWithTag("device-connect-button")
            .performScrollTo()
            .assertIsDisplayed()
            .performSemanticsAction(SemanticsActions.OnClick)
        composeRule.waitForIdle()

        assertTrue("device_open_guide" in bridge.dispatchedTypes)
        assertEquals(1, scanRequests)

        composeRule.onNodeWithTag("device-rescan-button")
            .performScrollTo()
            .assertIsDisplayed()
            .performSemanticsAction(SemanticsActions.OnClick)
        composeRule.waitForIdle()

        assertEquals(2, scanRequests)
    }

    @Test
    fun connectGuidePrimaryButtonRequestsBleScanInsteadOfOnboardingNext() {
        val connectGuide = DeviceGuideSnapshot(
            mode = "connect",
            step = 1,
            totalSteps = 2,
            title = "连接录音豆",
            subtitle = "短按充电仓按钮开启广播",
            primaryLabel = "开始扫描录音豆",
        )
        val bridge = RecordingBridgeClient(
            HostSnapshot.empty.copy(
                generation = 1L,
                device = DeviceSnapshot.empty.copy(connected = false, guide = connectGuide),
            ),
        )
        val store = HostSessionStore(workspacePath = "/tmp/koe-device-guide-connect", bridge = bridge)
        var scanRequests = 0
        store.bridgeActions = HostBridgeActions(requestBleScan = { scanRequests += 1 })

        composeRule.setContent {
            KoeTheme {
                DeviceSheet(store = store, onDismiss = {})
            }
        }

        composeRule.onNode(hasAnyAncestor(isDialog()) and hasText("开始扫描录音豆"))
            .performScrollTo()
            .performSemanticsAction(SemanticsActions.OnClick)
        composeRule.waitForIdle()

        assertEquals(1, scanRequests)
        assertFalse("device_onboarding_next" in bridge.dispatchedTypes)
    }

    @Test
    fun onboardingGuidePrimaryButtonDispatchesOnboardingNext() {
        val onboardingGuide = DeviceGuideSnapshot(
            mode = "onboarding",
            step = 1,
            totalSteps = 3,
            title = "设备已连接",
            subtitle = "查看使用步骤",
            primaryLabel = "下一步引导",
        )
        val bridge = RecordingBridgeClient(
            HostSnapshot.empty.copy(
                generation = 1L,
                device = DeviceSnapshot.empty.copy(connected = true, guide = onboardingGuide),
            ),
        )
        val store = HostSessionStore(workspacePath = "/tmp/koe-device-guide-onboarding", bridge = bridge)
        var scanRequests = 0
        store.bridgeActions = HostBridgeActions(requestBleScan = { scanRequests += 1 })

        composeRule.setContent {
            KoeTheme {
                DeviceSheet(store = store, onDismiss = {})
            }
        }

        composeRule.onNode(hasAnyAncestor(isDialog()) and hasText("下一步引导"))
            .performScrollTo()
            .performSemanticsAction(SemanticsActions.OnClick)
        composeRule.waitForIdle()

        assertEquals(0, scanRequests)
        assertTrue("device_onboarding_next" in bridge.dispatchedTypes)
    }
}
