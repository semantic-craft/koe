package com.semanticcraft.koe.platform

import com.semanticcraft.koe.bridge.KoeNativeBridge
import com.semanticcraft.koe.core.HostBridgeActions
import com.semanticcraft.koe.core.HostBridgeClient
import com.semanticcraft.koe.core.HostJson
import com.semanticcraft.koe.core.HostSessionStore
import com.semanticcraft.koe.core.HostSnapshot
import com.semanticcraft.koe.core.LifecycleSnapshot
import com.semanticcraft.koe.core.PcmIngestReceipt
import com.semanticcraft.koe.core.PcmIngestStatus
import com.semanticcraft.koe.core.PlaybackProgressReceipt
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class AndroidHostCoordinatorTest {
    private class FakeTickScheduler : TickScheduler {
        var scheduleCount = 0
        var closeCount = 0
        var lastIntervalMs: Long = 0L
        var activeTick: (() -> Unit)? = null

        val isRunning: Boolean
            get() = activeTick != null

        override fun schedulePeriodic(intervalMs: Long, onTick: () -> Unit): AutoCloseable {
            scheduleCount += 1
            lastIntervalMs = intervalMs
            activeTick = onTick
            var closed = false
            return AutoCloseable {
                if (!closed) {
                    closed = true
                    closeCount += 1
                    if (activeTick === onTick) {
                        activeTick = null
                    }
                }
            }
        }

        fun fireTick() {
            val callback = checkNotNull(activeTick) { "ticker is not running" }
            callback()
        }
    }

    private class RecordingBridgeClient(
        var snapshot: HostSnapshot = HostSnapshot.empty.copy(generation = 1L),
    ) : HostBridgeClient {
        val polledElapsedMs = mutableListOf<Long>()

        override fun apiVersion(): Int = 2
        override fun sessionCreate(directory: String): Long = 501L
        override fun sessionCreateWithCredentials(
            directory: String,
            credentialBridge: KoeNativeBridge.CredentialBridge,
            isolated: Boolean,
        ): Long = 501L
        override fun sessionDestroy(handle: Long): Boolean = true
        override fun sessionGeneration(handle: Long): Long = snapshot.generation
        override fun sessionSnapshotJson(handle: Long, nowEpochSec: Long): String =
            HostJson.json.encodeToString(HostSnapshot.serializer(), snapshot)
        override fun sessionDispatchJson(handle: Long, commandJson: String, nowEpochSec: Long): String =
            sessionSnapshotJson(handle, nowEpochSec)
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
        ): PcmIngestReceipt = PcmIngestReceipt(snapshot.generation, sequence + 1L, PcmIngestStatus.ACCEPTED)
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
        override fun sessionPollTimers(handle: Long, elapsedMs: Long, nowEpochSec: Long): Long {
            polledElapsedMs.add(elapsedMs)
            return snapshot.generation
        }
    }

    private class RecordingAdapter : AndroidHostAdapter {
        val ticks = mutableListOf<Long>()
        val snapshots = mutableListOf<HostSnapshot>()
        val boundStores = mutableListOf<HostSessionStore>()
        var unboundCount = 0

        override fun onTick(elapsedMs: Long) {
            ticks.add(elapsedMs)
        }

        override fun onSnapshotChanged(snapshot: HostSnapshot) {
            snapshots.add(snapshot)
        }

        override fun onSessionBound(store: HostSessionStore) {
            boundStores.add(store)
        }

        override fun onSessionUnbound() {
            unboundCount += 1
        }
    }

    @Test
    fun foregroundActiveStarts250msPollingAndDispatchesElapsedMs() {
        val scheduler = FakeTickScheduler()
        var nowMs = 1_000L
        val bridge = RecordingBridgeClient()
        val store = HostSessionStore(workspacePath = "/tmp/koe-coord-fg", bridge = bridge)
        val adapter = RecordingAdapter()
        val coordinator = AndroidHostCoordinator(
            tickIntervalMs = 250L,
            scheduler = scheduler,
            clockElapsedMs = { nowMs },
        )

        coordinator.registerAdapter(adapter)
        coordinator.bind(store)
        assertFalse(scheduler.isRunning)

        coordinator.setForegroundActive(true)
        assertTrue(scheduler.isRunning)
        assertEquals(250L, scheduler.lastIntervalMs)

        nowMs += 250L
        scheduler.fireTick()
        nowMs += 300L
        scheduler.fireTick()

        assertEquals(listOf(250L, 300L), bridge.polledElapsedMs)
        assertEquals(listOf(250L, 300L), adapter.ticks)
        assertEquals(listOf(store), adapter.boundStores)
    }

    @Test
    fun backgroundingStopsPollingUnlessKeepAwakeIsTrue() {
        val scheduler = FakeTickScheduler()
        var nowMs = 5_000L
        val bridge = RecordingBridgeClient()
        val store = HostSessionStore(workspacePath = "/tmp/koe-coord-awake", bridge = bridge)
        val adapter = RecordingAdapter()
        val coordinator = AndroidHostCoordinator(
            tickIntervalMs = 250L,
            scheduler = scheduler,
            clockElapsedMs = { nowMs },
        )

        coordinator.registerAdapter(adapter)
        coordinator.bind(store)
        coordinator.setForegroundActive(true)
        assertTrue(scheduler.isRunning)

        coordinator.setForegroundActive(false)
        assertFalse(scheduler.isRunning)

        val awakeSnapshot = HostSnapshot.empty.copy(
            generation = 2L,
            lifecycle = LifecycleSnapshot(keepAwake = true),
        )
        assertTrue(store.applySnapshotJson(HostJson.json.encodeToString(HostSnapshot.serializer(), awakeSnapshot)))
        assertTrue(scheduler.isRunning)
        assertEquals(1, adapter.snapshots.size)

        nowMs += 250L
        scheduler.fireTick()
        assertEquals(listOf(250L), bridge.polledElapsedMs)
        assertEquals(listOf(250L), adapter.ticks)

        val idleSnapshot = awakeSnapshot.copy(
            generation = 3L,
            lifecycle = LifecycleSnapshot(keepAwake = false),
        )
        assertTrue(store.applySnapshotJson(HostJson.json.encodeToString(HostSnapshot.serializer(), idleSnapshot)))
        assertFalse(scheduler.isRunning)
    }

    @Test
    fun rebindingAndShutdownCancelTickerAndNotifyUnboundIdempotently() {
        val scheduler = FakeTickScheduler()
        var nowMs = 10_000L
        val store1 = HostSessionStore(workspacePath = "/tmp/koe-coord-1", bridge = RecordingBridgeClient())
        val store2 = HostSessionStore(workspacePath = "/tmp/koe-coord-2", bridge = RecordingBridgeClient())
        val adapter = RecordingAdapter()
        val coordinator = AndroidHostCoordinator(
            tickIntervalMs = 250L,
            scheduler = scheduler,
            clockElapsedMs = { nowMs },
        )
        var resumed = false

        coordinator.registerAdapter(adapter)
        coordinator.setForegroundActive(true)
        coordinator.bind(store1, HostBridgeActions(resumeMicrophone = { resumed = true }))
        assertTrue(scheduler.isRunning)
        store1.bridgeActions.resumeMicrophone()
        assertTrue(resumed)

        coordinator.bind(store2)
        assertEquals(1, adapter.unboundCount)
        assertEquals(listOf(store1, store2), adapter.boundStores)
        assertNull(store1.onSnapshotChanged)
        assertTrue(scheduler.isRunning)

        coordinator.shutdown()
        coordinator.shutdown()
        assertFalse(scheduler.isRunning)
        assertEquals(2, adapter.unboundCount)
        assertNull(store2.onSnapshotChanged)

        nowMs += 250L
        coordinator.tickOnce()
        assertTrue(adapter.ticks.isEmpty())
    }

    @Test
    fun coroutineTickSchedulerRunsPeriodicallyAndStopsAfterClose() {
        val scheduler = CoroutineTickScheduler()
        val latch = CountDownLatch(3)
        val count = AtomicInteger(0)

        val handle = scheduler.schedulePeriodic(15L) {
            count.incrementAndGet()
            latch.countDown()
        }

        assertTrue("expected periodic coroutine ticks", latch.await(2, TimeUnit.SECONDS))
        handle.close()
        Thread.sleep(60L)
        val countAfterStop = count.get()
        Thread.sleep(80L)
        assertEquals(countAfterStop, count.get())
    }
}
