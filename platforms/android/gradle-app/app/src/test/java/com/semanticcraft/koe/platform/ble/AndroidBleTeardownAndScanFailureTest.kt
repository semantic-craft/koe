package com.semanticcraft.koe.platform.ble

import com.semanticcraft.koe.bridge.KoeNativeBridge
import com.semanticcraft.koe.core.DeviceSnapshot
import com.semanticcraft.koe.core.HostBridgeActions
import com.semanticcraft.koe.core.HostBridgeClient
import com.semanticcraft.koe.core.HostJson
import com.semanticcraft.koe.core.HostSessionStore
import com.semanticcraft.koe.core.HostSnapshot
import com.semanticcraft.koe.core.PcmIngestReceipt
import com.semanticcraft.koe.core.PcmIngestStatus
import com.semanticcraft.koe.core.PlaybackProgressReceipt
import com.semanticcraft.koe.platform.AndroidHostCoordinator
import com.semanticcraft.koe.platform.TickScheduler
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class AndroidBleTeardownAndScanFailureTest {
    private class VirtualClockScheduler(var nowMs: Long = 1_000L) {
        data class Task(
            val fireAtMs: Long,
            val delayMs: Long,
            val action: () -> Unit,
            var cancelled: Boolean = false,
        )

        val tasks = mutableListOf<Task>()

        fun schedule(delayMs: Long, action: () -> Unit): AutoCloseable {
            val task = Task(nowMs + delayMs, delayMs, action)
            tasks.add(task)
            return AutoCloseable { task.cancelled = true }
        }

        fun activeTasks(): List<Task> = tasks.filter { !it.cancelled }.sortedBy { it.fireAtMs }

        fun advanceTo(targetMs: Long) {
            while (true) {
                val next = tasks
                    .filter { !it.cancelled && it.fireAtMs <= targetMs }
                    .minByOrNull { it.fireAtMs } ?: break
                tasks.remove(next)
                nowMs = maxOf(nowMs, next.fireAtMs)
                next.action()
            }
            nowMs = maxOf(nowMs, targetMs)
        }
    }

    private class InMemoryAddressStore(var saved: String? = null) : BleAddressStore {
        override fun read(): String? = saved
        override fun write(address: String) { saved = address }
        override fun clear() { saved = null }
    }

    private class RecordingBleTransport : AndroidBleTransport {
        var activeListener: BleTransportListener? = null
        val scanCalls = mutableListOf<String?>()
        val writtenChunks = mutableListOf<ByteArray>()
        val writeResults = ArrayDeque<Boolean>()
        var writeAttempts = 0
        var disconnectCount = 0

        override fun setListener(listener: BleTransportListener?) {
            activeListener = listener
        }

        override fun adapterState(): BleAdapterState = BleAdapterState.SUPPORTED_READY

        override fun startScan(savedAddress: String?) {
            scanCalls.add(savedAddress)
        }

        override fun stopScan() {}

        override fun connect(address: String, displayName: String) {}

        override fun writeCharacteristic(data: ByteArray): Boolean {
            writeAttempts += 1
            val accepted = if (writeResults.isEmpty()) true else writeResults.removeFirst()
            if (accepted) {
                writtenChunks.add(data.copyOf())
            }
            return accepted
        }

        override fun disconnect() {
            disconnectCount += 1
        }
    }

    private class RecordingBridgeClient : HostBridgeClient {
        var snapshot: HostSnapshot = HostSnapshot.empty.copy(generation = 1L)
        val dispatchedEvents = mutableListOf<JsonObject>()
        val outboundFrames = ArrayDeque<ByteArray>()

        override fun apiVersion(): Int = 2
        override fun sessionCreate(directory: String): Long = 801L
        override fun sessionCreateWithCredentials(
            directory: String,
            credentialBridge: KoeNativeBridge.CredentialBridge,
            isolated: Boolean,
        ): Long = 801L

        override fun sessionDestroy(handle: Long): Boolean = true
        override fun sessionGeneration(handle: Long): Long = snapshot.generation
        override fun sessionSnapshotJson(handle: Long, nowEpochSec: Long): String =
            HostJson.json.encodeToString(HostSnapshot.serializer(), snapshot)

        override fun sessionDispatchJson(handle: Long, commandJson: String, nowEpochSec: Long): String {
            val obj = HostJson.json.parseToJsonElement(commandJson) as JsonObject
            dispatchedEvents.add(obj)
            val type = obj["type"]?.jsonPrimitive?.content
            when (type) {
                "device_event" -> {
                    val event = obj["event"]?.jsonPrimitive?.content
                    val updated = when (event) {
                        "scanning" -> snapshot.device.copy(phase = "scanning", connected = false)
                        "connecting" -> snapshot.device.copy(phase = "connecting", connected = false)
                        "ready" -> snapshot.device.copy(phase = "handshaking", connected = false)
                        "disconnected" -> snapshot.device.copy(phase = "disconnected", connected = false, recording = false)
                        else -> snapshot.device
                    }
                    snapshot = snapshot.copy(generation = snapshot.generation + 1L, device = updated)
                }
                "device_disconnect" -> {
                    snapshot = snapshot.copy(
                        generation = snapshot.generation + 1L,
                        device = snapshot.device.copy(phase = "disconnected", connected = false, recording = false),
                    )
                }
            }
            return sessionSnapshotJson(handle, nowEpochSec)
        }

        override fun sessionIngestBle(handle: Long, bytes: ByteArray, nowEpochSec: Long): Long = snapshot.generation
        override fun sessionIngestPcm(
            handle: Long, recordId: String, sessionId: String, lane: String,
            sequence: Long, epoch: Long, capturedStartNs: Long?,
            samples: ShortArray, sampleCount: Int, nowEpochSec: Long,
        ): PcmIngestReceipt = PcmIngestReceipt(snapshot.generation, 0L, PcmIngestStatus.REJECTED)

        override fun sessionReportPlaybackProgress(
            handle: Long, recordId: String, requestId: Long, positionMs: Long,
            isPlaying: Boolean, lastProjectedNowSec: Long, nowEpochSec: Long,
        ): PlaybackProgressReceipt = PlaybackProgressReceipt(
            snapshot.generation, snapshot.generation, positionMs, nowEpochSec, isPlaying, true, false,
        )

        override fun sessionDrainBleTx(handle: Long): ByteArray {
            if (outboundFrames.isEmpty()) return ByteArray(0)
            val totalSize = outboundFrames.sumOf { 4 + it.size }
            val out = ByteArray(totalSize)
            var offset = 0
            while (outboundFrames.isNotEmpty()) {
                val frame = outboundFrames.removeFirst()
                val len = frame.size
                out[offset] = (len and 0xFF).toByte()
                out[offset + 1] = ((len ushr 8) and 0xFF).toByte()
                out[offset + 2] = ((len ushr 16) and 0xFF).toByte()
                out[offset + 3] = ((len ushr 24) and 0xFF).toByte()
                frame.copyInto(out, destinationOffset = offset + 4)
                offset += 4 + len
            }
            return out
        }

        override fun sessionDrainLocalAsr(handle: Long): ByteArray = ByteArray(0)
        override fun sessionPollTimers(handle: Long, elapsedMs: Long, nowEpochSec: Long): Long = snapshot.generation

        fun updateDevice(transform: (DeviceSnapshot) -> DeviceSnapshot) {
            snapshot = snapshot.copy(
                generation = snapshot.generation + 1L,
                device = transform(snapshot.device),
            )
        }
    }

    private data class Fixture(
        val clock: VirtualClockScheduler,
        val bridge: RecordingBridgeClient,
        val store: HostSessionStore,
        val transport: RecordingBleTransport,
        val coordinator: AndroidBleCoordinator,
        val foregroundChanges: MutableList<Boolean>,
    )

    private class NoopTickScheduler : TickScheduler {
        override fun schedulePeriodic(intervalMs: Long, onTick: () -> Unit): AutoCloseable = AutoCloseable {}
    }

    private fun createFixture(): Fixture {
        val clock = VirtualClockScheduler(nowMs = 1_000L)
        val bridge = RecordingBridgeClient()
        val store = HostSessionStore(workspacePath = "/tmp/koe-ble-teardown-test", bridge = bridge)
        val transport = RecordingBleTransport()
        val foregroundChanges = mutableListOf<Boolean>()
        val coordinator = AndroidBleCoordinator(
            transport = transport,
            addressStore = InMemoryAddressStore(),
            requestBlePermission = { cb -> cb(true) },
            clockMs = { clock.nowMs },
            scheduleDelayed = clock::schedule,
            onForegroundRequirementChanged = { foregroundChanges.add(it != BleForegroundActivity.IDLE) },
        )
        val hostCoordinator = AndroidHostCoordinator(
            tickIntervalMs = 250L,
            scheduler = NoopTickScheduler(),
            clockElapsedMs = { clock.nowMs },
        )
        hostCoordinator.registerAdapter(coordinator)
        hostCoordinator.bind(
            store,
            HostBridgeActions(
                requestBleScan = { coordinator.requestScan() },
                flushBleOutbound = { coordinator.flushOutboundFrames() },
            ),
        )
        return Fixture(clock, bridge, store, transport, coordinator, foregroundChanges)
    }

    private fun Fixture.connectReadyRecording(stopHex: String = "08EE00000018820B00029D") {
        coordinator.requestScan()
        transport.activeListener!!.onCandidateDiscovered("AA:BB:CC:DD:EE:FF", "soundcore Work")
        transport.activeListener!!.onLinkReady("AA:BB:CC:DD:EE:FF", "soundcore Work", payloadMtu = 244)
        bridge.updateDevice {
            it.copy(
                phase = "connected",
                connected = true,
                recording = true,
                teardownStopFramesHex = listOf(stopHex),
            )
        }
        store.refreshSnapshot()
    }

    @Test
    fun onSessionUnboundSerializesStopWriteBehindInFlightWriteAndDisconnectsAfterAck() {
        val f = createFixture()
        val stopHex = "08EE00000018820B00029D"
        f.connectReadyRecording(stopHex)

        val inFlightNormal = byteArrayOf(0x01, 0x02, 0x03)
        val queuedNormal = byteArrayOf(0x04, 0x05, 0x06)
        f.bridge.outboundFrames.addLast(inFlightNormal)
        f.bridge.outboundFrames.addLast(queuedNormal)
        f.coordinator.flushOutboundFrames()

        assertEquals(1, f.transport.writtenChunks.size)
        assertArrayEquals(inFlightNormal, f.transport.writtenChunks[0])

        f.clock.nowMs = 1_050L
        f.coordinator.onSessionUnbound()

        assertEquals(1, f.transport.writtenChunks.size)
        assertEquals(0, f.transport.disconnectCount)
        assertEquals(false, f.foregroundChanges.lastOrNull())

        f.clock.nowMs = 1_100L
        f.transport.activeListener!!.onWriteCompleted(true)
        assertEquals(1, f.transport.writtenChunks.size)
        assertEquals(0, f.transport.disconnectCount)

        f.clock.advanceTo(1_299L)
        assertEquals(1, f.transport.writtenChunks.size)
        assertEquals(0, f.transport.disconnectCount)

        f.clock.advanceTo(1_300L)
        assertEquals(2, f.transport.writtenChunks.size)
        assertArrayEquals(BleHex.decode(stopHex), f.transport.writtenChunks[1])
        assertEquals(0, f.transport.disconnectCount)

        f.clock.nowMs = 1_350L
        f.transport.activeListener!!.onWriteCompleted(true)
        assertEquals(1, f.transport.disconnectCount)
        assertTrue(f.clock.activeTasks().isEmpty())
    }

    @Test
    fun teardownWriteFailureDisconnectsCleanlyWithoutErrorBanner() {
        val f = createFixture()
        val stopHex = "08EE00000018820B00029D"
        f.connectReadyRecording(stopHex)

        f.coordinator.disconnect()
        assertEquals(1, f.transport.writtenChunks.size)
        assertArrayEquals(BleHex.decode(stopHex), f.transport.writtenChunks[0])
        assertEquals(0, f.transport.disconnectCount)

        f.transport.activeListener!!.onWriteCompleted(false)
        assertEquals(1, f.transport.disconnectCount)
        assertNull(f.store.navigation.value.effectiveError)
        assertTrue(f.clock.activeTasks().isEmpty())
    }

    @Test
    fun teardownTimeoutForcesDisconnectWhenWriteCallbackNeverArrives() {
        val f = createFixture()
        f.connectReadyRecording()

        f.coordinator.onSessionUnbound()
        assertEquals(1, f.transport.writtenChunks.size)
        assertEquals(0, f.transport.disconnectCount)

        f.clock.advanceTo(1_000L + AndroidBleCoordinator.TEARDOWN_WRITE_TIMEOUT_MS - 1L)
        assertEquals(0, f.transport.disconnectCount)

        f.clock.advanceTo(1_000L + AndroidBleCoordinator.TEARDOWN_WRITE_TIMEOUT_MS)
        assertEquals(1, f.transport.disconnectCount)
        assertTrue(f.clock.activeTasks().isEmpty())
    }

    @Test
    fun teardownRetriesBusyWriteOnSpacingTimerUntilAcceptedAndCompleted() {
        val f = createFixture()
        val stopHex = "08EE00000018820B00029D"
        f.connectReadyRecording(stopHex)
        f.transport.writeResults.addLast(false)
        f.transport.writeResults.addLast(true)

        f.coordinator.disconnect()
        assertEquals(1, f.transport.writeAttempts)
        assertEquals(0, f.transport.writtenChunks.size)
        assertEquals(0, f.transport.disconnectCount)

        f.clock.advanceTo(1_300L)
        assertEquals(2, f.transport.writeAttempts)
        assertEquals(1, f.transport.writtenChunks.size)
        assertArrayEquals(BleHex.decode(stopHex), f.transport.writtenChunks[0])
        assertEquals(0, f.transport.disconnectCount)

        f.transport.activeListener!!.onWriteCompleted(true)
        assertEquals(1, f.transport.disconnectCount)
        assertTrue(f.clock.activeTasks().isEmpty())
    }

    @Test
    fun scanFailureBeforeDiscoveryResetsRuntimePhaseReportsErrorAndAllowsFreshScan() {
        val f = createFixture()
        f.coordinator.requestScan()
        assertEquals(1, f.transport.scanCalls.size)
        assertEquals("scanning", f.store.device.value.phase)

        val scanError = "蓝牙扫描启动失败（错误码 2），请重试。"
        f.transport.activeListener!!.onDisconnected(scanError)

        assertEquals("disconnected", f.store.device.value.phase)
        assertEquals(scanError, f.store.navigation.value.effectiveError)
        assertEquals(
            "device_disconnect",
            f.bridge.dispatchedEvents.last()["type"]?.jsonPrimitive?.content,
        )

        f.coordinator.requestScan()
        assertEquals(2, f.transport.scanCalls.size)
        assertEquals("scanning", f.store.device.value.phase)
    }

    @Test
    fun transportDropDuringTeardownResetsWithoutDuplicateEventOrError() {
        val f = createFixture()
        f.connectReadyRecording()

        f.coordinator.disconnect()
        assertEquals(0, f.transport.disconnectCount)
        f.bridge.dispatchedEvents.clear()

        f.transport.activeListener!!.onDisconnected("连接已中断")
        assertTrue(f.bridge.dispatchedEvents.isEmpty())
        assertNull(f.store.navigation.value.effectiveError)
        assertTrue(f.clock.activeTasks().isEmpty())

        f.coordinator.requestScan()
        assertEquals(2, f.transport.scanCalls.size)
        assertEquals("scanning", f.store.device.value.phase)
    }

    @Test
    fun explicitRequestScanFinalizesPendingTeardownBeforeStartingNewScan() {
        val f = createFixture()
        f.connectReadyRecording()

        f.coordinator.disconnect()
        assertEquals(0, f.transport.disconnectCount)

        f.coordinator.requestScan()
        assertEquals(1, f.transport.disconnectCount)
        assertEquals(2, f.transport.scanCalls.size)
        assertEquals("scanning", f.store.device.value.phase)
        assertTrue(f.clock.activeTasks().isEmpty())
    }
}
