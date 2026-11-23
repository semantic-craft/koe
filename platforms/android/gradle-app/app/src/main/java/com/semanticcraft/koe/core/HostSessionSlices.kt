package com.semanticcraft.koe.core

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

internal class HostSessionSliceFlows {
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
    private val _keepAwake = MutableStateFlow(false)
    val keepAwake: StateFlow<Boolean> = _keepAwake.asStateFlow()
    private val _activeCapture = MutableStateFlow<ActiveCaptureSnapshot?>(null)
    val activeCapture: StateFlow<ActiveCaptureSnapshot?> = _activeCapture.asStateFlow()
    private val _liveCaption = MutableStateFlow<LiveCaptionSnapshot?>(null)
    val liveCaption: StateFlow<LiveCaptionSnapshot?> = _liveCaption.asStateFlow()

    fun updateNavigation(snap: HostSnapshot, nativeError: String?) {
        _navigation.value = NavigationChromeSlice.from(snap, nativeError)
    }

    fun updatePlayback(playback: PlaybackSnapshot) {
        _playback.value = playback
    }

    fun reconcile(snap: HostSnapshot, nativeError: String?) {
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
        _keepAwake.value = snap.lifecycle?.keepAwake == true
        _activeCapture.value = snap.activeCapture
        _liveCaption.value = snap.liveCaption
    }
}

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

internal fun parseLengthPrefixedBleFrames(raw: ByteArray): List<ByteArray>? {
    if (raw.isEmpty()) return emptyList()
    val frames = mutableListOf<ByteArray>()
    var offset = 0
    while (offset + 4 <= raw.size) {
        val length = (raw[offset].toInt() and 0xFF) or
            ((raw[offset + 1].toInt() and 0xFF) shl 8) or
            ((raw[offset + 2].toInt() and 0xFF) shl 16) or
            ((raw[offset + 3].toInt() and 0xFF) shl 24)
        offset += 4
        if (length < 0 || offset + length > raw.size) return null
        frames.add(raw.copyOfRange(offset, offset + length))
        offset += length
    }
    return if (offset == raw.size) frames else null
}

enum class PcmIngestStatus(val code: Int) {
    ACCEPTED(0),
    STALE_SESSION(1),
    REJECTED(2);

    companion object {
        fun fromCode(code: Int): PcmIngestStatus =
            entries.firstOrNull { it.code == code } ?: REJECTED
    }
}

data class PcmIngestReceipt(
    val generation: Long,
    val nextSequence: Long,
    val status: PcmIngestStatus,
)

data class PlaybackProgressReceipt(
    val generation: Long,
    val prevGeneration: Long,
    val positionMs: Long,
    val nowEpochSec: Long,
    val isPlaying: Boolean,
    val applied: Boolean,
    val needsFullSnapshot: Boolean,
)

data class NavigationChromeSlice(
    val section: String,
    val canGoBack: Boolean,
    val selectedRecordId: String?,
    val detailId: String?,
    val detailTitle: String?,
    val detailDurationMs: Long,
    val hasPlayableDetailAsset: Boolean,
    val hasConnectGuide: Boolean,
    val savingRecordId: String?,
    val activeCaptureMode: CaptureMode?,
    val hasLiveCaption: Boolean,
    val trashCount: Int,
    val undoTrash: UndoTrashSnapshot?,
    val effectiveError: String?,
    val notice: String?,
) {
    companion object {
        val empty = from(HostSnapshot.empty, nativeError = null)

        fun from(snapshot: HostSnapshot, nativeError: String?): NavigationChromeSlice =
            NavigationChromeSlice(
                section = snapshot.section,
                canGoBack = snapshot.canGoBack,
                selectedRecordId = snapshot.selectedRecordId,
                detailId = snapshot.detail?.id,
                detailTitle = snapshot.detail?.title,
                detailDurationMs = snapshot.detail?.durationMs ?: 0L,
                hasPlayableDetailAsset = snapshot.playback.asset != null &&
                    snapshot.playback.recordId == snapshot.detail?.id,
                hasConnectGuide = snapshot.device.guide != null,
                activeCaptureMode = snapshot.activeCapture?.mode,
                hasLiveCaption = snapshot.liveCaption != null,
                savingRecordId = snapshot.microphone?.takeIf {
                    it.phase == "saving" || snapshot.activeCapture?.phase == "saving"
                }?.recordId,
                trashCount = snapshot.trashRecords.size,
                undoTrash = snapshot.undoTrash,
                effectiveError = nativeError ?: snapshot.error,
                notice = snapshot.notice,
            )
    }
}

data class TodaySlice(
    val picker: ModePickerSnapshot?,
    val beanControlState: String,
    val recordCount: Int,
    val proposedActionCount: Int,
    val deviceConnected: Boolean,
    val deviceState: String,
    val captureSelectedBadge: String,
    val captureSelectedLabel: String,
) {
    companion object {
        val empty = from(HostSnapshot.empty)

        fun from(snapshot: HostSnapshot): TodaySlice {
            val picker = snapshot.workspaces?.picker
            val resolvedBeanControl = picker?.resolvedBeanControlState ?: "this_device"
            val proposedActionCount = snapshot.reviewCounts?.proposedActionCount
                ?: (snapshot.tasks.count { it.state == "proposed" } + snapshot.memories.count { it.state == "proposed" })
            return TodaySlice(
                picker = picker,
                beanControlState = resolvedBeanControl,
                recordCount = snapshot.records.size,
                proposedActionCount = proposedActionCount,
                deviceConnected = snapshot.device.connected,
                deviceState = snapshot.device.state,
                captureSelectedBadge = snapshot.capture.selectedBadge,
                captureSelectedLabel = snapshot.capture.selectedLabel,
            )
        }
    }
}

data class RecordDetailSlice(
    val detail: RecordDetailSnapshot?,
    val focusSegmentId: String?,
    val recordTasks: List<TaskSnapshot>,
    val recordMemories: List<MemorySnapshot>,
) {
    companion object {
        val empty = from(HostSnapshot.empty)

        fun from(snapshot: HostSnapshot): RecordDetailSlice {
            val detailId = snapshot.detail?.id
            val detailTasks = if (detailId != null) {
                snapshot.tasks.filter { task ->
                    task.state != "dismissed" && task.sources.any { it.recordId == detailId }
                }
            } else {
                emptyList()
            }
            val detailMemories = if (detailId != null) {
                snapshot.memories.filter { memory ->
                    memory.state != "dismissed" && memory.sources.any { it.recordId == detailId }
                }
            } else {
                emptyList()
            }
            return RecordDetailSlice(
                detail = snapshot.detail,
                focusSegmentId = snapshot.focusSegmentId,
                recordTasks = detailTasks,
                recordMemories = detailMemories,
            )
        }
    }
}

data class CaptureStudioSlice(
    val studio: CaptureStudioSnapshot,
    val isRecordingLocked: Boolean,
) {
    companion object {
        val empty = from(HostSnapshot.empty)

        fun from(snapshot: HostSnapshot): CaptureStudioSlice =
            CaptureStudioSlice(
                studio = snapshot.capture,
                isRecordingLocked = snapshot.activeCapture != null,
            )
    }
}

data class SettingsSlice(
    val speech: SpeechSnapshot,
    val provider: ProviderSnapshot,
    val appUpdate: AppUpdateSnapshot,
) {
    companion object {
        val empty = from(HostSnapshot.empty)

        fun from(snapshot: HostSnapshot): SettingsSlice =
            SettingsSlice(
                speech = snapshot.speech,
                provider = snapshot.provider,
                appUpdate = snapshot.appUpdate,
            )
    }
}
