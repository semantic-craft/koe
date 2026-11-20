package com.semanticcraft.koe.platform.capture

import android.media.AudioDeviceInfo
import com.semanticcraft.koe.bridge.KoeNativeBridge
import com.semanticcraft.koe.core.HostAudioInputDescriptor
import com.semanticcraft.koe.core.HostBridgeClient
import com.semanticcraft.koe.core.HostJson
import com.semanticcraft.koe.core.HostSessionStore
import com.semanticcraft.koe.core.HostSnapshot
import com.semanticcraft.koe.core.PcmIngestReceipt
import com.semanticcraft.koe.core.PcmIngestStatus
import com.semanticcraft.koe.core.PlaybackProgressReceipt
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class AndroidAudioInputMonitorTest {
    private class FakeAudioInputProvider(
        var inputs: List<HostAudioInputDescriptor>,
    ) : AudioInputProvider {
        var registerCount = 0
        var unregisterCount = 0
        private var listener: (() -> Unit)? = null

        val isRegistered: Boolean
            get() = listener != null

        override fun listInputs(): List<HostAudioInputDescriptor> = inputs

        override fun registerListener(onChanged: () -> Unit): AutoCloseable {
            registerCount += 1
            listener = onChanged
            var closed = false
            return AutoCloseable {
                if (!closed) {
                    closed = true
                    unregisterCount += 1
                    if (listener === onChanged) listener = null
                }
            }
        }

        fun notifyDevicesChanged() {
            listener?.invoke()
        }
    }

    private class RecordingBridge : HostBridgeClient {
        private var snapshot = HostSnapshot.empty.copy(generation = 1L)
        val dispatched = mutableListOf<JsonObject>()

        override fun apiVersion(): Int = 2
        override fun sessionCreate(directory: String): Long = 701L
        override fun sessionCreateWithCredentials(
            directory: String,
            credentialBridge: KoeNativeBridge.CredentialBridge,
            isolated: Boolean,
        ): Long = 701L
        override fun sessionDestroy(handle: Long): Boolean = true
        override fun sessionGeneration(handle: Long): Long = snapshot.generation
        override fun sessionSnapshotJson(handle: Long, nowEpochSec: Long): String =
            HostJson.json.encodeToString(HostSnapshot.serializer(), snapshot)

        override fun sessionDispatchJson(handle: Long, commandJson: String, nowEpochSec: Long): String {
            dispatched.add(HostJson.json.parseToJsonElement(commandJson) as JsonObject)
            snapshot = snapshot.copy(generation = snapshot.generation + 1L)
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
        override fun sessionPollTimers(handle: Long, elapsedMs: Long, nowEpochSec: Long): Long = snapshot.generation
    }

    @Test
    fun mapAudioDeviceTransportClassifiesBuiltInBluetoothUsbAndExternal() {
        assertEquals("built_in", mapAudioDeviceTransport(AudioDeviceInfo.TYPE_BUILTIN_MIC))
        assertEquals("bluetooth", mapAudioDeviceTransport(AudioDeviceInfo.TYPE_BLUETOOTH_SCO))
        assertEquals("bluetooth", mapAudioDeviceTransport(AudioDeviceInfo.TYPE_BLUETOOTH_A2DP))
        assertEquals("bluetooth", mapAudioDeviceTransport(AudioDeviceInfo.TYPE_BLE_HEADSET))
        assertEquals("usb", mapAudioDeviceTransport(AudioDeviceInfo.TYPE_USB_DEVICE))
        assertEquals("usb", mapAudioDeviceTransport(AudioDeviceInfo.TYPE_USB_ACCESSORY))
        assertEquals("usb", mapAudioDeviceTransport(AudioDeviceInfo.TYPE_USB_HEADSET))
        assertEquals("external", mapAudioDeviceTransport(AudioDeviceInfo.TYPE_WIRED_HEADSET))
        assertEquals("external", mapAudioDeviceTransport(AudioDeviceInfo.TYPE_LINE_ANALOG))
    }

    @Test
    fun syncsOnBindDeduplicatesUnchangedInputsAndUnregistersOnUnbind() {
        val builtIn = HostAudioInputDescriptor(
            id = "1",
            name = "Pixel Mic",
            transport = "built_in",
            isDefault = true,
        )
        val usbMic = HostAudioInputDescriptor(
            id = "2",
            name = "USB Podcast Mic",
            transport = "usb",
            isDefault = false,
        )
        val provider = FakeAudioInputProvider(listOf(builtIn))
        val bridge = RecordingBridge()
        val store = HostSessionStore(workspacePath = "/tmp/koe-input-monitor-test", bridge = bridge)
        val monitor = AndroidAudioInputMonitor(provider)

        monitor.onSessionBound(store)
        assertTrue(provider.isRegistered)
        assertEquals(1, bridge.dispatched.size)
        assertEquals("sync_audio_inputs", bridge.dispatched[0]["type"]?.jsonPrimitive?.content)
        assertEquals(1, bridge.dispatched[0]["inputs"]?.jsonArray?.size)

        provider.notifyDevicesChanged()
        assertEquals(1, bridge.dispatched.size)

        provider.inputs = listOf(builtIn, usbMic)
        provider.notifyDevicesChanged()
        assertEquals(2, bridge.dispatched.size)
        val syncedIds = bridge.dispatched[1]["inputs"]?.jsonArray?.map {
            it.jsonObject["id"]?.jsonPrimitive?.content
        }
        assertEquals(listOf("1", "2"), syncedIds)

        monitor.onSessionUnbound()
        assertFalse(provider.isRegistered)
        assertEquals(1, provider.unregisterCount)

        provider.inputs = listOf(builtIn)
        provider.notifyDevicesChanged()
        assertEquals(2, bridge.dispatched.size)
    }
}
