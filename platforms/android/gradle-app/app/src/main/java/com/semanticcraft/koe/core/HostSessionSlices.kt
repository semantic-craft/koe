package com.semanticcraft.koe.core

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
            val proposedTasks = snapshot.tasks.count { it.state == "proposed" }
            val proposedMemories = snapshot.memories.count { it.state == "proposed" }
            return TodaySlice(
                picker = picker,
                beanControlState = resolvedBeanControl,
                recordCount = snapshot.records.size,
                proposedActionCount = proposedTasks + proposedMemories,
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
