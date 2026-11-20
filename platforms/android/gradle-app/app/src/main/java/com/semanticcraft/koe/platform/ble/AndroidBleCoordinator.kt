package com.semanticcraft.koe.platform.ble

import android.os.SystemClock
import com.semanticcraft.koe.core.DeviceSnapshot
import com.semanticcraft.koe.core.HostAdapterEvent
import com.semanticcraft.koe.core.HostCommand
import com.semanticcraft.koe.core.HostSessionStore
import com.semanticcraft.koe.core.HostSnapshot
import com.semanticcraft.koe.platform.AndroidHostAdapter
import java.util.UUID
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

internal class CoroutineDelayScheduler(
    dispatcher: CoroutineDispatcher = Dispatchers.IO,
) {
    private val scope = CoroutineScope(SupervisorJob() + dispatcher)

    fun schedule(delayMs: Long, action: () -> Unit): AutoCloseable {
        val job = scope.launch {
            delay(delayMs.coerceAtLeast(1L))
            try {
                action()
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (_: Throwable) {
            }
        }
        return AutoCloseable { job.cancel() }
    }
}

class AndroidBleCoordinator(
    private val transport: AndroidBleTransport,
    private val addressStore: BleAddressStore,
    private val requestBlePermission: ((Boolean) -> Unit) -> Unit,
    private val clockMs: () -> Long = { SystemClock.elapsedRealtime() },
    private val scheduleDelayed: (Long, () -> Unit) -> AutoCloseable = CoroutineDelayScheduler()::schedule,
    private val onForegroundRequirementChanged: (Boolean) -> Unit = {},
) : AndroidHostAdapter, BleTransportListener {
    private val lock = Any()
    private val outboundQueue = BleOutboundQueue()
    private var boundStore: HostSessionStore? = null
    private var connectionId: String = ""
    private var activeAddress: String? = null
    private var discoveredName: String? = null
    private var payloadMtu: Int = DEFAULT_PAYLOAD_MTU
    private var isScanRequested: Boolean = false
    private var reportedReady: Boolean = false
    private var permissionRequestInFlight: Boolean = false
    private var lastObservedAutoConnect: Boolean? = null
    private var lastForegroundRequired: Boolean = false
    private var scheduledPump: AutoCloseable? = null
    private var pumping: Boolean = false
    private var repumpRequested: Boolean = false

    init {
        transport.setListener(this)
    }

    override fun onSessionBound(store: HostSessionStore) {
        synchronized(lock) {
            boundStore = store
            lastObservedAutoConnect = null
        }
        val device = store.device.value
        syncWithRuntimeDevice(device)
        if (device.autoConnect &&
            !device.connected &&
            device.phase == "disconnected" &&
            addressStore.read() != null &&
            transport.adapterState() == BleAdapterState.SUPPORTED_READY
        ) {
            requestScan()
        }
    }

    override fun onSessionUnbound() {
        val (stopFrames, mtu) = synchronized(lock) {
            val store = boundStore
            val frames = if (reportedReady && store != null) decodeStopFrames(store.device.value) else emptyList()
            boundStore = null
            lastObservedAutoConnect = null
            permissionRequestInFlight = false
            frames to payloadMtu
        }
        writeImmediateFrames(stopFrames, mtu)
        teardownLocalBleLink()
        emitForegroundRequirement(false)
    }

    override fun onSnapshotChanged(snapshot: HostSnapshot) {
        syncWithRuntimeDevice(snapshot.device)
        flushOutboundFrames()
    }

    override fun onTick(elapsedMs: Long) {
        flushOutboundFrames()
    }

    fun requestScan() {
        val store = synchronized(lock) { boundStore } ?: return
        if (synchronized(lock) { reportedReady }) {
            store.send(HostCommand.DeviceRefresh)
            flushOutboundFrames()
            return
        }
        val shouldRequest = synchronized(lock) {
            if (permissionRequestInFlight) {
                false
            } else {
                permissionRequestInFlight = true
                true
            }
        }
        if (!shouldRequest) return
        requestBlePermission { granted ->
            handleScanPermissionResult(store, granted)
        }
    }

    fun disconnect() {
        val (store, stopFrames, mtu) = synchronized(lock) {
            val current = boundStore
            val frames = if (reportedReady && current != null) {
                decodeStopFrames(current.device.value)
            } else {
                emptyList()
            }
            Triple(current, frames, payloadMtu)
        }
        writeImmediateFrames(stopFrames, mtu)
        teardownLocalBleLink()
        store?.send(HostAdapterEvent.DeviceDisconnect)
    }

    fun flushOutboundFrames() {
        val store = synchronized(lock) {
            if (reportedReady) boundStore else null
        } ?: return
        val frames = store.drainOutboundBleFrames()
        if (frames.isNotEmpty()) {
            synchronized(lock) {
                if (!reportedReady) return
                outboundQueue.enqueueFragmented(frames, payloadMtu)
            }
        }
        pumpOutboundQueue()
    }

    override fun onCandidateDiscovered(address: String, displayName: String) {
        val store = synchronized(lock) { boundStore } ?: return
        if (!store.device.value.autoConnect) return
        val newConnectionId = synchronized(lock) {
            if (!isScanRequested || activeAddress != null || reportedReady) return
            val id = "$address:${UUID.randomUUID()}"
            activeAddress = address
            discoveredName = displayName
            connectionId = id
            id
        }
        transport.stopScan()
        store.send(HostAdapterEvent.DeviceEvent("connecting", newConnectionId, displayName))
        transport.connect(address, displayName)
    }

    override fun onLinkReady(address: String, displayName: String, payloadMtu: Int) {
        val readyContext = synchronized(lock) {
            val store = boundStore ?: return
            if (activeAddress != address || reportedReady) return
            if (!store.device.value.autoConnect) {
                Triple<HostSessionStore, String, String?>(store, "", null)
            } else {
                this.payloadMtu = payloadMtu.coerceAtLeast(1)
                discoveredName = displayName
                reportedReady = true
                Triple(store, connectionId, displayName)
            }
        }
        if (readyContext.third == null) {
            teardownLocalBleLink()
            return
        }
        addressStore.write(address)
        readyContext.first.send(
            HostAdapterEvent.DeviceEvent("ready", readyContext.second, readyContext.third),
        )
        flushOutboundFrames()
    }

    override fun onWriteCompleted(success: Boolean) {
        val active = synchronized(lock) {
            if (!reportedReady) {
                false
            } else {
                outboundQueue.markWriteCompleted()
                true
            }
        }
        if (!active) return
        if (!success) {
            transport.disconnect()
            onDisconnected(ERROR_WRITE_FAILED)
            return
        }
        flushOutboundFrames()
    }

    override fun onNotifyBytes(bytes: ByteArray) {
        val store = synchronized(lock) {
            if (reportedReady) boundStore else null
        } ?: return
        store.ingestBleChunk(bytes)
        flushOutboundFrames()
    }

    override fun onDisconnected(errorMessage: String?) {
        val timerToCancel: AutoCloseable?
        val store: HostSessionStore?
        val shouldEmitDisconnected: Boolean
        val previousConnId: String
        val previousName: String?
        synchronized(lock) {
            store = boundStore
            shouldEmitDisconnected = (activeAddress != null || reportedReady) && connectionId.isNotEmpty()
            previousConnId = connectionId
            previousName = discoveredName
            timerToCancel = resetLinkStateLocked()
        }
        timerToCancel?.close()
        if (shouldEmitDisconnected) {
            store?.send(HostAdapterEvent.DeviceEvent("disconnected", previousConnId, previousName))
        }
        if (errorMessage != null) {
            store?.reportNativeError(errorMessage)
        }
    }

    fun syncWithRuntimeDevice(device: DeviceSnapshot) {
        val foregroundRequired = device.connected &&
            (device.recording || device.transferPhase == "pulling_offline" || device.busy)
        emitForegroundRequirement(foregroundRequired)

        val store: HostSessionStore?
        val wasAutoConnectDisabled: Boolean
        val hasActiveLink: Boolean
        val shouldAutoScan: Boolean
        val stopFrames: List<ByteArray>
        val mtu: Int
        synchronized(lock) {
            store = boundStore
            wasAutoConnectDisabled = (lastObservedAutoConnect == false)
            lastObservedAutoConnect = device.autoConnect
            hasActiveLink = reportedReady || isScanRequested || activeAddress != null
            stopFrames = if (!device.autoConnect && reportedReady) {
                decodeStopFrames(device)
            } else {
                emptyList()
            }
            mtu = payloadMtu
            shouldAutoScan = device.autoConnect &&
                !device.connected &&
                device.phase == "disconnected" &&
                wasAutoConnectDisabled &&
                !hasActiveLink &&
                !permissionRequestInFlight
        }

        if (!device.autoConnect) {
            addressStore.clear()
            if (!wasAutoConnectDisabled && hasActiveLink) {
                writeImmediateFrames(stopFrames, mtu)
                teardownLocalBleLink()
                if (device.phase != "disconnected") {
                    store?.send(HostAdapterEvent.DeviceDisconnect)
                }
            } else if (!device.connected && device.phase == "disconnected" && hasActiveLink) {
                writeImmediateFrames(stopFrames, mtu)
                teardownLocalBleLink()
            }
            return
        }

        if (!device.connected && device.phase == "disconnected") {
            if (synchronized(lock) { reportedReady }) {
                teardownLocalBleLink()
                return
            }
            if (shouldAutoScan) {
                requestScan()
            }
        }
    }

    private fun handleScanPermissionResult(targetStore: HostSessionStore, granted: Boolean) {
        val stillBound = synchronized(lock) {
            permissionRequestInFlight = false
            boundStore === targetStore
        }
        if (!stillBound) return
        if (!granted) {
            targetStore.reportNativeError(ERROR_UNAUTHORIZED)
            return
        }
        val adapterError = when (transport.adapterState()) {
            BleAdapterState.SUPPORTED_READY -> null
            BleAdapterState.POWERED_OFF -> ERROR_POWERED_OFF
            BleAdapterState.UNSUPPORTED -> ERROR_UNSUPPORTED
            BleAdapterState.UNAUTHORIZED -> ERROR_UNAUTHORIZED
        }
        if (adapterError != null) {
            if (synchronized(lock) { isScanRequested || activeAddress != null || reportedReady }) {
                teardownLocalBleLink()
            }
            targetStore.reportNativeError(adapterError)
            return
        }
        if (synchronized(lock) { reportedReady }) {
            targetStore.send(HostCommand.DeviceRefresh)
            flushOutboundFrames()
            return
        }
        if (synchronized(lock) { isScanRequested && activeAddress == null }) {
            return
        }
        val hadStaleLink = synchronized(lock) { activeAddress != null }
        if (hadStaleLink) {
            teardownLocalBleLink()
        }
        val scanConnectionId = UUID.randomUUID().toString()
        synchronized(lock) {
            if (boundStore !== targetStore) return
            connectionId = scanConnectionId
            isScanRequested = true
            activeAddress = null
            discoveredName = null
            reportedReady = false
            payloadMtu = DEFAULT_PAYLOAD_MTU
        }
        targetStore.send(HostAdapterEvent.DeviceEvent("scanning", scanConnectionId, null))
        transport.startScan(addressStore.read())
    }

    private fun pumpOutboundQueue() {
        synchronized(lock) {
            if (pumping) {
                repumpRequested = true
                return
            }
            pumping = true
        }
        try {
            while (true) {
                val nextChunk: ByteArray?
                val scheduleDelayMs: Long?
                val timerToCancel: AutoCloseable?
                synchronized(lock) {
                    repumpRequested = false
                    timerToCancel = scheduledPump
                    scheduledPump = null
                    if (!reportedReady) {
                        nextChunk = null
                        scheduleDelayMs = null
                    } else {
                        val now = clockMs()
                        val popped = outboundQueue.popReady(now)
                        if (popped != null) {
                            nextChunk = popped
                            scheduleDelayMs = null
                        } else {
                            nextChunk = null
                            scheduleDelayMs = outboundQueue.delayUntilNextReadyMs(now)
                        }
                    }
                }
                timerToCancel?.close()
                if (nextChunk != null) {
                    val accepted = transport.writeCharacteristic(nextChunk)
                    synchronized(lock) {
                        if (!accepted && reportedReady) {
                            outboundQueue.requeueFront(nextChunk)
                        }
                        if (reportedReady && !outboundQueue.isEmpty) {
                            repumpRequested = true
                        }
                    }
                } else if (scheduleDelayMs != null) {
                    val handle = scheduleDelayed(scheduleDelayMs.coerceAtLeast(1L)) {
                        pumpOutboundQueue()
                    }
                    val obsolete = synchronized(lock) {
                        if (reportedReady && scheduledPump == null && !outboundQueue.isEmpty) {
                            scheduledPump = handle
                            false
                        } else {
                            true
                        }
                    }
                    if (obsolete) handle.close()
                }
                val again = synchronized(lock) {
                    if (repumpRequested) {
                        true
                    } else {
                        pumping = false
                        false
                    }
                }
                if (!again) return
            }
        } catch (error: Throwable) {
            synchronized(lock) { pumping = false }
            throw error
        }
    }

    private fun teardownLocalBleLink() {
        val timerToCancel = synchronized(lock) { resetLinkStateLocked() }
        timerToCancel?.close()
        transport.stopScan()
        transport.disconnect()
    }

    private fun resetLinkStateLocked(): AutoCloseable? {
        val timer = scheduledPump
        scheduledPump = null
        outboundQueue.reset()
        activeAddress = null
        discoveredName = null
        connectionId = ""
        payloadMtu = DEFAULT_PAYLOAD_MTU
        isScanRequested = false
        reportedReady = false
        return timer
    }

    private fun decodeStopFrames(device: DeviceSnapshot): List<ByteArray> =
        device.teardownStopFramesHex.mapNotNull(BleHex::decode).filter { it.isNotEmpty() }

    private fun writeImmediateFrames(frames: List<ByteArray>, mtu: Int) {
        if (frames.isEmpty()) return
        val limit = mtu.coerceAtLeast(1)
        for (frame in frames) {
            var offset = 0
            while (offset < frame.size) {
                val end = minOf(offset + limit, frame.size)
                transport.writeCharacteristic(frame.copyOfRange(offset, end))
                offset = end
            }
        }
    }

    private fun emitForegroundRequirement(required: Boolean) {
        val changed = synchronized(lock) {
            if (lastForegroundRequired == required) {
                false
            } else {
                lastForegroundRequired = required
                true
            }
        }
        if (changed) {
            onForegroundRequirementChanged(required)
        }
    }

    companion object {
        const val ERROR_UNAUTHORIZED = "请在系统设置中允许 Koe 使用蓝牙。"
        const val ERROR_POWERED_OFF = "蓝牙已关闭，请在系统设置中打开。"
        const val ERROR_UNSUPPORTED = "这台设备不支持蓝牙连接。"
        const val ERROR_WRITE_FAILED = "设备指令发送失败，请重新连接。"
    }
}
