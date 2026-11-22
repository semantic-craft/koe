package com.semanticcraft.koe.platform.capture

import com.semanticcraft.koe.core.CaptureAction
import com.semanticcraft.koe.core.CaptureMode
import com.semanticcraft.koe.core.HostBridgeActions
import com.semanticcraft.koe.core.HostCommand
import com.semanticcraft.koe.core.HostSessionStore
import com.semanticcraft.koe.platform.AndroidHostCoordinator
import com.semanticcraft.koe.platform.TickScheduler
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
        var lastStartThread: Thread? = null
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
            lastStartThread = Thread.currentThread()
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
        workExecutor: java.util.concurrent.Executor? = null,
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
            workExecutor = workExecutor,
        )
        val hostCoordinator = AndroidHostCoordinator(
            tickIntervalMs = 250L,
            scheduler = ManualTickScheduler(),
            clockElapsedMs = { 0L },
            callbackExecutor = java.util.concurrent.Executor { it.run() },
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

    @Test
    fun asyncPermissionGrantDispatchesStartAndEventsOntoWorkExecutor() {
        val workThreadRef = java.util.concurrent.atomic.AtomicReference<Thread>()
        val workExecutor = java.util.concurrent.Executors.newSingleThreadExecutor { runnable ->
            Thread(runnable, "koe-test-capture-work").apply {
                isDaemon = true
                workThreadRef.set(this)
            }
        }
        val h = createHarness(synchronousGrant = null, workExecutor = workExecutor)
        try {
            h.store.startCapture(CaptureMode.QUICK_NOTE, stayOnPage = true)
            assertEquals("starting", h.store.currentMicrophone()?.phase)
            val callback = requireNotNull(h.source.lastPermissionCallback)
            val permissionThread = Thread.currentThread()

            callback(true)

            val done = java.util.concurrent.CountDownLatch(1)
            workExecutor.execute { done.countDown() }
            assertTrue("expected workExecutor to finish", done.await(2, java.util.concurrent.TimeUnit.SECONDS))

            val expectedWorker = requireNotNull(workThreadRef.get())
            assertTrue("source.start must not run on permission callback thread", h.source.lastStartThread !== permissionThread)
            assertEquals(expectedWorker, h.source.lastStartThread)
            val preparedThread = h.bridge.dispatchedThreads.lastOrNull { it.first == "microphone_prepared" }?.second
            val startedThread = h.bridge.dispatchedThreads.lastOrNull { it.first == "microphone_started" }?.second
            assertEquals(expectedWorker, preparedThread)
            assertEquals(expectedWorker, startedThread)
            assertEquals("recording", h.store.currentMicrophone()?.phase)
        } finally {
            h.hostCoordinator.shutdown()
            workExecutor.shutdownNow()
        }
    }
}
