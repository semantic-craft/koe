package com.semanticcraft.koe.core

import com.semanticcraft.koe.bridge.KoeNativeBridge
import java.io.File
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

internal class ViewRequestGeneration {
    var latestRustGeneration: Long = 0L
        private set

    fun acceptRustGeneration(generation: Long): Boolean {
        if (generation < latestRustGeneration) return false
        latestRustGeneration = generation
        return true
    }

    fun reset(generation: Long) {
        latestRustGeneration = generation
    }
}

class HostSessionStore(
    val workspacePath: String,
    private val bridge: HostBridgeClient = JniHostBridgeClient(),
    private val credentials: KoeNativeBridge.CredentialBridge? = null,
    private val isolatedCredentials: Boolean = true,
    private val allowDebugFixture: Boolean = false,
    private val clockEpochSec: () -> Long = { System.currentTimeMillis() / 1_000L },
    private val clockEpochMs: () -> Long = { System.currentTimeMillis() },
    autoOpen: Boolean = true,
) {
    private val stateLock = Any()
    private var currentSnapshot: HostSnapshot = HostSnapshot.empty
    private var lastProjectedNowSec: Long = 0L
    private var requestGate = ViewRequestGeneration()
    private val traceBuffer = HostTraceRingBuffer(HostTraceRingBuffer.DEFAULT_CAPACITY)

    var handle: Long = 0L
        private set
    var nativeError: String? = null
        private set
    var onSnapshotChanged: ((HostSnapshot) -> Unit)? = null
    var onTraceUpdated: (() -> Unit)? = null

    private val _platform = MutableStateFlow(HostPlatformSnapshot.androidDefault)
    val platform: StateFlow<HostPlatformSnapshot> = _platform.asStateFlow()
    private val _navigation = MutableStateFlow(NavigationChromeSlice.empty)
    val navigation: StateFlow<NavigationChromeSlice> = _navigation.asStateFlow()
    private val _today = MutableStateFlow(TodaySlice.empty)
    val today: StateFlow<TodaySlice> = _today.asStateFlow()
    private val _quickNoteWorkspace = MutableStateFlow(QuickNoteWorkspaceSnapshot.empty)
    val quickNoteWorkspace: StateFlow<QuickNoteWorkspaceSnapshot> = _quickNoteWorkspace.asStateFlow()
    private val _allDayWorkspace = MutableStateFlow(AllDayWorkspaceSnapshot.empty)
    val allDayWorkspace: StateFlow<AllDayWorkspaceSnapshot> = _allDayWorkspace.asStateFlow()
    private val _liveMinutesWorkspace = MutableStateFlow(LiveMinutesWorkspaceSnapshot.empty)
    val liveMinutesWorkspace: StateFlow<LiveMinutesWorkspaceSnapshot> = _liveMinutesWorkspace.asStateFlow()
    private val _liveMinutesCoverage = MutableStateFlow<MeetingCoverageSnapshot?>(null)
    val liveMinutesCoverage: StateFlow<MeetingCoverageSnapshot?> = _liveMinutesCoverage.asStateFlow()
    private val _recordDetail = MutableStateFlow(RecordDetailSlice.empty)
    val recordDetail: StateFlow<RecordDetailSlice> = _recordDetail.asStateFlow()
    private val _records = MutableStateFlow<List<RecordSnapshot>>(emptyList())
    val records: StateFlow<List<RecordSnapshot>> = _records.asStateFlow()
    private val _tasks = MutableStateFlow<List<TaskSnapshot>>(emptyList())
    val tasks: StateFlow<List<TaskSnapshot>> = _tasks.asStateFlow()
    private val _memories = MutableStateFlow<List<MemorySnapshot>>(emptyList())
    val memories: StateFlow<List<MemorySnapshot>> = _memories.asStateFlow()
    private val _trashRecords = MutableStateFlow<List<TrashRecordSnapshot>>(emptyList())
    val trashRecords: StateFlow<List<TrashRecordSnapshot>> = _trashRecords.asStateFlow()
    private val _ask = MutableStateFlow(HostSnapshot.empty.ask)
    val ask: StateFlow<AskSnapshot> = _ask.asStateFlow()
    private val _captureStudio = MutableStateFlow(CaptureStudioSlice.empty)
    val captureStudio: StateFlow<CaptureStudioSlice> = _captureStudio.asStateFlow()
    private val _device = MutableStateFlow(DeviceSnapshot.empty)
    val device: StateFlow<DeviceSnapshot> = _device.asStateFlow()
    private val _settings = MutableStateFlow(SettingsSlice.empty)
    val settings: StateFlow<SettingsSlice> = _settings.asStateFlow()
    private val _playback = MutableStateFlow(HostSnapshot.empty.playback)
    val playback: StateFlow<PlaybackSnapshot> = _playback.asStateFlow()
    private val _activeCapture = MutableStateFlow<ActiveCaptureSnapshot?>(null)
    val activeCapture: StateFlow<ActiveCaptureSnapshot?> = _activeCapture.asStateFlow()
    private val _liveCaption = MutableStateFlow<LiveCaptionSnapshot?>(null)
    val liveCaption: StateFlow<LiveCaptionSnapshot?> = _liveCaption.asStateFlow()

    val currentGeneration: Long
        get() = synchronized(stateLock) { currentSnapshot.generation }

    fun currentLifecycle(): LifecycleSnapshot? = synchronized(stateLock) { currentSnapshot.lifecycle }

    fun currentMicrophone(): MicrophoneSnapshot? = synchronized(stateLock) { currentSnapshot.microphone }

    init {
        if (autoOpen) {
            openSession()
        }
    }

    fun openSession(): Boolean {
        synchronized(stateLock) {
            if (handle != 0L) return true
            if (bridge.apiVersion() != EXPECTED_ABI_VERSION) {
                setNativeErrorLocked("应用与数据引擎版本不一致，请重新构建应用。")
                return false
            }
            val opened = if (credentials != null) {
                bridge.sessionCreateWithCredentials(workspacePath, credentials, isolatedCredentials)
            } else {
                bridge.sessionCreate(workspacePath)
            }
            if (opened == 0L) {
                setNativeErrorLocked("无法打开工作区，请检查文件夹的访问权限。")
                return false
            }
            handle = opened
        }
        refreshSnapshot()
        return true
    }

    fun shutdown() {
        synchronized(stateLock) {
            if (handle == 0L) return
            bridge.sessionDestroy(handle)
            handle = 0L
        }
    }

    fun reportNativeError(message: String) {
        synchronized(stateLock) { setNativeErrorLocked(message) }
    }

    fun clearError() {
        synchronized(stateLock) { setNativeErrorLocked(null) }
        send(HostCommand.ClearError)
    }

    fun recentTraceEntries(): List<HostTraceEntry> = traceBuffer.snapshot()

    fun exportTraceJson(): String = traceBuffer.exportJson()

    fun writeTraceAtomically(outputFile: File): Boolean = traceBuffer.writeAtomically(outputFile)

    fun send(command: HostCommand, nowEpochSec: Long = 0L) {
        val json = try {
            command.toJsonString()
        } catch (_: Exception) {
            synchronized(stateLock) {
                setNativeErrorLocked("无法发送这次操作，请重试。")
                recordTraceLocked(kind = "command", name = command.commandType)
            }
            onTraceUpdated?.invoke()
            return
        }
        dispatchEncodedJson(json, traceKind = "command", commandType = command.commandType, nowEpochSec = nowEpochSec)
    }

    fun send(event: HostAdapterEvent, nowEpochSec: Long = 0L) {
        val json = try {
            event.toJsonString()
        } catch (_: Exception) {
            synchronized(stateLock) {
                setNativeErrorLocked("无法发送这次操作，请重试。")
                recordTraceLocked(kind = "event", name = event.eventType)
            }
            onTraceUpdated?.invoke()
            return
        }
        dispatchEncodedJson(json, traceKind = "event", commandType = event.eventType, nowEpochSec = nowEpochSec)
    }

    val canReleaseToPhone: Boolean
        get() = today.value.picker?.canReleaseToPhone ?: (device.value.transferPhase != "pulling_offline")

    fun toggleModeSession(card: ModePickerCardSnapshot) {
        if (card.isSessionActive) {
            send(HostCommand.CaptureActionCommand(action = CaptureAction.END))
        } else {
            CaptureMode.fromRaw(card.mode)?.let { mode ->
                send(HostCommand.StartCaptureMode(mode = mode, stayOnPage = true))
            }
        }
    }

    fun performCaptureAction(action: CaptureAction) {
        send(HostCommand.CaptureActionCommand(action = action))
    }

    fun refreshSnapshot(nowEpochSec: Long = 0L) {
        var traced = false
        synchronized(stateLock) {
            if (handle == 0L) return
            try {
                val effectiveNow = resolveNowEpochSec(nowEpochSec)
                val raw = bridge.sessionSnapshotJson(handle, effectiveNow)
                if (raw == null) {
                    setNativeErrorLocked("无法读取工作区状态。")
                    return
                }
                applySnapshotJsonLocked(raw, projectedNowSec = effectiveNow, resetGate = false)
            } finally {
                recordTraceLocked(kind = "snapshot", name = "snapshot")
                traced = true
            }
        }
        if (traced) {
            onTraceUpdated?.invoke()
        }
    }

    fun refreshSnapshotIfNeeded(minGeneration: Long, nowEpochSec: Long = 0L) {
        val needsRefresh = synchronized(stateLock) { minGeneration > currentSnapshot.generation }
        if (needsRefresh) refreshSnapshot(nowEpochSec)
    }

    fun ingestMicrophonePcm(
        recordId: String,
        sessionId: String,
        lane: String,
        sequence: Long,
        epoch: Long,
        capturedStartNs: Long?,
        samples: ShortArray,
        sampleCount: Int = samples.size,
        nowEpochSec: Long = 0L,
    ): PcmIngestReceipt = synchronized(stateLock) {
        if (handle == 0L) return PcmIngestReceipt(0L, 0L, PcmIngestStatus.REJECTED)
        setNativeErrorLocked(null)
        bridge.sessionIngestPcm(
            handle, recordId, sessionId, lane, sequence, epoch,
            capturedStartNs, samples, sampleCount, nowEpochSec,
        )
    }

    fun reportPlaybackProgress(
        recordId: String,
        requestId: Long,
        positionMs: Long,
        isPlaying: Boolean,
        nowEpochSec: Long = 0L,
    ) {
        var needsFullRefresh = false
        var minRefreshGeneration: Long? = null
        synchronized(stateLock) {
            if (handle == 0L) return
            val receipt = bridge.sessionReportPlaybackProgress(
                handle, recordId, requestId, positionMs, isPlaying, lastProjectedNowSec, nowEpochSec,
            )
            when {
                receipt.needsFullSnapshot -> needsFullRefresh = true
                !receipt.applied -> minRefreshGeneration = receipt.generation
                receipt.prevGeneration != currentSnapshot.generation ||
                    !requestGate.acceptRustGeneration(receipt.generation) -> needsFullRefresh = true
                else -> {
                    val next = currentSnapshot.updatingPlayback(
                        generation = receipt.generation,
                        positionMs = receipt.positionMs,
                        isPlaying = receipt.isPlaying,
                    )
                    currentSnapshot = next
                    lastProjectedNowSec = receipt.nowEpochSec
                    _playback.value = next.playback
                    onSnapshotChanged?.invoke(next)
                }
            }
        }
        if (needsFullRefresh) {
            refreshSnapshot(nowEpochSec)
        } else if (minRefreshGeneration != null) {
            refreshSnapshotIfNeeded(minRefreshGeneration, nowEpochSec)
        }
    }

    fun ingestBleChunk(bytes: ByteArray, nowEpochSec: Long = 0L) {
        val nextGeneration = synchronized(stateLock) {
            if (handle == 0L) return
            bridge.sessionIngestBle(handle, bytes, nowEpochSec)
        }
        refreshSnapshotIfNeeded(nextGeneration, nowEpochSec)
    }

    fun pollTimers(elapsedMs: Long, nowEpochSec: Long = 0L) {
        val nextGeneration = synchronized(stateLock) {
            if (handle == 0L) return
            bridge.sessionPollTimers(handle, elapsedMs, nowEpochSec)
        }
        refreshSnapshotIfNeeded(nextGeneration, nowEpochSec)
    }

    fun drainOutboundBleFrames(): List<ByteArray> = synchronized(stateLock) {
        if (handle == 0L) return emptyList()
        val raw = bridge.sessionDrainBleTx(handle) ?: return emptyList()
        if (raw.isEmpty()) return emptyList()
        val frames = mutableListOf<ByteArray>()
        var offset = 0
        while (offset + 4 <= raw.size) {
            val length = (raw[offset].toInt() and 0xFF) or
                ((raw[offset + 1].toInt() and 0xFF) shl 8) or
                ((raw[offset + 2].toInt() and 0xFF) shl 16) or
                ((raw[offset + 3].toInt() and 0xFF) shl 24)
            offset += 4
            if (length < 0 || offset + length > raw.size) {
                setNativeErrorLocked("无法读取设备发送队列。")
                return emptyList()
            }
            frames.add(raw.copyOfRange(offset, offset + length))
            offset += length
        }
        if (offset != raw.size) {
            setNativeErrorLocked("无法读取设备发送队列。")
            return emptyList()
        }
        frames
    }

    fun drainLocalAsrEffects(): ByteArray = synchronized(stateLock) {
        if (handle == 0L) return ByteArray(0)
        bridge.sessionDrainLocalAsr(handle) ?: ByteArray(0)
    }

    fun loadDebugSnapshotFixtureJson(json: String): Boolean {
        if (!allowDebugFixture) return false
        val applied = synchronized(stateLock) {
            try {
                applySnapshotJsonLocked(json, projectedNowSec = 0L, resetGate = true)
            } finally {
                recordTraceLocked(kind = "fixture", name = "fixture")
            }
        }
        onTraceUpdated?.invoke()
        return applied
    }

    internal fun applySnapshotJson(json: String, projectedNowSec: Long = 0L): Boolean =
        synchronized(stateLock) {
            applySnapshotJsonLocked(json, projectedNowSec = projectedNowSec, resetGate = false)
        }

    private fun dispatchEncodedJson(json: String, traceKind: String, commandType: String, nowEpochSec: Long) {
        var traced = false
        synchronized(stateLock) {
            if (handle == 0L) return
            try {
                val preservesNativeError = commandType == "sync_audio_inputs" ||
                    commandType == "sync_app_metadata" ||
                    commandType.startsWith("local_asr_")
                if (!preservesNativeError) setNativeErrorLocked(null)
                val effectiveNow = resolveNowEpochSec(nowEpochSec)
                val response = bridge.sessionDispatchJson(handle, json, effectiveNow)
                if (response == null) {
                    setNativeErrorLocked("操作未能完成，请重试。工作区数据仍然保留。")
                    return
                }
                applySnapshotJsonLocked(response, projectedNowSec = effectiveNow, resetGate = false)
            } finally {
                recordTraceLocked(kind = traceKind, name = commandType)
                traced = true
            }
        }
        if (traced) {
            onTraceUpdated?.invoke()
        }
    }

    private fun applySnapshotJsonLocked(json: String, projectedNowSec: Long, resetGate: Boolean): Boolean {
        val decoded = try {
            HostJson.json.decodeFromString(HostSnapshot.serializer(), json)
        } catch (_: Exception) {
            setNativeErrorLocked("无法读取数据引擎的回应，请重新打开应用。")
            return false
        }
        if (decoded.version != EXPECTED_ABI_VERSION) {
            setNativeErrorLocked("数据引擎返回了不兼容的版本。")
            return false
        }
        if (resetGate) {
            nativeError = null
            requestGate.reset(decoded.generation)
        } else if (!requestGate.acceptRustGeneration(decoded.generation)) {
            return false
        }
        if (projectedNowSec > 0L) lastProjectedNowSec = projectedNowSec
        if (decoded != currentSnapshot || resetGate) {
            currentSnapshot = decoded
            reconcileSlicesLocked()
            onSnapshotChanged?.invoke(decoded)
        }
        return true
    }

    private fun setNativeErrorLocked(message: String?) {
        if (nativeError == message) return
        nativeError = message
        _navigation.value = NavigationChromeSlice.from(currentSnapshot, nativeError)
    }

    private fun recordTraceLocked(kind: String, name: String) {
        traceBuffer.append(
            HostTraceEntry(
                kind = kind,
                name = name,
                generation = currentSnapshot.generation,
                section = currentSnapshot.section,
                hasError = (nativeError ?: currentSnapshot.error) != null,
                timestampEpochMs = clockEpochMs().coerceAtLeast(0L),
            ),
        )
    }

    private fun resolveNowEpochSec(requested: Long): Long =
        if (requested > 0L) requested else clockEpochSec().coerceAtLeast(0L)

    private fun reconcileSlicesLocked() {
        val snap = currentSnapshot
        _platform.value = snap.platform
        _navigation.value = NavigationChromeSlice.from(snap, nativeError)
        _today.value = TodaySlice.from(snap)
        _quickNoteWorkspace.value = snap.workspaces?.quickNote ?: QuickNoteWorkspaceSnapshot.empty
        _allDayWorkspace.value = snap.workspaces?.allDay ?: AllDayWorkspaceSnapshot.empty
        val resolvedLive = snap.workspaces?.liveMinutes ?: LiveMinutesWorkspaceSnapshot.empty
        _liveMinutesWorkspace.value = resolvedLive.withoutCoverage()
        _liveMinutesCoverage.value = resolvedLive.coverage
        _recordDetail.value = RecordDetailSlice.from(snap)
        _records.value = snap.records
        _tasks.value = snap.tasks
        _memories.value = snap.memories
        _trashRecords.value = snap.trashRecords
        _ask.value = snap.ask
        _captureStudio.value = CaptureStudioSlice.from(snap)
        _device.value = snap.device
        _settings.value = SettingsSlice.from(snap)
        _playback.value = snap.playback
        _activeCapture.value = snap.activeCapture
        _liveCaption.value = snap.liveCaption
    }

    companion object {
        const val EXPECTED_ABI_VERSION = 2
    }
}
