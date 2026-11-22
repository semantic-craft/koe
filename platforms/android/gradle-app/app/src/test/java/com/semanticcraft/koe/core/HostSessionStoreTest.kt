package com.semanticcraft.koe.core

import com.semanticcraft.koe.bridge.KoeNativeBridge
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.charset.StandardCharsets
import java.nio.file.Files
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class HostSessionStoreTest {
    private class FakeHostBridgeClient(
        var version: Int = 2,
        var nextHandle: Long = 1001L,
        var snapshotJson: String? = null,
        var dispatchHandler: (String, Long) -> String? = { _, _ -> snapshotJson },
        var outboundBleBytes: ByteArray = ByteArray(0),
    ) : HostBridgeClient {
        val dispatchedCommands = mutableListOf<String>()
        var destroyedHandle: Long? = null

        override fun apiVersion(): Int = version

        override fun sessionCreate(directory: String): Long = nextHandle

        override fun sessionCreateWithCredentials(
            directory: String,
            credentialBridge: KoeNativeBridge.CredentialBridge,
            isolated: Boolean,
        ): Long = nextHandle

        override fun sessionDestroy(handle: Long): Boolean {
            destroyedHandle = handle
            return true
        }

        override fun sessionGeneration(handle: Long): Long = 0L

        override fun sessionSnapshotJson(handle: Long, nowEpochSec: Long): String? = snapshotJson

        override fun sessionDispatchJson(handle: Long, commandJson: String, nowEpochSec: Long): String? {
            dispatchedCommands.add(commandJson)
            return dispatchHandler(commandJson, nowEpochSec)
        }

        override fun sessionIngestBle(handle: Long, bytes: ByteArray, nowEpochSec: Long): Long = 0L

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
        ): PcmIngestReceipt = PcmIngestReceipt(1L, sequence + 1L, PcmIngestStatus.ACCEPTED)

        override fun sessionReportPlaybackProgress(
            handle: Long,
            recordId: String,
            requestId: Long,
            positionMs: Long,
            isPlaying: Boolean,
            lastProjectedNowSec: Long,
            nowEpochSec: Long,
        ): PlaybackProgressReceipt = PlaybackProgressReceipt(
            generation = 43L,
            prevGeneration = 42L,
            positionMs = positionMs,
            nowEpochSec = nowEpochSec,
            isPlaying = isPlaying,
            applied = true,
            needsFullSnapshot = false,
        )

        override fun sessionDrainBleTx(handle: Long): ByteArray = outboundBleBytes

        override fun sessionDrainLocalAsr(handle: Long): ByteArray = ByteArray(0)

        override fun sessionPollTimers(handle: Long, elapsedMs: Long, nowEpochSec: Long): Long = 0L
    }

    private fun loadRichAndroidSnapshot(): String {
        val stream = checkNotNull(javaClass.classLoader?.getResourceAsStream("android-rich-snapshot.json"))
        return stream.use { String(it.readBytes(), StandardCharsets.UTF_8) }
    }

    @Test
    fun parsesFullV2RustSnapshotAndPopulatesAllSlices() {
        val richJson = loadRichAndroidSnapshot()
        val bridge = FakeHostBridgeClient(snapshotJson = richJson)
        val store = HostSessionStore(
            workspacePath = "/tmp/koe-test-workspace",
            bridge = bridge,
            allowDebugFixture = false,
            clockEpochSec = { 1_800_000_000L },
            clockEpochMs = { 1_800_000_000_000L },
        )

        assertEquals(42L, store.currentGeneration)
        assertEquals("android", store.platform.value.id)
        assertEquals("Android", store.platform.value.hostDisplayName)
        assertFalse(store.platform.value.supportsNativeSpeech)
        assertFalse(store.platform.value.supportsSystemAudio)
        assertFalse(store.platform.value.supportsSelfUpdate)
        assertEquals("Android 本机", store.platform.value.nativeSpeechLabel)

        assertEquals("today", store.navigation.value.section)
        assertEquals("rec-meeting-1", store.navigation.value.selectedRecordId)
        assertTrue(store.navigation.value.hasPlayableDetailAsset)
        assertNull(store.navigation.value.effectiveError)

        assertEquals("this_device", store.today.value.beanControlState)
        assertEquals(2, store.today.value.recordCount)
        assertEquals(1, store.today.value.proposedActionCount)
        assertTrue(store.today.value.deviceConnected)

        assertEquals(1, store.quickNoteWorkspace.value.inboxCount)
        assertEquals("2026-11-20", store.allDayWorkspace.value.selectedDate)
        assertEquals(1, store.allDayWorkspace.value.spans.size)

        // Coverage must be stripped from the low-frequency liveMinutesWorkspace slice.
        assertNull(store.liveMinutesWorkspace.value.coverage)
        assertEquals(98, store.liveMinutesCoverage.value?.transcriptPercent)
        assertEquals("grounded", store.liveMinutesCoverage.value?.consolidationStage)

        assertEquals("rec-meeting-1", store.recordDetail.value.detail?.id)
        assertEquals(1, store.recordDetail.value.recordTasks.size)
        assertEquals(1, store.recordDetail.value.recordMemories.size)
        assertEquals(2, store.records.value.size)
        assertEquals(2, store.tasks.value.size)
        assertEquals(1, store.memories.value.size)
        assertTrue(store.trashRecords.value.isEmpty())
        assertEquals(2, store.ask.value.messages.size)
        assertTrue(store.captureStudio.value.isRecordingLocked)
        assertEquals(85, store.device.value.batteryPercent)
        assertEquals(72, store.device.value.boxBatteryPercent)
        assertEquals("2.7.1", store.settings.value.appUpdate.currentVersion)
        assertEquals(12_000L, store.playback.value.positionMs)
        assertEquals(CaptureMode.MEETING, store.activeCapture.value?.mode)
        assertEquals("实时字幕", store.liveCaption.value?.status)
    }

    @Test
    fun enforcesMonotonicGenerationGateAndRejectsIncompatibleVersion() {
        val richJson = loadRichAndroidSnapshot()
        val bridge = FakeHostBridgeClient(snapshotJson = richJson)
        val store = HostSessionStore(
            workspacePath = "/tmp/koe-test-gen",
            bridge = bridge,
            allowDebugFixture = false,
        )
        assertEquals(42L, store.currentGeneration)

        val staleJson = richJson
            .replace("\"generation\": 42,", "\"generation\": 41,")
            .replace("\"section\": \"today\",", "\"section\": \"records\",")
        assertFalse(store.applySnapshotJson(staleJson))
        assertEquals(42L, store.currentGeneration)
        assertEquals("today", store.navigation.value.section)

        val newerJson = richJson
            .replace("\"generation\": 42,", "\"generation\": 43,")
            .replace("\"section\": \"today\",", "\"section\": \"ask\",")
        assertTrue(store.applySnapshotJson(newerJson))
        assertEquals(43L, store.currentGeneration)
        assertEquals("ask", store.navigation.value.section)

        val wrongVersionJson = richJson
            .replace("\"version\": 2,", "\"version\": 3,")
            .replace("\"generation\": 42,", "\"generation\": 99,")
        assertFalse(store.applySnapshotJson(wrongVersionJson))
        assertEquals(43L, store.currentGeneration)
        assertEquals("数据引擎返回了不兼容的版本。", store.navigation.value.effectiveError)
    }

    @Test
    fun rejectsDebugSnapshotFixtureWhenAllowDebugFixtureIsFalse() {
        val richJson = loadRichAndroidSnapshot()
        val bridge = FakeHostBridgeClient()
        val releaseStore = HostSessionStore(
            workspacePath = "/tmp/koe-release",
            bridge = bridge,
            allowDebugFixture = false,
            autoOpen = false,
        )
        assertFalse(releaseStore.loadDebugSnapshotFixtureJson(richJson))
        assertEquals(0L, releaseStore.currentGeneration)
        assertTrue(releaseStore.records.value.isEmpty())

        val debugStore = HostSessionStore(
            workspacePath = "/tmp/koe-debug",
            bridge = bridge,
            allowDebugFixture = true,
            autoOpen = false,
        )
        assertTrue(debugStore.loadDebugSnapshotFixtureJson(richJson))
        assertEquals(42L, debugStore.currentGeneration)
        assertEquals(2, debugStore.records.value.size)
    }

    @Test
    fun encodesAndroidMetadataAndHostCommandsMatchingRustSchema() {
        val syncEvent = HostAdapterEvent.SyncAppMetadata(
            version = "2.7.1",
            build = "17",
            platform = "android",
            hostDisplayName = "Android",
            supportsSystemAudio = false,
            supportsSelfUpdate = false,
            nativeSpeechLabel = "Android 本机",
        )
        val syncObj = HostJson.json.parseToJsonElement(syncEvent.toJsonString()) as JsonObject
        assertEquals("sync_app_metadata", syncObj["type"]?.jsonPrimitive?.content)
        assertEquals("2.7.1", syncObj["version"]?.jsonPrimitive?.content)
        assertEquals("17", syncObj["build"]?.jsonPrimitive?.content)
        assertEquals("android", syncObj["platform"]?.jsonPrimitive?.content)
        assertEquals("Android", syncObj["hostDisplayName"]?.jsonPrimitive?.content)
        assertEquals(false, syncObj["supportsSystemAudio"]?.jsonPrimitive?.boolean)
        assertEquals(false, syncObj["supportsSelfUpdate"]?.jsonPrimitive?.boolean)
        assertEquals("Android 本机", syncObj["nativeSpeechLabel"]?.jsonPrimitive?.content)
        assertFalse(syncObj.containsKey("eventType"))

        val releaseObj = HostJson.json.parseToJsonElement(HostCommand.DeviceRelease.toJsonString()) as JsonObject
        assertEquals(setOf("type"), releaseObj.keys)
        assertEquals("device_release", releaseObj["type"]?.jsonPrimitive?.content)

        for ((decision, verb) in listOf(
            ReviewDecision.ACCEPT to "accept", ReviewDecision.DISMISS to "dismiss", ReviewDecision.RESET to "reset",
        )) {
            val command = HostCommand.ReviewItem("item", decision)
            val json = HostJson.json.parseToJsonElement(command.toJsonString()) as JsonObject
            assertEquals("review_item", json["type"]?.jsonPrimitive?.content)
            assertEquals("item", json["itemId"]?.jsonPrimitive?.content)
            assertEquals(verb, json["decision"]?.jsonPrimitive?.content)
        }

        val noteCmd = HostCommand.CreateNote(title = "闪记标题", text = "内容正文", stayOnPage = true)
        val noteObj = HostJson.json.parseToJsonElement(noteCmd.toJsonString()) as JsonObject
        assertEquals(setOf("type", "title", "text", "stayOnPage"), noteObj.keys)
        assertEquals("create_note", noteObj["type"]?.jsonPrimitive?.content)
        assertEquals("闪记标题", noteObj["title"]?.jsonPrimitive?.content)
        assertEquals("内容正文", noteObj["text"]?.jsonPrimitive?.content)
        assertEquals(true, noteObj["stayOnPage"]?.jsonPrimitive?.boolean)

        val trashObj = HostJson.json.parseToJsonElement(HostCommand.TrashRecord("rec-1").toJsonString()) as JsonObject
        assertEquals(setOf("type", "recordId"), trashObj.keys)
        assertEquals("trash_record", trashObj["type"]?.jsonPrimitive?.content)
        assertEquals("rec-1", trashObj["recordId"]?.jsonPrimitive?.content)

        val captureObj = HostJson.json.parseToJsonElement(
            HostCommand.StartCaptureMode(mode = CaptureMode.QUICK_NOTE, stayOnPage = true).toJsonString(),
        ) as JsonObject
        assertEquals("start_capture_mode", captureObj["type"]?.jsonPrimitive?.content)
        assertEquals("quick_note", captureObj["mode"]?.jsonPrimitive?.content)
        assertEquals(true, captureObj["stayOnPage"]?.jsonPrimitive?.boolean)

        val actionObj = HostJson.json.parseToJsonElement(
            HostCommand.CaptureActionCommand(action = CaptureAction.RETRY_SAVE).toJsonString(),
        ) as JsonObject
        assertEquals("capture_action", actionObj["type"]?.jsonPrimitive?.content)
        assertEquals("retry_save", actionObj["action"]?.jsonPrimitive?.content)
    }

    @Test
    fun traceRingBufferCapsAt20EntriesAndNeverLeaksSecretsOrTranscripts() {
        val richJson = loadRichAndroidSnapshot()
        val bridge = FakeHostBridgeClient(snapshotJson = richJson)
        var tickMs = 1_800_000_000_000L
        val store = HostSessionStore(
            workspacePath = "/tmp/koe-trace",
            bridge = bridge,
            allowDebugFixture = true,
            clockEpochSec = { 1_800_000_000L },
            clockEpochMs = {
                tickMs += 10L
                tickMs
            },
        )

        val qwenSecret = "sk-qwen-never-leak-123456"
        val deepseekSecret = "sk-deepseek-never-leak-654321"
        val sensitiveTitle = "绝密项目复盘"
        val sensitiveBody = "这是绝密会议逐字稿正文内容"

        repeat(22) { index ->
            store.send(HostCommand.Navigate(if (index % 2 == 0) "today" else "records"))
        }
        store.send(
            HostCommand.ConfigureProvider(
                apiKey = qwenSecret,
                deepseekApiKey = deepseekSecret,
                model = "deepseek-flash",
            ),
        )
        store.send(HostCommand.CreateNote(title = sensitiveTitle, text = sensitiveBody, stayOnPage = true))

        val entries = store.recentTraceEntries()
        assertEquals(20, entries.size)
        assertEquals("configure_provider", entries[entries.size - 2].name)
        assertEquals("create_note", entries.last().name)

        val traceJson = store.exportTraceJson()
        val decoded = HostJson.json.decodeFromString(ListSerializer(HostTraceEntry.serializer()), traceJson)
        assertEquals(20, decoded.size)

        val tempDir = Files.createTempDirectory("koe-trace-test").toFile()
        try {
            val outFile = File(tempDir, "host-trace.json")
            assertTrue(store.writeTraceAtomically(outFile))
            val fileText = outFile.readText(StandardCharsets.UTF_8)
            assertEquals(traceJson, fileText)
            for (forbidden in listOf(
                qwenSecret,
                deepseekSecret,
                sensitiveTitle,
                sensitiveBody,
                "Android 架构同步会",
            )) {
                assertFalse("trace must not contain $forbidden", traceJson.contains(forbidden))
                assertFalse("trace file must not contain $forbidden", fileText.contains(forbidden))
            }
        } finally {
            tempDir.deleteRecursively()
        }
    }

    @Test
    fun drainsLengthPrefixedBleFramesAndFormatsTimeLabels() {
        val frame1 = byteArrayOf(0x01, 0x02, 0x03)
        val frame2 = byteArrayOf(0x0A, 0x0B)
        val packed = ByteBuffer.allocate(4 + frame1.size + 4 + frame2.size)
            .order(ByteOrder.LITTLE_ENDIAN)
            .putInt(frame1.size)
            .put(frame1)
            .putInt(frame2.size)
            .put(frame2)
            .array()

        val bridge = FakeHostBridgeClient(
            snapshotJson = loadRichAndroidSnapshot(),
            outboundBleBytes = packed,
        )
        val store = HostSessionStore(workspacePath = "/tmp/koe-ble", bridge = bridge)
        val drained = store.drainOutboundBleFrames()
        assertEquals(2, drained.size)
        assertNotNull(drained[0])
        assertTrue(frame1.contentEquals(drained[0]))
        assertTrue(frame2.contentEquals(drained[1]))

        assertEquals("00:00", TimeLabel.duration(0L))
        assertEquals("00:42", TimeLabel.duration(42_000L))
        assertEquals("03:05", TimeLabel.duration(185_000L))
    }

    @Test
    fun performCaptureActionRoutesResumeToBridgeAndFlushesBleForOtherActions() {
        val fixture = HostJson.json.decodeFromString(HostSnapshot.serializer(), loadRichAndroidSnapshot())
        val microphoneCapture = fixture.copy(capture = fixture.capture.copy(activeSource = "system_default"))
        val bridge = FakeHostBridgeClient(snapshotJson = HostJson.json.encodeToString(HostSnapshot.serializer(), microphoneCapture))
        val store = HostSessionStore(workspacePath = "/tmp/koe-capture-routing", bridge = bridge)
        var resumeCount = 0
        var flushCount = 0
        store.bridgeActions = HostBridgeActions(
            resumeMicrophone = { resumeCount += 1 },
            flushBleOutbound = { flushCount += 1 },
        )

        store.performCaptureAction(CaptureAction.RESUME)

        assertEquals(1, resumeCount)
        assertEquals(0, flushCount)
        assertTrue(bridge.dispatchedCommands.isEmpty())

        store.performCaptureAction(CaptureAction.PAUSE)
        store.performCaptureAction(CaptureAction.END)
        store.startCapture(CaptureMode.MEETING, stayOnPage = true)
        store.toggleModeSession(
            ModePickerCardSnapshot(
                id = "quick_note",
                mode = "quick_note",
                title = "随心闪记",
                subtitle = "快速留下一段想法",
                isSessionActive = false,
            ),
        )
        store.toggleModeSession(
            ModePickerCardSnapshot(
                id = "quick_note",
                mode = "quick_note",
                title = "随心闪记",
                subtitle = "快速留下一段想法",
                isSessionActive = true,
            ),
        )

        assertEquals(1, resumeCount)
        assertEquals(5, flushCount)
        val parsed = bridge.dispatchedCommands.map {
            HostJson.json.parseToJsonElement(it) as JsonObject
        }
        assertEquals(5, parsed.size)
        assertEquals("capture_action", parsed[0]["type"]?.jsonPrimitive?.content)
        assertEquals("pause", parsed[0]["action"]?.jsonPrimitive?.content)
        assertEquals("capture_action", parsed[1]["type"]?.jsonPrimitive?.content)
        assertEquals("end", parsed[1]["action"]?.jsonPrimitive?.content)
        assertEquals("start_capture_mode", parsed[2]["type"]?.jsonPrimitive?.content)
        assertEquals("meeting", parsed[2]["mode"]?.jsonPrimitive?.content)
        assertEquals(true, parsed[2]["stayOnPage"]?.jsonPrimitive?.boolean)
        assertEquals("start_capture_mode", parsed[3]["type"]?.jsonPrimitive?.content)
        assertEquals("quick_note", parsed[3]["mode"]?.jsonPrimitive?.content)
        assertEquals("capture_action", parsed[4]["type"]?.jsonPrimitive?.content)
        assertEquals("end", parsed[4]["action"]?.jsonPrimitive?.content)
    }
}
