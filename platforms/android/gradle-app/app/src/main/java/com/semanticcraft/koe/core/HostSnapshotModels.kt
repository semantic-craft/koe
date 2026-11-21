package com.semanticcraft.koe.core

import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

object HostJson {
    val json: Json = Json {
        ignoreUnknownKeys = true
        encodeDefaults = true
        explicitNulls = false
        classDiscriminator = "type"
    }
}

object TimeLabel {
    private val dateFormatter: DateTimeFormatter =
        DateTimeFormatter.ofPattern("M月d日 HH:mm", Locale.CHINA)
    private val hourMinuteFormatter: DateTimeFormatter =
        DateTimeFormatter.ofPattern("HH:mm", Locale.US)

    fun duration(ms: Long): String {
        val safeMs = ms.coerceAtLeast(0L)
        val minutes = safeMs / 60_000L
        val seconds = (safeMs / 1_000L) % 60L
        return String.format(Locale.US, "%02d:%02d", minutes, seconds)
    }

    fun date(seconds: Long, zoneId: ZoneId = ZoneId.systemDefault()): String =
        Instant.ofEpochSecond(seconds).atZone(zoneId).format(dateFormatter)

    fun hourMinute(seconds: Long, zoneId: ZoneId = ZoneId.systemDefault()): String =
        Instant.ofEpochSecond(seconds).atZone(zoneId).format(hourMinuteFormatter)
}

@Serializable
data class HostPlatformSnapshot(
    val id: String = "android",
    val hostDisplayName: String = "Android",
    val supportsSystemAudio: Boolean = false,
    val supportsSelfUpdate: Boolean = false,
    val nativeSpeechLabel: String = "Android 本机",
    val supportsNativeSpeech: Boolean = id != "android",
) {
    companion object {
        val androidDefault = HostPlatformSnapshot()
        val macosDefault = HostPlatformSnapshot(
            id = "macos",
            hostDisplayName = "Mac",
            supportsSystemAudio = true,
            supportsSelfUpdate = true,
            nativeSpeechLabel = "Apple 本机",
        )
    }
}

enum class HostSection(val rawValue: String, val title: String) {
    TODAY("today", "模式选择"),
    NOTES("notes", "随心闪记"),
    ALL_DAY("all_day", "全天听记"),
    LIVE_MINUTES("live_minutes", "实时纪要"),
    ASK("ask", "问 AI"),
    RECORDS("records", "所有记录"),
    TASKS("tasks", "行动"),
    MEMORY("memory", "记忆"),
    SETTINGS("settings", "模型设置"),
    CAPTURE("capture", "录音管理"),
    TRASH("trash", "回收站"),
    DETAIL("detail", "记录");

    companion object {
        fun fromRaw(raw: String): HostSection? = entries.firstOrNull { it.rawValue == raw }

        fun titleFor(rawSection: String, detailTitle: String? = null): String {
            val section = fromRaw(rawSection) ?: TODAY
            return if (section == DETAIL) detailTitle ?: section.title else section.title
        }
    }
}

@Serializable
enum class CaptureMode(val rawValue: String, val title: String, val purpose: String) {
    @SerialName("quick_note")
    QUICK_NOTE("quick_note", "随心闪记", "快速留下一段想法"),

    @SerialName("all_day")
    ALL_DAY("all_day", "全天听记", "持续记录，随时回看"),

    @SerialName("meeting")
    MEETING("meeting", "实时纪要", "记录讨论并整理纪要");

    val section: HostSection
        get() = when (this) {
            QUICK_NOTE -> HostSection.NOTES
            ALL_DAY -> HostSection.ALL_DAY
            MEETING -> HostSection.LIVE_MINUTES
        }

    companion object {
        fun fromRaw(raw: String): CaptureMode? = entries.firstOrNull { it.rawValue == raw }
    }
}

@Serializable
enum class CaptureAction {
    @SerialName("pause")
    PAUSE,

    @SerialName("resume")
    RESUME,

    @SerialName("end")
    END,

    @SerialName("retry_save")
    RETRY_SAVE,

    @SerialName("retry_stop")
    RETRY_STOP,

    @SerialName("cancel")
    CANCEL,
}

@Serializable
data class SourceSnapshot(
    val recordId: String,
    val segmentId: String,
    val title: String,
    val quote: String,
    val startMs: Long = 0L,
) {
    val id: String get() = "$recordId:$segmentId"
}

@Serializable
data class SpeakerSummarySnapshot(
    val name: String,
    val segmentCount: Int = 0,
    val firstSegmentId: String = "",
)

@Serializable
data class SegmentSnapshot(
    val id: String,
    val text: String,
    val originalText: String? = null,
    val isEdited: Boolean = false,
    val startMs: Long = 0L,
    val endMs: Long = 0L,
    val timed: Boolean? = null,
    val speaker: String? = null,
)

