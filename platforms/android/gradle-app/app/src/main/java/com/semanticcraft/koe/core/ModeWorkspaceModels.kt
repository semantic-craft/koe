package com.semanticcraft.koe.core

import java.time.ZoneId
import kotlinx.serialization.Serializable

sealed interface QuickNoteFilterSelection {
    data object All : QuickNoteFilterSelection
    data object Inbox : QuickNoteFilterSelection
    data class Project(val name: String) : QuickNoteFilterSelection
}

enum class RecordFilterCategory(val title: String) {
    ALL("全部"),
    QUICK_NOTE(CaptureMode.QUICK_NOTE.title),
    INBOX("收件箱"),
    ALL_DAY(CaptureMode.ALL_DAY.title),
    MEETING(CaptureMode.MEETING.title),
    ARCHIVED("已归档"),
}

fun RecordSnapshot.matches(filter: RecordFilterCategory, query: String): Boolean {
    val passesCategory = when (filter) {
        RecordFilterCategory.ALL -> true
        RecordFilterCategory.QUICK_NOTE -> effectiveMode == "quick_note"
        RecordFilterCategory.INBOX -> isQuickNoteInbox
        RecordFilterCategory.ALL_DAY -> effectiveMode == "all_day"
        RecordFilterCategory.MEETING -> effectiveMode == "meeting"
        RecordFilterCategory.ARCHIVED -> archived
    }
    if (!passesCategory) return false
    val trimmed = query.trim()
    if (trimmed.isEmpty()) return true
    return title.contains(trimmed, ignoreCase = true) ||
        preview.contains(trimmed, ignoreCase = true) ||
        source.contains(trimmed, ignoreCase = true) ||
        (project?.contains(trimmed, ignoreCase = true) == true)
}

@Serializable
data class ModeWorkspacesSnapshot(
    val picker: ModePickerSnapshot = ModePickerSnapshot.empty,
    val quickNote: QuickNoteWorkspaceSnapshot = QuickNoteWorkspaceSnapshot.empty,
    val allDay: AllDayWorkspaceSnapshot = AllDayWorkspaceSnapshot.empty,
    val liveMinutes: LiveMinutesWorkspaceSnapshot = LiveMinutesWorkspaceSnapshot.empty,
) {
    companion object {
        val empty = ModeWorkspacesSnapshot()
    }
}

@Serializable
data class ModePickerCardSnapshot(
    val id: String,
    val mode: String,
    val title: String,
    val subtitle: String,
    val isSessionActive: Boolean = false,
    val canToggleSession: Boolean = true,
    val statusBadge: String = "就绪",
    val metricText: String = "",
)

@Serializable
data class ModePickerSnapshot(
    val sourceLabel: String = "Android 麦克风",
    val sourceBadge: String = "本机",
    val beanBadge: String = "录音豆 未连接",
    val beanBadgeTone: String = "muted",
    val beanControlOwner: String = "android",
    val beanControlState: String? = null,
    val guidanceText: String = "当前使用本机麦克风，也可将录音豆放入充电仓按键连接后再选模式。",
    val canSwitchToBean: Boolean = false,
    val canConnectBean: Boolean = true,
    val canReleaseToPhone: Boolean = true,
    val cards: List<ModePickerCardSnapshot> = defaultCards,
) {
    val resolvedBeanControlState: String
        get() = beanControlState ?: if (beanControlOwner == "phone") "released" else "this_device"

    companion object {
        val defaultCards: List<ModePickerCardSnapshot> = listOf(
            ModePickerCardSnapshot(
                id = HostSection.NOTES.rawValue,
                mode = CaptureMode.QUICK_NOTE.rawValue,
                title = CaptureMode.QUICK_NOTE.title,
                subtitle = "想到就记，原文优先，收件箱与项目自由归类",
                statusBadge = "就绪",
                metricText = "共 0 条闪记，收件箱 0 条",
            ),
            ModePickerCardSnapshot(
                id = HostSection.ALL_DAY.rawValue,
                mode = CaptureMode.ALL_DAY.rawValue,
                title = CaptureMode.ALL_DAY.title,
                subtitle = "按事件回看全天对话，自动标记暂停与未录音空档",
                statusBadge = "待开启",
                metricText = "今日 0 个事件，已录 0 分钟",
            ),
            ModePickerCardSnapshot(
                id = HostSection.LIVE_MINUTES.rawValue,
                mode = CaptureMode.MEETING.rawValue,
                title = CaptureMode.MEETING.title,
                subtitle = "边听边整理议题与待办，会后核对完整纪要",
                statusBadge = "就绪",
                metricText = "往期会议 0 场",
            ),
        )

        val empty = ModePickerSnapshot()
    }
}

