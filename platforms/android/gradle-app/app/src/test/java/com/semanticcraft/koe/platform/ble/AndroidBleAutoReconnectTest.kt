package com.semanticcraft.koe.platform.ble

import com.semanticcraft.koe.bridge.KoeNativeBridge
import com.semanticcraft.koe.core.DeviceSnapshot
import com.semanticcraft.koe.core.HostBridgeClient
import com.semanticcraft.koe.core.HostJson
import com.semanticcraft.koe.core.HostSessionStore
import com.semanticcraft.koe.core.HostSnapshot
import com.semanticcraft.koe.core.PcmIngestReceipt
import com.semanticcraft.koe.core.PcmIngestStatus
import com.semanticcraft.koe.core.PlaybackProgressReceipt
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class AndroidBleAutoReconnectTest {
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
        var state: BleAdapterState,
    ) : AndroidBleTransport {
        val scanCalls = mutableListOf<String?>()

        override fun setListener(listener: BleTransportListener?) {}
        override fun adapterState(): BleAdapterState = state
        override fun startScan(savedAddress: String?) {
            scanCalls.add(savedAddress)
        }

        override fun stopScan() {}
        override fun connect(address: String, displayName: String) {}
        override fun writeCharacteristic(data: ByteArray): Boolean = true
        override fun disconnect() {}
    }

    private class MinimalBleBridgeClient(
        device: DeviceSnapshot,
    ) : HostBridgeClient {
        private var currentSnapshot = HostSnapshot.empty.copy(generation = 1L, device = device)
        val dispatchedEvents = mutableListOf<JsonObject>()

        override fun apiVersion(): Int = 2
        override fun sessionCreate(directory: String): Long = 701L
        override fun sessionCreateWithCredentials(
            directory: String,
            credentialBridge: KoeNativeBridge.CredentialBridge,
            isolated: Boolean,
        ): Long = 701L

        override fun sessionDestroy(handle: Long): Boolean = true
        override fun sessionGeneration(handle: Long): Long = currentSnapshot.generation
        override fun sessionSnapshotJson(handle: Long, nowEpochSec: Long): String =
            HostJson.json.encodeToString(HostSnapshot.serializer(), currentSnapshot)

        override fun sessionDispatchJson(handle: Long, commandJson: String, nowEpochSec: Long): String {
            val obj = HostJson.json.parseToJsonElement(commandJson) as JsonObject
            dispatchedEvents.add(obj)
            if (obj["type"]?.jsonPrimitive?.content == "device_event" &&
                obj["event"]?.jsonPrimitive?.content == "scanning"
            ) {
                currentSnapshot = currentSnapshot.copy(
                    generation = currentSnapshot.generation + 1L,
                    device = currentSnapshot.device.copy(phase = "scanning", connected = false),
                )
            }
            return sessionSnapshotJson(handle, nowEpochSec)
        }

        override fun sessionIngestBle(handle: Long, bytes: ByteArray, nowEpochSec: Long): Long =
            currentSnapshot.generation

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
        ): PcmIngestReceipt = PcmIngestReceipt(currentSnapshot.generation, 0L, PcmIngestStatus.REJECTED)

        override fun sessionReportPlaybackProgress(
            handle: Long,
            recordId: String,
            requestId: Long,
            positionMs: Long,
            isPlaying: Boolean,
            lastProjectedNowSec: Long,
            nowEpochSec: Long,
        ): PlaybackProgressReceipt = PlaybackProgressReceipt(
            currentSnapshot.generation, currentSnapshot.generation, positionMs, nowEpochSec, isPlaying, true, false,
        )

        override fun sessionDrainBleTx(handle: Long): ByteArray = ByteArray(0)
        override fun sessionDrainLocalAsr(handle: Long): ByteArray = ByteArray(0)
        override fun sessionPollTimers(handle: Long, elapsedMs: Long, nowEpochSec: Long): Long =
            currentSnapshot.generation
    }

    private data class BoundResult(
        val transport: FakeBleTransport,
        val bridge: MinimalBleBridgeClient,
        val permissionRequests: Int,
    )

    private fun bindCoordinator(
        autoConnect: Boolean = true,
        savedAddress: String? = "AA:BB:CC:DD:EE:FF",
        adapterState: BleAdapterState = BleAdapterState.SUPPORTED_READY,
        connected: Boolean = false,
        phase: String = "disconnected",
    ): BoundResult {
        val bridge = MinimalBleBridgeClient(
            DeviceSnapshot.empty.copy(
                autoConnect = autoConnect,
                connected = connected,
                phase = phase,
            ),
        )
        val store = HostSessionStore(workspacePath = "/tmp/koe-ble-autoreconnect", bridge = bridge)
        val transport = FakeBleTransport(state = adapterState)
        var permissionRequests = 0
        val coordinator = AndroidBleCoordinator(
            transport = transport,
            addressStore = InMemoryAddressStore(saved = savedAddress),
            requestBlePermission = { cb ->
                permissionRequests += 1
                cb(adapterState == BleAdapterState.SUPPORTED_READY)
            },
            scheduleDelayed = { _, _ -> AutoCloseable {} },
        )
        coordinator.onSessionBound(store)
        return BoundResult(transport, bridge, permissionRequests)
    }

    @Test
    fun onSessionBoundAutoScansWhenPairedAutoConnectEnabledAndAdapterReady() {
        val result = bindCoordinator(
            autoConnect = true,
            savedAddress = "AA:BB:CC:DD:EE:FF",
            adapterState = BleAdapterState.SUPPORTED_READY,
        )

        assertEquals(listOf("AA:BB:CC:DD:EE:FF"), result.transport.scanCalls)
        assertEquals(1, result.permissionRequests)
        assertEquals(
            "scanning",
            result.bridge.dispatchedEvents.lastOrNull()?.get("event")?.jsonPrimitive?.content,
        )
    }

    @Test
    fun onSessionBoundSkipsAutoScanWhenNoSavedAddress() {
        val result = bindCoordinator(
            autoConnect = true,
            savedAddress = null,
            adapterState = BleAdapterState.SUPPORTED_READY,
        )

        assertTrue(result.transport.scanCalls.isEmpty())
        assertEquals(0, result.permissionRequests)
        assertTrue(result.bridge.dispatchedEvents.isEmpty())
    }

    @Test
    fun onSessionBoundSkipsAutoScanWhenAdapterUnauthorized() {
        val result = bindCoordinator(
            autoConnect = true,
            savedAddress = "AA:BB:CC:DD:EE:FF",
            adapterState = BleAdapterState.UNAUTHORIZED,
        )

        assertTrue(result.transport.scanCalls.isEmpty())
        assertEquals(0, result.permissionRequests)
        assertTrue(result.bridge.dispatchedEvents.isEmpty())
    }

    @Test
    fun onSessionBoundSkipsAutoScanWhenAutoConnectDisabled() {
        val result = bindCoordinator(
            autoConnect = false,
            savedAddress = "AA:BB:CC:DD:EE:FF",
            adapterState = BleAdapterState.SUPPORTED_READY,
        )

        assertTrue(result.transport.scanCalls.isEmpty())
        assertEquals(0, result.permissionRequests)
        assertTrue(result.bridge.dispatchedEvents.isEmpty())
    }
}
