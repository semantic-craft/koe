package com.semanticcraft.koe.platform.ble

import com.semanticcraft.koe.bridge.KoeNativeBridge
import com.semanticcraft.koe.core.DeviceSnapshot
import com.semanticcraft.koe.core.HostBridgeActions
import com.semanticcraft.koe.core.HostBridgeClient
import com.semanticcraft.koe.core.HostCommand
import com.semanticcraft.koe.core.HostJson
import com.semanticcraft.koe.core.HostSessionStore
import com.semanticcraft.koe.core.HostSnapshot
import com.semanticcraft.koe.core.PcmIngestReceipt
import com.semanticcraft.koe.core.PcmIngestStatus
import com.semanticcraft.koe.core.PlaybackProgressReceipt
import com.semanticcraft.koe.platform.AndroidHostCoordinator
import com.semanticcraft.koe.platform.TickScheduler
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class AndroidBleCoordinatorTest {
    private class ManualTickScheduler : TickScheduler {
        var activeTick: (() -> Unit)? = null

        override fun schedulePeriodic(intervalMs: Long, onTick: () -> Unit): AutoCloseable {
            activeTick = onTick
            return AutoCloseable {
                if (activeTick === onTick) activeTick = null
            }
        }
    }

    private class ManualDelayScheduler {
        data class Scheduled(val delayMs: Long, val action: () -> Unit, var cancelled: Boolean = false)

        val pending = mutableListOf<Scheduled>()

        fun schedule(delayMs: Long, action: () -> Unit): AutoCloseable {
            val item = Scheduled(delayMs, action)
            pending.add(item)
            return AutoCloseable { item.cancelled = true }
        }

        fun runNextActive(): Long? {
            val next = pending.firstOrNull { !it.cancelled } ?: return null
            pending.remove(next)
            next.action()
            return next.delayMs
        }
    }

    private class InMemoryAddressStore(var saved: String? = null) : BleAddressStore {
        override fun read(): String? = saved
        override fun write(address: String) {
            saved = address
        }

        override fun clear() {
            saved = null
        }
    }

    private class FakeBleTransport(
        var state: BleAdapterState = BleAdapterState.SUPPORTED_READY,
    ) : AndroidBleTransport {
        var activeListener: BleTransportListener? = null
        val scanCalls = mutableListOf<String?>()
        var stopScanCount = 0
        val connectCalls = mutableListOf<Pair<String, String>>()
        val writtenChunks = mutableListOf<ByteArray>()
        val callLog = mutableListOf<String>()
        var disconnectCount = 0
        var writeResult = true

        override fun setListener(listener: BleTransportListener?) {
            activeListener = listener
        }

        override fun adapterState(): BleAdapterState = state

        override fun startScan(savedAddress: String?) {
            scanCalls.add(savedAddress)
            callLog.add("startScan")
        }

        override fun stopScan() {
            stopScanCount += 1
            callLog.add("stopScan")
        }

        override fun connect(address: String, displayName: String) {
            connectCalls.add(address to displayName)
            callLog.add("connect:$address")
        }

        override fun writeCharacteristic(data: ByteArray): Boolean {
            writtenChunks.add(data.copyOf())
            callLog.add("write:${data.size}")
            return writeResult
        }

        override fun disconnect() {
            disconnectCount += 1
            callLog.add("disconnect")
        }
    }

    private class StatefulBleBridgeClient : HostBridgeClient {
        var snapshot: HostSnapshot = HostSnapshot.empty.copy(generation = 1L)
        val dispatchedEvents = mutableListOf<JsonObject>()
        val ingestedBleChunks = mutableListOf<ByteArray>()
        val outboundFrames = ArrayDeque<ByteArray>()
        var followUpFrameOnIngest: ByteArray? = null
        var handshakeFrameOnReady: ByteArray? = null

        override fun apiVersion(): Int = 2
        override fun sessionCreate(directory: String): Long = 700L
        override fun sessionCreateWithCredentials(
            directory: String,
            credentialBridge: KoeNativeBridge.CredentialBridge,
            isolated: Boolean,
        ): Long = 700L

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
                    val name = obj["deviceName"]?.jsonPrimitive?.content ?: snapshot.device.deviceName
                    val updated = when (event) {
                        "scanning" -> snapshot.device.copy(phase = "scanning", connected = false)
                        "connecting" -> snapshot.device.copy(phase = "connecting", deviceName = name, connected = false)
                        "ready" -> {
                            if (snapshot.device.phase == "connecting") {
                                handshakeFrameOnReady?.let {
                                    outboundFrames.addLast(it)
                                    handshakeFrameOnReady = null
                                }
                                snapshot.device.copy(phase = "handshaking", deviceName = name, connected = false)
                            } else {
                                snapshot.device
                            }
                        }
                        "disconnected" -> snapshot.device.copy(
                            phase = "disconnected",
                            connected = false,
                            recording = false,
                            busy = false,
                            transferPhase = "idle",
                        )
                        else -> snapshot.device
                    }
                    snapshot = snapshot.copy(generation = snapshot.generation + 1L, device = updated)
                }
                "device_disconnect" -> {
                    snapshot = snapshot.copy(
                        generation = snapshot.generation + 1L,
                        device = snapshot.device.copy(
                            phase = "disconnected",
                            connected = false,
                            recording = false,
                            busy = false,
                            transferPhase = "idle",
                        ),
                    )
                }
                "set_ble_auto_connect" -> {
                    val enabled = obj["enabled"]?.jsonPrimitive?.boolean ?: true
                    snapshot = snapshot.copy(
                        generation = snapshot.generation + 1L,
                        device = snapshot.device.copy(autoConnect = enabled),
                    )
                }
            }
            return sessionSnapshotJson(handle, nowEpochSec)
        }

        override fun sessionIngestBle(handle: Long, bytes: ByteArray, nowEpochSec: Long): Long {
            ingestedBleChunks.add(bytes.copyOf())
            followUpFrameOnIngest?.let {
                outboundFrames.addLast(it)
                followUpFrameOnIngest = null
            }
            snapshot = snapshot.copy(generation = snapshot.generation + 1L)
            return snapshot.generation
        }

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

    private data class Harness(
        val bridge: StatefulBleBridgeClient,
        val store: HostSessionStore,
        val transport: FakeBleTransport,
        val addressStore: InMemoryAddressStore,
        val scheduler: ManualDelayScheduler,
        val coordinator: AndroidBleCoordinator,
        val hostCoordinator: AndroidHostCoordinator,
        val foregroundChanges: MutableList<Boolean>,
        val setClock: (Long) -> Unit,
    )

    private fun createHarness(
        permissionGranted: Boolean = true,
        adapterState: BleAdapterState = BleAdapterState.SUPPORTED_READY,
        savedAddress: String? = null,
        commandExecutor: java.util.concurrent.Executor? = null,
    ): Harness {
        var nowMs = 1_000L
        val bridge = StatefulBleBridgeClient()
        val store = HostSessionStore(
            workspacePath = "/tmp/koe-ble-test",
            bridge = bridge,
            commandExecutor = commandExecutor,
        )
        val transport = FakeBleTransport(state = adapterState)
        val addressStore = InMemoryAddressStore(saved = savedAddress)
        val delayScheduler = ManualDelayScheduler()
        val foregroundChanges = mutableListOf<Boolean>()
        val bleCoordinator = AndroidBleCoordinator(
            transport = transport,
            addressStore = addressStore,
            requestBlePermission = { cb -> cb(permissionGranted) },
            clockMs = { nowMs },
            scheduleDelayed = delayScheduler::schedule,
            onForegroundRequirementChanged = { foregroundChanges.add(it != BleForegroundActivity.IDLE) },
        )
        val hostCoordinator = AndroidHostCoordinator(
            tickIntervalMs = 250L,
            scheduler = ManualTickScheduler(),
            clockElapsedMs = { nowMs },
            callbackExecutor = java.util.concurrent.Executor { it.run() },
        )
        hostCoordinator.registerAdapter(bleCoordinator)
        hostCoordinator.bind(
            store,
            HostBridgeActions(
                requestBleScan = { bleCoordinator.requestScan() },
                flushBleOutbound = { bleCoordinator.flushOutboundFrames() },
            ),
        )
        return Harness(
            bridge = bridge,
            store = store,
            transport = transport,
            addressStore = addressStore,
            scheduler = delayScheduler,
            coordinator = bleCoordinator,
            hostCoordinator = hostCoordinator,
            foregroundChanges = foregroundChanges,
            setClock = { nowMs = it },
        )
    }

    @Test
    fun scanDiscoverConnectReadyPersistsOnlyAfterReadyAndPumpsFragmentedOutboundFrames() {
        val h = createHarness()
        val payload = byteArrayOf(1, 2, 3, 4, 5, 6, 7, 8, 9, 10)
        h.bridge.outboundFrames.addLast(payload)

        h.store.bridgeActions.requestBleScan()
        assertEquals(listOf<String?>(null), h.transport.scanCalls)
        assertEquals("scanning", h.bridge.dispatchedEvents.last()["event"]?.jsonPrimitive?.content)

        h.transport.activeListener!!.onCandidateDiscovered("AA:BB:CC:DD:EE:FF", "soundcore Work")
        assertEquals(1, h.transport.stopScanCount)
        assertEquals(listOf("AA:BB:CC:DD:EE:FF" to "soundcore Work"), h.transport.connectCalls)
        assertNull(h.addressStore.read())
        val connectingEvent = h.bridge.dispatchedEvents.last()
        assertEquals("connecting", connectingEvent["event"]?.jsonPrimitive?.content)
        val connectingConnId = connectingEvent["connectionId"]?.jsonPrimitive?.content
        assertNotNull(connectingConnId)

        h.transport.activeListener!!.onLinkReady("AA:BB:CC:DD:EE:FF", "soundcore Work", payloadMtu = 4)
        assertEquals("AA:BB:CC:DD:EE:FF", h.addressStore.read())
        val readyEvent = h.bridge.dispatchedEvents.last()
        assertEquals("ready", readyEvent["event"]?.jsonPrimitive?.content)
        assertEquals(connectingConnId, readyEvent["connectionId"]?.jsonPrimitive?.content)

        assertEquals(1, h.transport.writtenChunks.size)
        assertArrayEquals(byteArrayOf(1, 2, 3, 4), h.transport.writtenChunks[0])

        h.setClock(1_400L)
        h.hostCoordinator.tickOnce()
        assertEquals(1, h.transport.writtenChunks.size)

        h.setClock(1_100L)
        h.transport.activeListener!!.onWriteCompleted(true)
        assertEquals(1, h.transport.writtenChunks.size)

        h.setClock(1_300L)
        assertEquals(200L, h.scheduler.runNextActive())
        assertEquals(2, h.transport.writtenChunks.size)
        assertArrayEquals(byteArrayOf(5, 6, 7, 8), h.transport.writtenChunks[1])

        h.setClock(1_350L)
        h.transport.activeListener!!.onWriteCompleted(true)
        h.setClock(1_600L)
        assertEquals(250L, h.scheduler.runNextActive())
        assertEquals(3, h.transport.writtenChunks.size)
        assertArrayEquals(byteArrayOf(9, 10), h.transport.writtenChunks[2])
    }

    @Test
    fun notifyBytesForwardsToStoreAndPumpsFollowUpOutboundFrame() {
        val h = createHarness()
        h.store.bridgeActions.requestBleScan()
        h.transport.activeListener!!.onCandidateDiscovered("11:22:33:44:55:66", "soundcore Work")
        h.transport.activeListener!!.onLinkReady("11:22:33:44:55:66", "soundcore Work", payloadMtu = 244)

        val incoming = byteArrayOf(0x09, 0xFF.toByte(), 0x00, 0x01)
        val response = byteArrayOf(0x08, 0xEE.toByte(), 0x00, 0x02)
        h.bridge.followUpFrameOnIngest = response

        h.transport.activeListener!!.onNotifyBytes(incoming)
        assertEquals(1, h.bridge.ingestedBleChunks.size)
        assertArrayEquals(incoming, h.bridge.ingestedBleChunks[0])
        assertEquals(1, h.transport.writtenChunks.size)
        assertArrayEquals(response, h.transport.writtenChunks[0])
    }

    @Test
    fun autoConnectFalseClearsAddressFlushesTeardownStopFramesBeforeDisconnectAndSendsDeviceDisconnect() {
        val h = createHarness(savedAddress = "AA:BB:CC:DD:EE:FF")
        h.store.bridgeActions.requestBleScan()
        h.transport.activeListener!!.onCandidateDiscovered("AA:BB:CC:DD:EE:FF", "soundcore Work")
        h.transport.activeListener!!.onLinkReady("AA:BB:CC:DD:EE:FF", "soundcore Work", payloadMtu = 244)
        assertEquals("AA:BB:CC:DD:EE:FF", h.addressStore.read())

        val stopHex = "08EE00000018820B00029D"
        h.bridge.updateDevice {
            it.copy(
                phase = "connected",
                connected = true,
                recording = true,
                teardownStopFramesHex = listOf(stopHex),
            )
        }
        h.store.refreshSnapshot()
        h.transport.callLog.clear()
        h.transport.writtenChunks.clear()

        h.store.send(HostCommand.SetBleAutoConnect(enabled = false))

        assertNull(h.addressStore.read())
        assertEquals(1, h.transport.writtenChunks.size)
        assertArrayEquals(BleHex.decode(stopHex), h.transport.writtenChunks[0])
        assertEquals(0, h.transport.disconnectCount)

        h.transport.activeListener!!.onWriteCompleted(true)
        assertEquals(1, h.transport.disconnectCount)
        val writeIdx = h.transport.callLog.indexOfFirst { it.startsWith("write:") }
        val disconnectIdx = h.transport.callLog.indexOf("disconnect")
        assertTrue(writeIdx >= 0 && disconnectIdx > writeIdx)
        val types = h.bridge.dispatchedEvents.map { it["type"]?.jsonPrimitive?.content }
        assertTrue("expected device_disconnect in $types", "device_disconnect" in types)
    }

    @Test
    fun autoConnectFalseToTrueTriggersScanWhenIdle() {
        val h = createHarness()
        h.store.send(HostCommand.SetBleAutoConnect(enabled = false))
        assertEquals(0, h.transport.scanCalls.size)

        h.store.send(HostCommand.SetBleAutoConnect(enabled = true))
        assertEquals(1, h.transport.scanCalls.size)
        assertEquals("scanning", h.bridge.dispatchedEvents.last()["event"]?.jsonPrimitive?.content)
    }

    @Test
    fun permissionDeniedAndAdapterStatesReportChineseErrorsWithoutScanning() {
        val denied = createHarness(permissionGranted = false)
        denied.store.bridgeActions.requestBleScan()
        assertEquals("请在系统设置中允许 Koe 使用蓝牙。", denied.store.navigation.value.effectiveError)
        assertEquals(0, denied.transport.scanCalls.size)

        val poweredOff = createHarness(adapterState = BleAdapterState.POWERED_OFF)
        poweredOff.store.bridgeActions.requestBleScan()
        assertEquals("蓝牙已关闭，请在系统设置中打开。", poweredOff.store.navigation.value.effectiveError)
        assertEquals(0, poweredOff.transport.scanCalls.size)

        val unsupported = createHarness(adapterState = BleAdapterState.UNSUPPORTED)
        unsupported.store.bridgeActions.requestBleScan()
        assertEquals("这台设备不支持蓝牙连接。", unsupported.store.navigation.value.effectiveError)
        assertEquals(0, unsupported.transport.scanCalls.size)

        val unauthorized = createHarness(adapterState = BleAdapterState.UNAUTHORIZED)
        unauthorized.store.bridgeActions.requestBleScan()
        assertEquals("请在系统设置中允许 Koe 使用蓝牙。", unauthorized.store.navigation.value.effectiveError)
        assertEquals(0, unauthorized.transport.scanCalls.size)
    }

    @Test
    fun foregroundRequirementTogglesWithRecordingAndOfflinePullAndClearsOnDisconnect() {
        val h = createHarness()
        h.store.bridgeActions.requestBleScan()
        h.transport.activeListener!!.onCandidateDiscovered("AA:BB:CC:DD:EE:FF", "soundcore Work")
        h.transport.activeListener!!.onLinkReady("AA:BB:CC:DD:EE:FF", "soundcore Work", payloadMtu = 244)
        assertTrue(h.foregroundChanges.isEmpty())

        h.bridge.updateDevice { it.copy(phase = "connected", connected = true, recording = true) }
        h.store.refreshSnapshot()
        assertEquals(listOf(true), h.foregroundChanges)

        h.bridge.updateDevice {
            it.copy(phase = "connected", connected = true, recording = false, transferPhase = "pulling_offline")
        }
        h.store.refreshSnapshot()
        assertEquals(listOf(true), h.foregroundChanges)

        h.bridge.updateDevice {
            it.copy(phase = "connected", connected = true, recording = false, transferPhase = "idle", busy = false)
        }
        h.store.refreshSnapshot()
        assertEquals(listOf(true, false), h.foregroundChanges)

        h.bridge.updateDevice { it.copy(phase = "connected", connected = true, busy = true) }
        h.store.refreshSnapshot()
        assertEquals(listOf(true, false, true), h.foregroundChanges)

        h.transport.activeListener!!.onDisconnected(null)
        assertEquals(listOf(true, false, true, false), h.foregroundChanges)
        val disconnectedEvent = h.bridge.dispatchedEvents.last()
        assertEquals("disconnected", disconnectedEvent["event"]?.jsonPrimitive?.content)
        assertFalse(h.store.device.value.connected)
    }

    @Test
    fun requestScanIsIdempotentWhileScanningRefreshesWhenReadyAndWriteFailureDisconnects() {
        val h = createHarness()
        h.store.bridgeActions.requestBleScan()
        h.store.bridgeActions.requestBleScan()
        assertEquals(1, h.transport.scanCalls.size)

        h.transport.activeListener!!.onCandidateDiscovered("AA:BB:CC:DD:EE:FF", "soundcore Work")
        h.transport.activeListener!!.onLinkReady("AA:BB:CC:DD:EE:FF", "soundcore Work", payloadMtu = 244)

        h.store.bridgeActions.requestBleScan()
        assertEquals(1, h.transport.scanCalls.size)
        assertEquals(0, h.transport.disconnectCount)
        assertEquals("device_refresh", h.bridge.dispatchedEvents.last()["type"]?.jsonPrimitive?.content)

        h.bridge.outboundFrames.addLast(byteArrayOf(0x01, 0x02))
        h.store.bridgeActions.flushBleOutbound()
        h.transport.activeListener!!.onWriteCompleted(false)
        assertEquals(1, h.transport.disconnectCount)
        assertEquals("disconnected", h.bridge.dispatchedEvents.last()["event"]?.jsonPrimitive?.content)
        assertEquals("设备指令发送失败，请重新连接。", h.store.navigation.value.effectiveError)
    }

    @Test
    fun linkReadySerializesBehindConnectingOnQueuedCommandExecutorAndFlushesAfterReady() {
        val queued = ArrayDeque<Runnable>()
        val h = createHarness(commandExecutor = java.util.concurrent.Executor { queued.addLast(it) })
        val handshakeFrame = byteArrayOf(0x09, 0x11, 0x22)
        h.bridge.handshakeFrameOnReady = handshakeFrame

        h.store.bridgeActions.requestBleScan()
        while (queued.isNotEmpty()) queued.removeFirst().run()

        h.transport.activeListener!!.onCandidateDiscovered("AA:BB:CC:DD:EE:FF", "soundcore Work")
        h.transport.activeListener!!.onLinkReady("AA:BB:CC:DD:EE:FF", "soundcore Work", payloadMtu = 244)

        val eventsBeforeDrain = h.bridge.dispatchedEvents
            .filter { it["type"]?.jsonPrimitive?.content == "device_event" }
            .map { it["event"]?.jsonPrimitive?.content }
        assertEquals(listOf("scanning"), eventsBeforeDrain)
        assertTrue("handshake frames must not flush before ready is dispatched", h.transport.writtenChunks.isEmpty())

        while (queued.isNotEmpty()) queued.removeFirst().run()

        val eventsAfterDrain = h.bridge.dispatchedEvents
            .filter { it["type"]?.jsonPrimitive?.content == "device_event" }
            .map { it["event"]?.jsonPrimitive?.content }
        assertEquals(listOf("scanning", "connecting", "ready"), eventsAfterDrain)
        assertEquals("handshaking", h.store.device.value.phase)
        assertEquals(1, h.transport.writtenChunks.size)
        assertArrayEquals(handshakeFrame, h.transport.writtenChunks.single())
    }
}