@Serializable
data class QuickNoteProjectCountSnapshot(
    val name: String,
    val count: Int = 0,
)

@Serializable
data class QuickNoteTopicSnapshot(
    val title: String,
    val summary: String,
    val sources: List<SourceSnapshot> = emptyList(),
)

@Serializable
data class WorkspaceSourcedItemSnapshot(
    val id: String,
    val kind: String,
    val text: String,
    val state: String,
    val completed: Boolean = false,
    val due: String? = null,
    val sources: List<SourceSnapshot> = emptyList(),
)

@Serializable
data class QuickNoteCardSnapshot(
    val id: String,
    val title: String,
    val createdAtEpochSec: Long = 0L,
    val durationMs: Long = 0L,
    val source: String = "",
    val status: String = "",
    val archived: Boolean = false,
    val project: String? = null,
    val isInbox: Boolean = true,
    val minutesStale: Boolean = false,
    val canSummarize: Boolean = false,
    val segments: List<SegmentSnapshot> = emptyList(),
    val gist: String? = null,
    val topics: List<QuickNoteTopicSnapshot> = emptyList(),
    val nextSteps: List<WorkspaceSourcedItemSnapshot> = emptyList(),
)

@Serializable
data class QuickNoteWorkspaceSnapshot(
    val isActive: Boolean = false,
    val canStart: Boolean = true,
    val sourceLabel: String = "Android 麦克风",
    val inboxCount: Int = 0,
    val totalCount: Int = 0,
    val projects: List<QuickNoteProjectCountSnapshot> = emptyList(),
    val selectedRecordId: String? = null,
    val mcpReadNote: String = "外部 Agent 可通过只读 MCP 检索已保存闪记原文与已采纳行动，不会自动改写记录。",
    val cards: List<QuickNoteCardSnapshot> = emptyList(),
) {
    fun filteredCards(filter: QuickNoteFilterSelection): List<QuickNoteCardSnapshot> =
        when (filter) {
            QuickNoteFilterSelection.All -> cards
            QuickNoteFilterSelection.Inbox -> cards.filter { it.isInbox }
            is QuickNoteFilterSelection.Project -> cards.filter { it.project == filter.name }
        }

    fun resolvedSelectedCard(filter: QuickNoteFilterSelection): QuickNoteCardSnapshot? {
        val visible = filteredCards(filter)
        return selectedRecordId?.let { id -> visible.firstOrNull { it.id == id } }
            ?: visible.firstOrNull()
    }

    companion object {
        val empty = QuickNoteWorkspaceSnapshot()
    }
}

@Serializable
data class AllDaySpanSnapshot(
    val kind: String,
    val id: String,
    val title: String? = null,
    val recordId: String? = null,
    val startEpochSec: Long = 0L,
    val endEpochSec: Long = 0L,
    val durationMs: Long = 0L,
    val recordIds: List<String> = emptyList(),
    val primaryRecordId: String? = null,
    val firstSegment: SourceSnapshot? = null,
    val preview: String = "",
    val summaryPoints: List<String> = emptyList(),
    val speakers: List<String> = emptyList(),
    val segmentCount: Int = 0,
) {
    fun timeRangeLabel(zoneId: ZoneId = ZoneId.systemDefault()): String {
        val start = TimeLabel.hourMinute(startEpochSec, zoneId)
        val end = TimeLabel.hourMinute(endEpochSec, zoneId)
        return "$start - $end"
    }

    val sliceBadgeText: String?
        get() = if (recordIds.size > 1) "跨 ${recordIds.size} 个切片" else null

    fun statusSummaryLabel(zoneId: ZoneId = ZoneId.systemDefault()): String {
        val duration = TimeLabel.duration(durationMs)
        val range = timeRangeLabel(zoneId)
        return when (kind) {
            "pause" -> "已暂停录音  $range  时长 $duration"
            "unrecorded_gap" -> "未录音空档  $range  时长 $duration"
            else -> "$range  时长 $duration"
        }
    }
}

