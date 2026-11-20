package com.semanticcraft.koe.platform.capture

import com.semanticcraft.koe.bridge.KoeNativeBridge
import com.semanticcraft.koe.core.ActiveCaptureSnapshot
import com.semanticcraft.koe.core.CaptureAction
import com.semanticcraft.koe.core.CaptureLaneSnapshot
import com.semanticcraft.koe.core.CaptureMode
import com.semanticcraft.koe.core.HostBridgeActions
import com.semanticcraft.koe.core.HostBridgeClient
import com.semanticcraft.koe.core.HostCommand
import com.semanticcraft.koe.core.HostJson
import com.semanticcraft.koe.core.HostSessionStore
import com.semanticcraft.koe.core.HostSnapshot
import com.semanticcraft.koe.core.MicrophoneSnapshot
import com.semanticcraft.koe.core.PcmIngestReceipt
import com.semanticcraft.koe.core.PcmIngestStatus
import com.semanticcraft.koe.core.PlaybackProgressReceipt
import com.semanticcraft.koe.platform.AndroidHostCoordinator
import com.semanticcraft.koe.platform.TickScheduler
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class AndroidCaptureCoordinatorTest {
    private class ManualTickScheduler : TickScheduler {
        var activeTick: (() -> Unit)? = null

        override fun schedulePeriodic(intervalMs: Long, onTick: () -> Unit): AutoCloseable {
            activeTick = onTick
            return AutoCloseable {
                if (activeTick === onTick) activeTick = null
            }
        }
    }

    private class FakeMicrophoneSource(
        var synchronousGrant: Boolean? = null,
        var sampleRate: Int = 16_000,
    ) : AndroidMicrophoneSource {
        var permissionRequests = 0
        var lastPermissionCallback: ((Boolean) -> Unit)? = null
        var startCount = 0
        var stopCount = 0
        var lastInputId: String? = null
        var lastExpectedSampleRate: Int? = null
        var onChunkCallback: ((CapturedPcm) -> Unit)? = null
        var onFailureCallback: ((String) -> Unit)? = null
        var tailOnStop: List<CapturedPcm> = emptyList()
        var startError: Throwable? = null

        override fun requestPermission(onResult: (Boolean) -> Unit) {
            permissionRequests += 1
            lastPermissionCallback = onResult
            synchronousGrant?.let { onResult(it) }
        }

        override fun start(
            inputId: String,
            expectedSampleRate: Int?,
            onChunk: (CapturedPcm) -> Unit,
            onFailure: (String) -> Unit,
        ): Int {
            startCount += 1
            lastInputId = inputId
            lastExpectedSampleRate = expectedSampleRate
            onChunkCallback = onChunk
            onFailureCallback = onFailure
            startError?.let { throw it }
            return sampleRate
        }

        override fun stop() {
            stopCount += 1
            val tail = tailOnStop
            tailOnStop = emptyList()
            tail.forEach { onChunkCallback?.invoke(it) }
            onChunkCallback = null
            onFailureCallback = null
        }

        fun emit(samples: ShortArray, capturedStartNs: Long) {
            onChunkCallback?.invoke(CapturedPcm(samples, capturedStartNs))
        }
    }

    private class FakeAudioFocusController(
        var grantFocus: Boolean = true,
    ) : AudioFocusController {
        var requestCount = 0
        var abandonCount = 0
        var activeLossCallback: (() -> Unit)? = null

        override fun requestFocus(onFocusLost: () -> Unit): Boolean {
            requestCount += 1
            if (!grantFocus) return false
            activeLossCallback = onFocusLost
            return true
        }

        override fun abandonFocus() {
            abandonCount += 1
            activeLossCallback = null
        }

        fun triggerFocusLoss() {
            activeLossCallback?.invoke()
        }
    }

    private data class IngestedChunk(
        val sequence: Long,
        val epoch: Long,
        val capturedStartNs: Long?,
        val sampleCount: Int,
    )

    private class StatefulCaptureBridgeClient : HostBridgeClient {
        var snapshot: HostSnapshot = HostSnapshot.empty.copy(generation = 1L)
        val dispatchedEvents = mutableListOf<JsonObject>()
        val ingestedChunks = mutableListOf<IngestedChunk>()
        var rejectAtSequence: Long? = null
        private var sessionCounter = 0

        override fun apiVersion(): Int = 2
        override fun sessionCreate(directory: String): Long = 900L
        override fun sessionCreateWithCredentials(
            directory: String,
            credentialBridge: KoeNativeBridge.CredentialBridge,
            isolated: Boolean,
        ): Long = 900L
        override fun sessionDestroy(handle: Long): Boolean = true
        override fun sessionGeneration(handle: Long): Long = snapshot.generation

        override fun sessionSnapshotJson(handle: Long, nowEpochSec: Long): String =
            HostJson.json.encodeToString(HostSnapshot.serializer(), snapshot)

        override fun sessionDispatchJson(handle: Long, commandJson: String, nowEpochSec: Long): String {
            val obj = HostJson.json.parseToJsonElement(commandJson) as JsonObject
            dispatchedEvents.add(obj)
            val type = obj["type"]?.jsonPrimitive?.content
            when (type) {
                "start_capture_mode", "start_microphone" -> {
                    sessionCounter += 1
                    val recordId = "mic-$sessionCounter"
                    val sessionId = "$recordId-session"
                    val inputId = obj["inputId"]?.jsonPrimitive?.content ?: ""
                    val mic = MicrophoneSnapshot(
                        recordId = recordId,
                        sessionId = sessionId,
                        lane = "microphone",
                        inputId = inputId,
                        phase = "starting",
                        nextSequence = 0L,
                        epoch = 0L,
                        clockNs = null,
                        lanes = mapOf("microphone" to CaptureLaneSnapshot(nextSequence = 0L)),
                    )
                    snapshot = snapshot.copy(
                        generation = snapshot.generation + 1L,
                        error = null,
                        microphone = mic,
                        activeCapture = activeCaptureFor(mic),
                    )
                }
                "microphone_prepared" -> {
                    val mic = snapshot.microphone
                    if (mic != null &&
                        mic.recordId == obj["recordId"]?.jsonPrimitive?.content &&
                        mic.sessionId == obj["sessionId"]?.jsonPrimitive?.content &&
                        mic.epoch == obj["epoch"]?.jsonPrimitive?.long &&
                        mic.phase == "starting"
                    ) {
                        val updated = mic.copy(clockNs = obj["clockNs"]?.jsonPrimitive?.long)
                        snapshot = snapshot.copy(
                            generation = snapshot.generation + 1L,
                            microphone = updated,
                            activeCapture = activeCaptureFor(updated),
                        )
                    }
                }
                "microphone_started" -> {
                    val mic = snapshot.microphone
                    val lane = mic?.lanes?.get("microphone")
                    if (mic != null && lane != null) {
                        val rate = obj["sampleRate"]?.jsonPrimitive?.int ?: 16_000
                        val updatedLane = lane.copy(
                            sampleRate = lane.sampleRate ?: rate,
                            started = true,
                        )
                        val updated = mic.copy(
                            phase = if (mic.phase == "starting") "recording" else mic.phase,
                            lanes = mapOf("microphone" to updatedLane),
                        )
                        snapshot = snapshot.copy(
                            generation = snapshot.generation + 1L,
                            microphone = updated,
                            activeCapture = activeCaptureFor(updated),
                        )
                    }
                }
                "pause_microphone" -> {
                    val mic = snapshot.microphone
                    if (mic != null && mic.phase == "recording" && mic.clockNs != null) {
                        val updated = mic.copy(phase = "pausing")
                        snapshot = snapshot.copy(
                            generation = snapshot.generation + 1L,
                            microphone = updated,
                            activeCapture = activeCaptureFor(updated),
                        )
                    }
                }
                "microphone_paused" -> {
                    val mic = snapshot.microphone
                    val lane = mic?.lanes?.get("microphone")
                    val seq = obj["sequence"]?.jsonPrimitive?.long
                    val epoch = obj["epoch"]?.jsonPrimitive?.long
                    if (mic != null && lane != null && mic.phase == "pausing" &&
                        seq == lane.nextSequence && epoch == mic.epoch
                    ) {
                        val updated = mic.copy(phase = "paused")
                        snapshot = snapshot.copy(
                            generation = snapshot.generation + 1L,
                            microphone = updated,
                            activeCapture = activeCaptureFor(updated),
                        )
                    }
                }
                "resume_microphone" -> {
                    val mic = snapshot.microphone
                    val clockNs = obj["clockNs"]?.jsonPrimitive?.long
                    if (mic != null && mic.phase == "paused" && clockNs != null) {
                        val updated = mic.copy(
                            epoch = mic.epoch + 1L,
                            clockNs = clockNs,
                            phase = "recording",
                        )
                        snapshot = snapshot.copy(
                            generation = snapshot.generation + 1L,
                            microphone = updated,
                            activeCapture = activeCaptureFor(updated),
                        )
                    }
                }
                "stop_microphone", "cancel_microphone" -> {
                    val mic = snapshot.microphone
                    if (mic != null) {
                        val updated = mic.copy(
                            phase = if (type == "cancel_microphone") "cancelling" else "stopping",
                        )
                        snapshot = snapshot.copy(
                            generation = snapshot.generation + 1L,
                            microphone = updated,
                            activeCapture = activeCaptureFor(updated),
                        )
                    }
                }
                "capture_action" -> {
                    val action = obj["action"]?.jsonPrimitive?.content
                    val mic = snapshot.microphone
                    if (mic != null) {
                        val nextPhase = when (action) {
                            "pause" -> "pausing"
                            "end" -> "stopping"
                            "cancel" -> "cancelling"
                            else -> mic.phase
                        }
                        val updated = mic.copy(phase = nextPhase)
                        snapshot = snapshot.copy(
                            generation = snapshot.generation + 1L,
                            microphone = updated,
                            activeCapture = activeCaptureFor(updated),
                        )
                    }
                }
                "microphone_failed" -> {
                    val mic = snapshot.microphone
                    val lane = mic?.lanes?.get("microphone")
                    if (mic != null && lane != null) {
                        val msg = obj["message"]?.jsonPrimitive?.content ?: "failed"
                        val updatedLane = lane.copy(interruption = lane.interruption ?: msg)
                        val updated = mic.copy(
                            phase = if (mic.phase == "cancelling") "cancelling" else "stopping",
                            interruption = msg,
                            lanes = mapOf("microphone" to updatedLane),
                        )
                        snapshot = snapshot.copy(
                            generation = snapshot.generation + 1L,
                            microphone = updated,
                            activeCapture = activeCaptureFor(updated),
                        )
                    }
                }
                "microphone_stopped" -> {
                    val mic = snapshot.microphone
                    val lane = mic?.lanes?.get("microphone")
                    val seq = obj["sequence"]?.jsonPrimitive?.long
                    if (mic != null && lane != null && seq == lane.nextSequence) {
                        snapshot = snapshot.copy(
                            generation = snapshot.generation + 1L,
                            microphone = null,
                            activeCapture = null,
                        )
                    }
                }
            }
            return sessionSnapshotJson(handle, nowEpochSec)
        }

        override fun sessionIngestBle(handle: Long, bytes: ByteArray, nowEpochSec: Long): Long = snapshot.generation

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
        ): PcmIngestReceipt {
            val mic = snapshot.microphone ?: return PcmIngestReceipt(snapshot.generation, 0L, PcmIngestStatus.STALE_SESSION)
            val laneState = mic.lanes[lane] ?: return PcmIngestReceipt(snapshot.generation, 0L, PcmIngestStatus.STALE_SESSION)
            if (mic.recordId != recordId || mic.sessionId != sessionId || mic.epoch != epoch) {
                return PcmIngestReceipt(snapshot.generation, laneState.nextSequence, PcmIngestStatus.STALE_SESSION)
            }
            if (rejectAtSequence == sequence || sequence != laneState.nextSequence) {
                snapshot = snapshot.copy(
                    generation = snapshot.generation + 1L,
                    error = "音频块被拒绝",
                )
                return PcmIngestReceipt(snapshot.generation, laneState.nextSequence, PcmIngestStatus.REJECTED)
            }
            ingestedChunks.add(IngestedChunk(sequence, epoch, capturedStartNs, sampleCount))
            val nextSeq = laneState.nextSequence + 1L
            val updatedLane = laneState.copy(nextSequence = nextSeq)
            val updatedMic = mic.copy(
                nextSequence = nextSeq,
                lanes = mapOf("microphone" to updatedLane),
            )
            snapshot = snapshot.copy(
                generation = snapshot.generation + 1L,
                microphone = updatedMic,
                activeCapture = activeCaptureFor(updatedMic),
            )
            return PcmIngestReceipt(snapshot.generation, nextSeq, PcmIngestStatus.ACCEPTED)
        }

        override fun sessionReportPlaybackProgress(
            handle: Long,
            recordId: String,
            requestId: Long,
            positionMs: Long,
            isPlaying: Boolean,
            lastProjectedNowSec: Long,
            nowEpochSec: Long,
        ): PlaybackProgressReceipt = PlaybackProgressReceipt(
            generation = snapshot.generation,
            prevGeneration = snapshot.generation,
            positionMs = positionMs,
            nowEpochSec = nowEpochSec,
            isPlaying = isPlaying,
            applied = true,
            needsFullSnapshot = false,
        )

        override fun sessionDrainBleTx(handle: Long): ByteArray = ByteArray(0)
        override fun sessionDrainLocalAsr(handle: Long): ByteArray = ByteArray(0)
        override fun sessionPollTimers(handle: Long, elapsedMs: Long, nowEpochSec: Long): Long = snapshot.generation

        private fun activeCaptureFor(mic: MicrophoneSnapshot): ActiveCaptureSnapshot =
            ActiveCaptureSnapshot(
                mode = CaptureMode.QUICK_NOTE,
                phase = mic.phase,
                sourceLabel = "Android 麦克风",
                actions = when (mic.phase) {
                    "recording" -> listOf(CaptureAction.PAUSE, CaptureAction.END, CaptureAction.CANCEL)
                    "paused" -> listOf(CaptureAction.RESUME, CaptureAction.END, CaptureAction.CANCEL)
                    else -> listOf(CaptureAction.END)
                },
            )
    }

    private data class Harness(
        val bridge: StatefulCaptureBridgeClient,
        val store: HostSessionStore,
        val source: FakeMicrophoneSource,
        val focus: FakeAudioFocusController,
        val coordinator: AndroidCaptureCoordinator,
        val hostCoordinator: AndroidHostCoordinator,
        val foregroundStates: MutableList<CaptureForegroundState>,
        val setClock: (Long) -> Unit,
    )

    private fun createHarness(
        synchronousGrant: Boolean? = null,
        grantFocus: Boolean = true,
    ): Harness {
        var nowNs = 1_000_000_000L
        val bridge = StatefulCaptureBridgeClient()
        val store = HostSessionStore(workspacePath = "/tmp/koe-capture-test", bridge = bridge)
        val source = FakeMicrophoneSource(synchronousGrant = synchronousGrant)
        val focus = FakeAudioFocusController(grantFocus = grantFocus)
        val foregroundStates = mutableListOf<CaptureForegroundState>()
        val captureCoordinator = AndroidCaptureCoordinator(
            source = source,
            focusController = focus,
            nowNanoseconds = { nowNs },
            onForegroundStateChanged = { foregroundStates.add(it) },
        )
        val hostCoordinator = AndroidHostCoordinator(
            tickIntervalMs = 250L,
            scheduler = ManualTickScheduler(),
            clockElapsedMs = { 0L },
        )
        hostCoordinator.registerAdapter(captureCoordinator)
        hostCoordinator.bind(store, HostBridgeActions(resumeMicrophone = { captureCoordinator.resume() }))
        return Harness(
            bridge = bridge,
            store = store,
            source = source,
            focus = focus,
            coordinator = captureCoordinator,
            hostCoordinator = hostCoordinator,
            foregroundStates = foregroundStates,
            setClock = { nowNs = it },
        )
    }

    @Test
    fun fullLifecycleStartingRecordingPauseResumeStopAndForegroundTransitions() {
        val h = createHarness()

        h.store.startCapture(CaptureMode.QUICK_NOTE, stayOnPage = true)
        assertEquals("starting", h.store.currentMicrophone()?.phase)
        assertEquals(1, h.source.permissionRequests)
        assertEquals(0, h.source.startCount)
        assertTrue(h.foregroundStates.isEmpty())

        h.setClock(5_000_000_000L)
        h.source.lastPermissionCallback!!.invoke(true)
        assertEquals("recording", h.store.currentMicrophone()?.phase)
        assertEquals(5_000_000_000L, h.store.currentMicrophone()?.clockNs)
        assertEquals(1, h.focus.requestCount)
        assertEquals(1, h.source.startCount)
        assertEquals(
            listOf(CaptureForegroundState(active = true, paused = false, modeTitle = "随心闪记")),
            h.foregroundStates,
        )

        h.source.emit(shortArrayOf(10, 20), 5_000_000_000L)
        h.source.emit(shortArrayOf(30, 40), 5_000_125_000L)
        h.hostCoordinator.tickOnce()
        assertEquals(2, h.bridge.ingestedChunks.size)
        assertEquals(2L, h.store.currentMicrophone()?.nextSequence)

        h.source.tailOnStop = listOf(CapturedPcm(shortArrayOf(50, 60), 5_000_250_000L))
        h.store.send(HostCommand.PauseMicrophone)
        assertEquals("paused", h.store.currentMicrophone()?.phase)
        assertEquals(3L, h.store.currentMicrophone()?.nextSequence)
        assertEquals(1, h.source.stopCount)
        assertEquals(1, h.focus.abandonCount)
        assertEquals(
            CaptureForegroundState(active = true, paused = true, modeTitle = "随心闪记"),
            h.foregroundStates.last(),
        )

        h.setClock(9_000_000_000L)
        h.store.performCaptureAction(CaptureAction.RESUME)
        h.store.performCaptureAction(CaptureAction.RESUME)
        assertEquals(2, h.source.permissionRequests)
        h.source.lastPermissionCallback!!.invoke(true)

        assertEquals("recording", h.store.currentMicrophone()?.phase)
        assertEquals(1L, h.store.currentMicrophone()?.epoch)
        assertEquals(9_000_000_000L, h.store.currentMicrophone()?.clockNs)
        assertEquals(16_000, h.source.lastExpectedSampleRate)
        assertEquals(2, h.focus.requestCount)
        assertEquals(2, h.source.startCount)
        assertEquals(
            CaptureForegroundState(active = true, paused = false, modeTitle = "随心闪记"),
            h.foregroundStates.last(),
        )

        h.source.emit(shortArrayOf(70, 80), 9_000_000_000L)
        h.hostCoordinator.tickOnce()
        assertEquals(4, h.bridge.ingestedChunks.size)
        assertEquals(1L, h.bridge.ingestedChunks.last().epoch)
        assertEquals(3L, h.bridge.ingestedChunks.last().sequence)

        h.source.tailOnStop = listOf(CapturedPcm(shortArrayOf(90, 100), 9_000_125_000L))
        h.store.send(HostCommand.StopMicrophone)
        assertNull(h.store.currentMicrophone())
        assertEquals(5, h.bridge.ingestedChunks.size)
        assertEquals(2, h.source.stopCount)
        assertEquals(2, h.focus.abandonCount)
        assertEquals(
            CaptureForegroundState(active = false, paused = false, modeTitle = null),
            h.foregroundStates.last(),
        )
    }

    @Test
    fun synchronousPermissionGrantTransitionsDirectlyToRecording() {
        val h = createHarness(synchronousGrant = true)

        h.store.startCapture(CaptureMode.QUICK_NOTE, stayOnPage = true)
        assertEquals("recording", h.store.currentMicrophone()?.phase)
        assertEquals(1, h.source.startCount)
        assertEquals(1, h.focus.requestCount)
        assertEquals(
            listOf(CaptureForegroundState(active = true, paused = false, modeTitle = "随心闪记")),
            h.foregroundStates,
        )
    }

    @Test
    fun permissionDeniedSendsMicrophoneFailedAndStoppedWithoutStartingSource() {
        val h = createHarness()

        h.store.startCapture(CaptureMode.QUICK_NOTE, stayOnPage = true)
        h.source.lastPermissionCallback!!.invoke(false)

        assertNull(h.store.currentMicrophone())
        assertEquals(0, h.source.startCount)
        assertEquals(0, h.focus.requestCount)
        assertTrue(h.foregroundStates.isEmpty())
        val types = h.bridge.dispatchedEvents.map { it["type"]?.jsonPrimitive?.content }
        assertTrue("expected microphone_failed in $types", "microphone_failed" in types)
        assertTrue("expected microphone_stopped in $types", "microphone_stopped" in types)
    }

    @Test
    fun latePermissionAfterCancelCannotStartNewSession() {
        val h = createHarness()

        h.store.startCapture(CaptureMode.QUICK_NOTE, stayOnPage = true)
        val staleCallback = h.source.lastPermissionCallback!!
        h.store.send(HostCommand.CancelMicrophone)
        assertNull(h.store.currentMicrophone())

        h.store.startCapture(CaptureMode.QUICK_NOTE, stayOnPage = true)
        staleCallback(true)
        assertEquals("starting", h.store.currentMicrophone()?.phase)
        assertEquals(0, h.source.startCount)

        h.source.lastPermissionCallback!!.invoke(true)
        assertEquals("recording", h.store.currentMicrophone()?.phase)
        assertEquals(1, h.source.startCount)
    }

    @Test
    fun audioFocusLossDispatchesPauseMicrophoneAndAbandonsFocus() {
        val h = createHarness(synchronousGrant = true)

        h.store.startCapture(CaptureMode.QUICK_NOTE, stayOnPage = true)
        assertEquals("recording", h.store.currentMicrophone()?.phase)

        h.focus.triggerFocusLoss()
        assertEquals("paused", h.store.currentMicrophone()?.phase)
        assertEquals(1, h.source.stopCount)
        assertEquals(1, h.focus.abandonCount)
        assertEquals(
            CaptureForegroundState(active = true, paused = true, modeTitle = "随心闪记"),
            h.foregroundStates.last(),
        )

        val pauseCountBefore = h.bridge.dispatchedEvents.count {
            it["type"]?.jsonPrimitive?.content == "pause_microphone"
        }
        h.focus.triggerFocusLoss()
        val pauseCountAfter = h.bridge.dispatchedEvents.count {
            it["type"]?.jsonPrimitive?.content == "pause_microphone"
        }
        assertEquals(pauseCountBefore, pauseCountAfter)
    }

    @Test
    fun sampleRateMismatchOnResumeFailsCleanlyAndAbandonsFocus() {
        val h = createHarness(synchronousGrant = true)

        h.store.startCapture(CaptureMode.QUICK_NOTE, stayOnPage = true)
        h.source.emit(shortArrayOf(1, 2), 1_000_000_000L)
        h.hostCoordinator.tickOnce()
        h.store.send(HostCommand.PauseMicrophone)
        assertEquals("paused", h.store.currentMicrophone()?.phase)

        h.source.sampleRate = 48_000
        h.setClock(5_000_000_000L)
        h.store.performCaptureAction(CaptureAction.RESUME)

        assertNull(h.store.currentMicrophone())
        assertEquals(2, h.focus.abandonCount)
        val failedEvent = h.bridge.dispatchedEvents.lastOrNull {
            it["type"]?.jsonPrimitive?.content == "microphone_failed"
        }
        assertNotNull(failedEvent)
        assertTrue(failedEvent!!["message"]?.jsonPrimitive?.content.orEmpty().contains("采样率"))
        val stoppedEvent = h.bridge.dispatchedEvents.lastOrNull {
            it["type"]?.jsonPrimitive?.content == "microphone_stopped"
        }
        assertEquals(1L, stoppedEvent?.get("sequence")?.jsonPrimitive?.long)
    }

    @Test
    fun rejectedPcmChunkStopsSourceReportsFailureAndDiscardsUnacceptedBlocks() {
        val h = createHarness(synchronousGrant = true)

        h.store.startCapture(CaptureMode.QUICK_NOTE, stayOnPage = true)
        h.bridge.rejectAtSequence = 1L
        h.source.emit(shortArrayOf(1, 2), 1_000_000_000L)
        h.source.emit(shortArrayOf(3, 4), 1_000_125_000L)
        h.source.emit(shortArrayOf(5, 6), 1_000_250_000L)
        h.hostCoordinator.tickOnce()

        assertNull(h.store.currentMicrophone())
        assertEquals(1, h.bridge.ingestedChunks.size)
        assertEquals(1, h.source.stopCount)
        assertEquals(1, h.focus.abandonCount)
        val stoppedEvent = h.bridge.dispatchedEvents.lastOrNull {
            it["type"]?.jsonPrimitive?.content == "microphone_stopped"
        }
        assertEquals(1L, stoppedEvent?.get("sequence")?.jsonPrimitive?.long)
    }

    @Test
    fun sessionUnboundStopsSourceAbandonsFocusAndClearsForegroundState() {
        val h = createHarness(synchronousGrant = true)

        h.store.startCapture(CaptureMode.QUICK_NOTE, stayOnPage = true)
        assertTrue(h.foregroundStates.last().active)

        h.hostCoordinator.shutdown()
        assertEquals(1, h.source.stopCount)
        assertEquals(1, h.focus.abandonCount)
        assertFalse(h.foregroundStates.last().active)
    }
}
