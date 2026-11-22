package com.semanticcraft.koe.core

import com.semanticcraft.koe.bridge.KoeNativeBridge
import java.io.File
import java.util.concurrent.Executor
import java.util.concurrent.RejectedExecutionException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.flow.StateFlow

class HostSessionStore(
    val workspacePath: String,
    private val bridge: HostBridgeClient = JniHostBridgeClient(),
    private val credentials: KoeNativeBridge.CredentialBridge? = null,
    private val isolatedCredentials: Boolean = true,
    private val allowDebugFixture: Boolean = false,
    private val clockEpochSec: () -> Long = { System.currentTimeMillis() / 1_000L },
    private val clockEpochMs: () -> Long = { System.currentTimeMillis() },
    autoOpen: Boolean = true,
    private val verificationTrace: Boolean = false,
    private val commandExecutor: Executor? = null,
) {
    private val stateLock = Any()
    private var currentSnapshot: HostSnapshot = HostSnapshot.empty
    private var publishSequence: Long = 0L
    private var lastProjectedNowSec: Long = 0L
    private var requestGate = ViewRequestGeneration()
    private var resumeLiveOnCommand = false
    private val traceBuffer = HostTraceRingBuffer(if (verificationTrace) 2048 else HostTraceRingBuffer.DEFAULT_CAPACITY)
    private val slices = HostSessionSliceFlows()

    var handle: Long = 0L
        private set
    var nativeError: String? = null
        private set
    @Volatile
    var bridgeActions: HostBridgeActions = HostBridgeActions()
    @Volatile
    var onSnapshotChanged: ((HostSnapshot) -> Unit)? = null
    @Volatile
    internal var onSnapshotPublished: ((HostSnapshot, Long) -> Unit)? = null
    @Volatile
    var onTraceUpdated: (() -> Unit)? = null

    val platform: StateFlow<HostPlatformSnapshot> = slices.platform
    val navigation: StateFlow<NavigationChromeSlice> = slices.navigation
    val today: StateFlow<TodaySlice> = slices.today
    val quickNoteWorkspace: StateFlow<QuickNoteWorkspaceSnapshot> = slices.quickNoteWorkspace
    val allDayWorkspace: StateFlow<AllDayWorkspaceSnapshot> = slices.allDayWorkspace
    val liveMinutesWorkspace: StateFlow<LiveMinutesWorkspaceSnapshot> = slices.liveMinutesWorkspace
    val liveMinutesCoverage: StateFlow<MeetingCoverageSnapshot?> = slices.liveMinutesCoverage
    val recordDetail: StateFlow<RecordDetailSlice> = slices.recordDetail
    val records: StateFlow<List<RecordSnapshot>> = slices.records
    val tasks: StateFlow<List<TaskSnapshot>> = slices.tasks
    val memories: StateFlow<List<MemorySnapshot>> = slices.memories
    val trashRecords: StateFlow<List<TrashRecordSnapshot>> = slices.trashRecords
    val ask: StateFlow<AskSnapshot> = slices.ask
    val captureStudio: StateFlow<CaptureStudioSlice> = slices.captureStudio
    val device: StateFlow<DeviceSnapshot> = slices.device
    val settings: StateFlow<SettingsSlice> = slices.settings
    val playback: StateFlow<PlaybackSnapshot> = slices.playback
    val keepAwake: StateFlow<Boolean> = slices.keepAwake
    val activeCapture: StateFlow<ActiveCaptureSnapshot?> = slices.activeCapture
    val liveCaption: StateFlow<LiveCaptionSnapshot?> = slices.liveCaption

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
        enqueueOrRun {
            synchronized(stateLock) { setNativeErrorLocked(null) }
            sendReturningError(HostCommand.ClearError)
        }
    }

    fun recentTraceEntries(): List<HostTraceEntry> = traceBuffer.snapshot()

    fun exportTraceJson(): String = traceBuffer.exportJson()

    fun writeTraceAtomically(outputFile: File): Boolean = traceBuffer.writeAtomically(outputFile)

    fun send(command: HostCommand, nowEpochSec: Long = 0L, afterDispatch: (() -> Unit)? = null) {
        enqueueOrRun {
            sendReturningError(command, nowEpochSec)
            afterDispatch?.invoke()
        }
    }

    suspend fun sendReturningErrorAsync(command: HostCommand, nowEpochSec: Long = 0L): String? {
        val executor = commandExecutor ?: return sendReturningError(command, nowEpochSec)
        val result = CompletableDeferred<String?>()
        try {
            executor.execute {
                try {
                    result.complete(sendReturningError(command, nowEpochSec))
                } catch (error: Throwable) {
                    result.completeExceptionally(error)
                }
            }
        } catch (_: RejectedExecutionException) {
            result.complete("工作区正在关闭。")
        }
        return result.await()
    }

    fun sendReturningError(command: HostCommand, nowEpochSec: Long = 0L): String? {
        val json = try {
            command.toJsonString()
        } catch (_: Exception) {
            val message = "无法发送这次操作，请重试。"
            synchronized(stateLock) {
                setNativeErrorLocked(message)
                recordTraceLocked(kind = "command", name = command.commandType)
            }
            onTraceUpdated?.invoke()
            return message
        }
        return dispatchEncodedJson(json, traceKind = "command", commandType = command.commandType, nowEpochSec = nowEpochSec)
    }

    fun send(event: HostAdapterEvent, nowEpochSec: Long = 0L, afterDispatch: (() -> Unit)? = null) {
        enqueueOrRun {
            sendEventSync(event, nowEpochSec)
            afterDispatch?.invoke()
        }
    }

    fun sendEventSync(event: HostAdapterEvent, nowEpochSec: Long = 0L) {
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

    fun startCapture(mode: CaptureMode, stayOnPage: Boolean = false) {
        enqueueOrRun {
            sendReturningError(HostCommand.StartCaptureMode(mode = mode, stayOnPage = stayOnPage))
            bridgeActions.flushBleOutbound()
        }
    }

    fun toggleModeSession(card: ModePickerCardSnapshot) {
        if (card.isSessionActive) {
            performCaptureAction(CaptureAction.END)
        } else {
            CaptureMode.fromRaw(card.mode)?.let { mode ->
                startCapture(mode, stayOnPage = true)
            }
        }
    }

    fun performCaptureAction(action: CaptureAction) {
        enqueueOrRun {
            if (action == CaptureAction.RESUME && (currentMicrophone() != null || captureStudio.value.studio.activeSource != "bean")) {
                bridgeActions.resumeMicrophone()
            } else {
                sendReturningError(HostCommand.CaptureActionCommand(action = action))
                bridgeActions.flushBleOutbound()
            }
        }
    }

    private fun enqueueOrRun(task: () -> Unit) {
        val executor = commandExecutor
        if (executor == null) {
            task()
        } else {
            try {
                executor.execute(task)
            } catch (_: RejectedExecutionException) {
            }
        }
    }

    fun refreshSnapshot(nowEpochSec: Long = 0L) {
        var traced = false
        var applied: ApplySnapshotResult? = null
        synchronized(stateLock) {
            if (handle == 0L) return
            try {
                val effectiveNow = resolveNowEpochSec(nowEpochSec)
                val raw = bridge.sessionSnapshotJson(handle, effectiveNow)
                if (raw == null) {
                    setNativeErrorLocked("无法读取工作区状态。")
                    return
                }
                applied = applySnapshotJsonLocked(raw, projectedNowSec = effectiveNow, resetGate = false)
            } finally {
                recordTraceLocked(kind = "snapshot", name = "snapshot")
                traced = true
            }
        }
        applied?.let { notifySnapshotPublished(it.changed, it.publishSequence) }
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
        var changedSnapshot: HostSnapshot? = null
        var publishedSeq = 0L
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
                    publishSequence += 1L
                    publishedSeq = publishSequence
                    lastProjectedNowSec = receipt.nowEpochSec
                    slices.updatePlayback(next.playback)
                    changedSnapshot = next
                }
            }
        }
        notifySnapshotPublished(changedSnapshot, publishedSeq)
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
        parseLengthPrefixedBleFrames(raw) ?: run {
            setNativeErrorLocked("无法读取设备发送队列。")
            emptyList()
        }
    }

    fun drainLocalAsrEffects(): ByteArray = synchronized(stateLock) {
        if (handle == 0L) return ByteArray(0)
        bridge.sessionDrainLocalAsr(handle) ?: ByteArray(0)
    }

    fun loadDebugSnapshotFixtureJson(json: String, resumeLiveOnCommand: Boolean = false): Boolean {
        if (!allowDebugFixture) return false
        val result = synchronized(stateLock) {
            try {
                applySnapshotJsonLocked(json, projectedNowSec = 0L, resetGate = true).also {
                    this.resumeLiveOnCommand = it.accepted && resumeLiveOnCommand
                }
            } finally {
                recordTraceLocked(kind = "fixture", name = "fixture")
            }
        }
        notifySnapshotPublished(result.changed, result.publishSequence)
        onTraceUpdated?.invoke()
        return result.accepted
    }

    internal fun applySnapshotJson(json: String, projectedNowSec: Long = 0L): Boolean {
        val result = synchronized(stateLock) {
            applySnapshotJsonLocked(json, projectedNowSec = projectedNowSec, resetGate = false)
        }
        notifySnapshotPublished(result.changed, result.publishSequence)
        return result.accepted
    }

    private fun dispatchEncodedJson(json: String, traceKind: String, commandType: String, nowEpochSec: Long): String? {
        val result = synchronized(stateLock) {
            if (handle == 0L) return "工作区未打开。"
            if (resumeLiveOnCommand && traceKind == "command") {
                requestGate.reset(0)
                resumeLiveOnCommand = false
            }
            val preservesNativeError = commandType == "sync_audio_inputs" ||
                commandType == "sync_app_metadata" ||
                commandType.startsWith("local_asr_")
            if (!preservesNativeError) setNativeErrorLocked(null)
            val effectiveNow = resolveNowEpochSec(nowEpochSec)
            val response = bridge.sessionDispatchJson(handle, json, effectiveNow)
            val applied = if (response == null) {
                snapshotFailureLocked("操作未能完成，请重试。工作区数据仍然保留。")
            } else {
                applySnapshotJsonLocked(response, projectedNowSec = effectiveNow, resetGate = false)
            }
            recordTraceLocked(kind = traceKind, name = commandType)
            applied
        }
        notifySnapshotPublished(result.changed, result.publishSequence)
        onTraceUpdated?.invoke()
        return result.error
    }

    private fun notifySnapshotPublished(snapshot: HostSnapshot?, sequence: Long) {
        if (snapshot == null) return
        onSnapshotPublished?.invoke(snapshot, sequence)
        onSnapshotChanged?.invoke(snapshot)
    }

    private data class ApplySnapshotResult(
        val accepted: Boolean,
        val changed: HostSnapshot? = null,
        val publishSequence: Long = 0L,
        val error: String? = null,
    )

    private fun snapshotFailureLocked(message: String): ApplySnapshotResult {
        setNativeErrorLocked(message)
        return ApplySnapshotResult(false, error = message)
    }

    private fun applySnapshotJsonLocked(json: String, projectedNowSec: Long, resetGate: Boolean): ApplySnapshotResult {
        val decoded = try {
            HostJson.json.decodeFromString(HostSnapshot.serializer(), json)
        } catch (_: Exception) {
            return snapshotFailureLocked("无法读取数据引擎的回应，请重新打开应用。")
        }
        if (decoded.version != EXPECTED_ABI_VERSION) {
            return snapshotFailureLocked("数据引擎返回了不兼容的版本。")
        }
        if (resetGate) {
            nativeError = null
            requestGate.reset(decoded.generation)
        } else if (!requestGate.acceptRustGeneration(decoded.generation)) {
            return ApplySnapshotResult(false, error = decoded.error)
        }
        if (projectedNowSec > 0L) lastProjectedNowSec = projectedNowSec
        if (decoded != currentSnapshot || resetGate) {
            currentSnapshot = decoded
            publishSequence += 1L
            slices.reconcile(decoded, nativeError)
            return ApplySnapshotResult(accepted = true, changed = decoded, publishSequence = publishSequence, error = decoded.error)
        }
        return ApplySnapshotResult(accepted = true, error = decoded.error)
    }

    private fun setNativeErrorLocked(message: String?) {
        if (nativeError == message) return
        nativeError = message
        slices.updateNavigation(currentSnapshot, nativeError)
    }

    private fun recordTraceLocked(kind: String, name: String) {
        if (verificationTrace && kind == "snapshot" && nativeError == null && currentSnapshot.error == null) return
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

    companion object {
        const val EXPECTED_ABI_VERSION = 2
    }
}