@Serializable
data class AllDayDecisionSnapshot(
    val id: String,
    val recordId: String,
    val text: String,
    val sources: List<SourceSnapshot> = emptyList(),
)

@Serializable
data class AllDayDailyReviewSnapshot(
    val overview: String,
    val highlights: List<String> = emptyList(),
    val sources: List<SourceSnapshot> = emptyList(),
)

@Serializable
data class AllDayWorkspaceSnapshot(
    val isActive: Boolean = false,
    val canStart: Boolean = true,
    val isPaused: Boolean = false,
    val canPause: Boolean = false,
    val canResume: Boolean = false,
    val sourceLabel: String = "Android 麦克风",
    val selectedDate: String = "1970-01-01",
    val availableDates: List<String> = emptyList(),
    val totalRecordedMs: Long = 0L,
    val eventCount: Int = 0,
    val pauseCount: Int = 0,
    val gapCount: Int = 0,
    val spans: List<AllDaySpanSnapshot> = emptyList(),
    val reviewTasks: List<WorkspaceSourcedItemSnapshot> = emptyList(),
    val reviewMemories: List<WorkspaceSourcedItemSnapshot> = emptyList(),
    val reviewDecisions: List<AllDayDecisionSnapshot> = emptyList(),
    val dailyReview: AllDayDailyReviewSnapshot? = null,
) {
    companion object {
        val empty = AllDayWorkspaceSnapshot()
    }
}

@Serializable
data class MeetingCoverageSnapshot(
    val audioDurationMs: Long = 0L,
    val transcribedDurationMs: Long = 0L,
    val transcriptPercent: Int = 0,
    val totalSegments: Int = 0,
    val groundedSegments: Int = 0,
    val minutesPercent: Int = 0,
    val consolidationStage: String = "",
    val consolidationLabel: String = "",
)

@Serializable
data class PastMeetingSnapshot(
    val id: String,
    val title: String,
    val createdAtEpochSec: Long = 0L,
    val durationMs: Long = 0L,
    val source: String = "",
    val status: String = "",
    val segmentCount: Int = 0,
    val decisionCount: Int = 0,
)

@Serializable
data class LiveMinutesWorkspaceSnapshot(
    val isActive: Boolean = false,
    val canStart: Boolean = true,
    val phase: String = "idle",
    val configured: Boolean = false,
    val sourceLabel: String = "Android 麦克风",
    val activeRecordId: String? = null,
    val selectedRecordId: String? = null,
    val selectedTitle: String? = null,
    val minutesStale: Boolean = false,
    val canSummarize: Boolean = false,
    val error: String? = null,
    val coverage: MeetingCoverageSnapshot? = null,
    val segments: List<SegmentSnapshot> = emptyList(),
    val drafts: List<String> = emptyList(),
    val liveSections: List<SummarySnapshot> = emptyList(),
    val finalSections: List<SummarySnapshot> = emptyList(),
    val actionItems: List<WorkspaceSourcedItemSnapshot> = emptyList(),
    val pastMeetings: List<PastMeetingSnapshot> = emptyList(),
) {
    fun withoutCoverage(): LiveMinutesWorkspaceSnapshot =
        if (coverage == null) this else copy(coverage = null)

    val phaseBadgeLabel: String
        get() = when (phase) {
            "starting" -> "正在启动"
            "recording" -> "会议记录中"
            "paused" -> "已暂停"
            "finishing" -> "正在收尾"
            "ended" -> "已结束"
            else -> "待开始"
        }

    companion object {
        val empty = LiveMinutesWorkspaceSnapshot()
    }
}