@Serializable
data class RecordSnapshot(
    val id: String,
    val title: String,
    val createdAtEpochSec: Long = 0L,
    val durationMs: Long = 0L,
    val source: String = "",
    val status: String = "",
    val segmentCount: Int = 0,
    val preview: String = "",
    val archived: Boolean = false,
    val runId: String? = null,
    val ordinal: Long? = null,
    val mode: String? = null,
    val project: String? = null,
) {
    val isTranscribing: Boolean
        get() = status == "转写中" || status == "等待转写"

    val effectiveMode: String
        get() = mode?.takeIf { it.isNotEmpty() } ?: if (runId != null) "all_day" else "quick_note"

    val modeLabel: String
        get() = (CaptureMode.fromRaw(effectiveMode) ?: CaptureMode.QUICK_NOTE).title

    val isQuickNoteInbox: Boolean
        get() = effectiveMode == "quick_note" && project.isNullOrBlank() && !archived
}

@Serializable
data class SummarySnapshot(
    val title: String,
    val text: String,
    val sources: List<SourceSnapshot> = emptyList(),
) {
    val id: String get() = "$title\u001F$text"
}

@Serializable
data class RecordDetailSnapshot(
    val id: String,
    val title: String,
    val createdAtEpochSec: Long = 0L,
    val durationMs: Long = 0L,
    val source: String = "",
    val status: String = "",
    val archived: Boolean = false,
    val mode: String? = null,
    val project: String? = null,
    val segments: List<SegmentSnapshot> = emptyList(),
    val summary: List<SummarySnapshot> = emptyList(),
    val highlights: List<SourceSnapshot> = emptyList(),
    val audioPath: String? = null,
    val canRetranscribe: Boolean = false,
    val isProcessing: Boolean = false,
    val minutesStale: Boolean = false,
    val canEditTranscript: Boolean = false,
    val speakers: List<SpeakerSummarySnapshot> = emptyList(),
) {
    val modeLabel: String
        get() = (CaptureMode.fromRaw(mode ?: "quick_note") ?: CaptureMode.QUICK_NOTE).title
}

@Serializable
data class TrashRecordSnapshot(
    val id: String,
    val title: String,
    val createdAtEpochSec: Long = 0L,
    val durationMs: Long = 0L,
    val source: String = "",
    val segmentCount: Int = 0,
    val preview: String = "",
    val trashedAtMs: Long = 0L,
    val expiresAtMs: Long = 0L,
    val remainingDays: Int = 30,
)

@Serializable
data class UndoTrashSnapshot(
    val recordId: String,
    val title: String,
    val recordIds: List<String>? = null,
) {
    val effectiveRecordIds: List<String>
        get() = recordIds?.takeIf { it.isNotEmpty() } ?: listOf(recordId)

    val count: Int get() = effectiveRecordIds.size
}

@Serializable
data class TaskSnapshot(
    val id: String,
    val text: String,
    val state: String,
    val completed: Boolean = false,
    val due: String? = null,
    val sources: List<SourceSnapshot> = emptyList(),
)

@Serializable
data class MemorySnapshot(
    val id: String,
    val text: String,
    val state: String,
    val sources: List<SourceSnapshot> = emptyList(),
)

@Serializable
data class AskMessageSnapshot(
    val id: String,
    val role: String,
    val text: String,
    val mode: String = "retrieval",
    val sources: List<SourceSnapshot> = emptyList(),
)

@Serializable
data class AskSnapshot(
    val scope: String = "all",
    val recordId: String? = null,
    val phase: String = "idle",
    val messages: List<AskMessageSnapshot> = emptyList(),
)

@Serializable
data class HostSnapshot(
    val version: Int = 2,
    val generation: Long = 0L,
    val section: String = "today",
    val canGoBack: Boolean = false,
    val selectedRecordId: String? = null,
    val focusSegmentId: String? = null,
    val platform: HostPlatformSnapshot = HostPlatformSnapshot.androidDefault,
    val records: List<RecordSnapshot> = emptyList(),
    val trashRecords: List<TrashRecordSnapshot> = emptyList(),
    val undoTrash: UndoTrashSnapshot? = null,
    val detail: RecordDetailSnapshot? = null,
    val tasks: List<TaskSnapshot> = emptyList(),
    val memories: List<MemorySnapshot> = emptyList(),
    val ask: AskSnapshot = AskSnapshot(),
    val device: DeviceSnapshot = DeviceSnapshot.empty,
    val provider: ProviderSnapshot = ProviderSnapshot.empty,
    val speech: SpeechSnapshot = SpeechSnapshot.empty,
    val appUpdate: AppUpdateSnapshot = AppUpdateSnapshot.empty,
    val capture: CaptureStudioSnapshot = CaptureStudioSnapshot.empty,
    val microphone: MicrophoneSnapshot? = null,
    val lifecycle: LifecycleSnapshot? = null,
    val activeCapture: ActiveCaptureSnapshot? = null,
    val liveCaption: LiveCaptionSnapshot? = null,
    val workspaces: ModeWorkspacesSnapshot? = null,
    val playback: PlaybackSnapshot = PlaybackSnapshot.empty,
    val error: String? = null,
    val notice: String? = null,
) {
    fun updatingPlayback(generation: Long, positionMs: Long, isPlaying: Boolean): HostSnapshot =
        copy(
            generation = generation,
            playback = playback.updatingProgress(positionMs = positionMs, isPlaying = isPlaying),
        )

    companion object {
        val empty = HostSnapshot()
    }
}
