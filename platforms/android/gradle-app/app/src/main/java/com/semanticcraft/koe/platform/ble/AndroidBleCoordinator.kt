package com.semanticcraft.koe.platform.ble

import android.os.SystemClock
import com.semanticcraft.koe.core.DeviceSnapshot
import com.semanticcraft.koe.core.HostAdapterEvent
import com.semanticcraft.koe.core.HostCommand
import com.semanticcraft.koe.core.HostSessionStore
import com.semanticcraft.koe.core.HostSnapshot
import com.semanticcraft.koe.platform.AndroidHostAdapter
import java.util.UUID

class AndroidBleCoordinator(
    private val transport: AndroidBleTransport,
    private val addressStore: BleAddressStore,
    private val requestBlePermission: ((Boolean) -> Unit) -> Unit,
    private val clockMs: () -> Long = { SystemClock.elapsedRealtime() },
    private val scheduleDelayed: (Long, () -> Unit) -> AutoCloseable = CoroutineDelayScheduler()::schedule,
    private val onForegroundRequirementChanged: (Boolean) -> Unit = {},
) : AndroidHostAdapter, BleTransportListener {
    private enum class WriteAction { IGNORE, FINISH_TEARDOWN, PUMP_TEARDOWN, FLUSH, FAIL }

    private class DisconnectState(
        val store: HostSessionStore?,
        val wasTeardown: Boolean,
        val wasScanOnly: Boolean,
        val shouldEmitDisconnected: Boolean,
        val previousConnId: String,
        val previousName: String?,
        val timers: Pair<AutoCloseable?, AutoCloseable?>,
    )

    private class SyncState(
        val store: HostSessionStore?,
        val teardownInProgress: Boolean,
        val wasAutoConnectDisabled: Boolean,
        val hasActiveLink: Boolean,
        val shouldAutoScan: Boolean,
        val stopFrames: List<ByteArray>,
        val mtu: Int,
    )

    private val lock = Any()
    private val outboundQueue = BleOutboundQueue()
    private var boundStore: HostSessionStore? = null
    private var connectionId: String = ""
    private var activeAddress: String? = null
    private var discoveredName: String? = null
    private var payloadMtu: Int = DEFAULT_PAYLOAD_MTU
    private var isScanRequested: Boolean = false
    private var reportedReady: Boolean = false
    private var teardownPending: Boolean = false
    private var teardownEpoch: Long = 0L
    private var permissionRequestInFlight: Boolean = false
    private var lastObservedAutoConnect: Boolean? = null
    private var lastForegroundRequired: Boolean = false
    private var scheduledPump: AutoCloseable? = null
    private var teardownDeadline: AutoCloseable? = null
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
            val frames = decodeReadyStopFramesLocked(boundStore)
            boundStore = null
            lastObservedAutoConnect = null
            permissionRequestInFlight = false
            frames to payloadMtu
        }
        beginTeardown(stopFrames, mtu)
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
            Triple(current, decodeReadyStopFramesLocked(current), payloadMtu)
        }
        beginTeardown(stopFrames, mtu)
        store?.send(HostAdapterEvent.DeviceDisconnect)
    }

    fun flushOutboundFrames() {
        val store = synchronized(lock) { if (reportedReady) boundStore else null } ?: return
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
            if (activeAddress != address || reportedReady || teardownPending) return
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
        readyContext.first.send(HostAdapterEvent.DeviceEvent("ready", readyContext.second, readyContext.third))
        flushOutboundFrames()
    }

    override fun onWriteCompleted(success: Boolean) {
        val action = synchronized(lock) {
            when {
                teardownPending -> {
                    outboundQueue.markWriteCompleted()
                    if (!success || outboundQueue.isEmpty) WriteAction.FINISH_TEARDOWN else WriteAction.PUMP_TEARDOWN
                }
                reportedReady -> {
                    outboundQueue.markWriteCompleted()
                    if (success) WriteAction.FLUSH else WriteAction.FAIL
                }
                else -> WriteAction.IGNORE
            }
        }
        when (action) {
            WriteAction.IGNORE -> Unit
            WriteAction.FINISH_TEARDOWN -> teardownLocalBleLink()
            WriteAction.PUMP_TEARDOWN -> pumpOutboundQueue()
            WriteAction.FLUSH -> flushOutboundFrames()
            WriteAction.FAIL -> {
                transport.disconnect()
                onDisconnected(ERROR_WRITE_FAILED)
            }
        }
    }

    override fun onNotifyBytes(bytes: ByteArray) {
        val store = synchronized(lock) { if (reportedReady) boundStore else null } ?: return
        store.ingestBleChunk(bytes)
        flushOutboundFrames()
    }

    override fun onDisconnected(errorMessage: String?) {
        val state = synchronized(lock) {
            val wasTeardown = teardownPending
            val wasScanOnly = !wasTeardown && activeAddress == null && !reportedReady && isScanRequested
            val emitDisconnected = !wasTeardown && (activeAddress != null || reportedReady) && connectionId.isNotEmpty()
            DisconnectState(boundStore, wasTeardown, wasScanOnly, emitDisconnected, connectionId, discoveredName, resetLinkStateLocked())
        }
        state.timers.first?.close()
        state.timers.second?.close()
        if (state.shouldEmitDisconnected) {
            state.store?.send(HostAdapterEvent.DeviceEvent("disconnected", state.previousConnId, state.previousName))
        } else if (state.wasScanOnly) {
            state.store?.send(HostAdapterEvent.DeviceDisconnect)
        }
        if (!state.wasTeardown && errorMessage != null) {
            state.store?.reportNativeError(errorMessage)
        }
    }

    fun syncWithRuntimeDevice(device: DeviceSnapshot) {
        val foregroundRequired = device.connected &&
            (device.recording || device.transferPhase == "pulling_offline" || device.busy)
        emitForegroundRequirement(foregroundRequired)

        val state = synchronized(lock) {
            val wasAutoConnectDisabled = (lastObservedAutoConnect == false)
            lastObservedAutoConnect = device.autoConnect
            val hasActiveLink = reportedReady || isScanRequested || activeAddress != null
            val stopFrames = if (!device.autoConnect && reportedReady) decodeStopFrames(device) else emptyList()
            val shouldAutoScan = !teardownPending && device.autoConnect && !device.connected &&
                device.phase == "disconnected" && wasAutoConnectDisabled && !hasActiveLink && !permissionRequestInFlight
            SyncState(boundStore, teardownPending, wasAutoConnectDisabled, hasActiveLink, shouldAutoScan, stopFrames, payloadMtu)
        }

        if (state.teardownInProgress) {
            if (!device.autoConnect) addressStore.clear()
            return
        }
        if (!device.autoConnect) {
            addressStore.clear()
            if (!state.wasAutoConnectDisabled && state.hasActiveLink) {
                beginTeardown(state.stopFrames, state.mtu)
                if (device.phase != "disconnected") state.store?.send(HostAdapterEvent.DeviceDisconnect)
            } else if (!device.connected && device.phase == "disconnected" && state.hasActiveLink) {
                beginTeardown(state.stopFrames, state.mtu)
            }
            return
        }
        if (!device.connected && device.phase == "disconnected") {
            if (synchronized(lock) { reportedReady }) {
                teardownLocalBleLink()
                return
            }
            if (state.shouldAutoScan) requestScan()
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
            if (synchronized(lock) { isScanRequested || activeAddress != null || reportedReady || teardownPending }) {
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
        if (synchronized(lock) { isScanRequested && activeAddress == null }) return
        if (synchronized(lock) { activeAddress != null || teardownPending }) teardownLocalBleLink()
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

    private fun beginTeardown(stopFrames: List<ByteArray>, mtu: Int) {
        if (stopFrames.isEmpty()) {
            if (synchronized(lock) { teardownPending }) return
            teardownLocalBleLink()
            return
        }
        val (shouldStart, epoch, previousDeadline) = synchronized(lock) {
            if (!reportedReady && !teardownPending) {
                Triple(false, 0L, null)
            } else {
                reportedReady = false
                isScanRequested = false
                teardownPending = true
                teardownEpoch += 1L
                outboundQueue.replacePendingWithFragmented(stopFrames, mtu)
                val prev = teardownDeadline
                teardownDeadline = null
                Triple(true, teardownEpoch, prev)
            }
        }
        if (!shouldStart) {
            teardownLocalBleLink()
            return
        }
        previousDeadline?.close()
        transport.stopScan()
        val deadline = scheduleDelayed(TEARDOWN_WRITE_TIMEOUT_MS) {
            if (synchronized(lock) { teardownPending && teardownEpoch == epoch }) teardownLocalBleLink()
        }
        val stored = synchronized(lock) {
            if (teardownPending && teardownEpoch == epoch && teardownDeadline == null) {
                teardownDeadline = deadline
                true
            } else {
                false
            }
        }
        if (!stored) {
            deadline.close()
            return
        }
        pumpOutboundQueue()
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
                var finishTeardown = false
                val nextChunk: ByteArray?
                val scheduleDelayMs: Long?
                val timerToCancel: AutoCloseable?
                synchronized(lock) {
                    repumpRequested = false
                    timerToCancel = scheduledPump
                    scheduledPump = null
                    when {
                        !reportedReady && !teardownPending -> {
                            nextChunk = null
                            scheduleDelayMs = null
                        }
                        teardownPending && outboundQueue.isEmpty && !outboundQueue.hasInFlight -> {
                            nextChunk = null
                            scheduleDelayMs = null
                            finishTeardown = true
                        }
                        else -> {
                            val now = clockMs()
                            nextChunk = outboundQueue.popReady(now)
                            scheduleDelayMs = if (nextChunk == null) outboundQueue.delayUntilNextReadyMs(now) else null
                        }
                    }
                }
                timerToCancel?.close()
                if (finishTeardown) {
                    teardownLocalBleLink()
                } else if (nextChunk != null) {
                    val accepted = transport.writeCharacteristic(nextChunk)
                    synchronized(lock) {
                        val active = reportedReady || teardownPending
                        if (!accepted && active) outboundQueue.requeueFront(nextChunk)
                        if (active && !outboundQueue.isEmpty) repumpRequested = true
                    }
                } else if (scheduleDelayMs != null) {
                    val handle = scheduleDelayed(scheduleDelayMs.coerceAtLeast(1L)) { pumpOutboundQueue() }
                    val obsolete = synchronized(lock) {
                        if ((reportedReady || teardownPending) && scheduledPump == null && !outboundQueue.isEmpty) {
                            scheduledPump = handle
                            false
                        } else {
                            true
                        }
                    }
                    if (obsolete) handle.close()
                }
                val again = synchronized(lock) {
                    if (repumpRequested) true else { pumping = false; false }
                }
                if (!again) return
            }
        } catch (error: Throwable) {
            synchronized(lock) { pumping = false }
            throw error
        }
    }

    private fun teardownLocalBleLink() {
        val (pumpTimer, deadlineTimer) = synchronized(lock) { resetLinkStateLocked() }
        pumpTimer?.close()
        deadlineTimer?.close()
        transport.stopScan()
        transport.disconnect()
    }

    private fun resetLinkStateLocked(): Pair<AutoCloseable?, AutoCloseable?> {
        val timers = scheduledPump to teardownDeadline
        scheduledPump = null
        teardownDeadline = null
        outboundQueue.reset()
        activeAddress = null
        discoveredName = null
        connectionId = ""
        payloadMtu = DEFAULT_PAYLOAD_MTU
        isScanRequested = false
        reportedReady = false
        teardownPending = false
        return timers
    }

    private fun decodeReadyStopFramesLocked(store: HostSessionStore?): List<ByteArray> =
        if (reportedReady && store != null) decodeStopFrames(store.device.value) else emptyList()

    private fun decodeStopFrames(device: DeviceSnapshot): List<ByteArray> =
        device.teardownStopFramesHex.mapNotNull(BleHex::decode).filter { it.isNotEmpty() }

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
        const val TEARDOWN_WRITE_TIMEOUT_MS = 1_500L
        const val ERROR_UNAUTHORIZED = "请在系统设置中允许 Koe 使用蓝牙。"
        const val ERROR_POWERED_OFF = "蓝牙已关闭，请在系统设置中打开。"
        const val ERROR_UNSUPPORTED = "这台设备不支持蓝牙连接。"
        const val ERROR_WRITE_FAILED = "设备指令发送失败，请重新连接。"
    }
}
