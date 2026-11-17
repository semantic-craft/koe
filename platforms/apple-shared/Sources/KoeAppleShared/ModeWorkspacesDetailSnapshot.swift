import Foundation

public struct AllDaySpanSnapshot: Codable, Equatable, Identifiable, Sendable {
    public let kind: String
    public let id: String
    public let title: String?
    public let recordId: String?
    public let startEpochSec: UInt64
    public let endEpochSec: UInt64
    public let durationMs: UInt64
    public let recordIds: [String]
    public let primaryRecordId: String?
    public let firstSegment: SourceSnapshot?
    public let preview: String
    public let summaryPoints: [String]
    public let speakers: [String]
    public let segmentCount: Int

    private enum CodingKeys: String, CodingKey {
        case kind, id, title, recordId, startEpochSec, endEpochSec, durationMs
        case recordIds, primaryRecordId, firstSegment, preview, summaryPoints, speakers, segmentCount
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(String.self, forKey: .kind)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        recordId = try c.decodeIfPresent(String.self, forKey: .recordId)
        startEpochSec = try c.decode(UInt64.self, forKey: .startEpochSec)
        endEpochSec = try c.decode(UInt64.self, forKey: .endEpochSec)
        durationMs = try c.decode(UInt64.self, forKey: .durationMs)
        recordIds = try c.decodeIfPresent([String].self, forKey: .recordIds) ?? []
        primaryRecordId = try c.decodeIfPresent(String.self, forKey: .primaryRecordId)
        firstSegment = try c.decodeIfPresent(SourceSnapshot.self, forKey: .firstSegment)
        preview = try c.decodeIfPresent(String.self, forKey: .preview) ?? ""
        summaryPoints = try c.decodeIfPresent([String].self, forKey: .summaryPoints) ?? []
        speakers = try c.decodeIfPresent([String].self, forKey: .speakers) ?? []
        segmentCount = try c.decodeIfPresent(Int.self, forKey: .segmentCount) ?? 0
    }

    public var timeRangeLabel: String {
        let start = Date(timeIntervalSince1970: Double(startEpochSec))
            .formatted(.dateTime.hour().minute())
        let end = Date(timeIntervalSince1970: Double(endEpochSec))
            .formatted(.dateTime.hour().minute())
        return "\(start) - \(end)"
    }

    public var sliceBadgeText: String? {
        recordIds.count > 1 ? "跨 \(recordIds.count) 个切片" : nil
    }

    public var statusSummaryLabel: String {
        let duration = TimeLabel.duration(durationMs)
        switch kind {
        case "pause":
            return "已暂停录音  \(timeRangeLabel)  时长 \(duration)"
        case "unrecorded_gap":
            return "未录音空档  \(timeRangeLabel)  时长 \(duration)"
        default:
            return "\(timeRangeLabel)  时长 \(duration)"
        }
    }
}

public struct AllDayDecisionSnapshot: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let recordId: String
    public let text: String
    public let sources: [SourceSnapshot]
}

public struct AllDayDailyReviewSnapshot: Codable, Equatable, Sendable {
    public let overview: String
    public let highlights: [String]
    public let sources: [SourceSnapshot]
}

public struct AllDayWorkspaceSnapshot: Codable, Equatable, Sendable {
    public let isActive: Bool
    public let canStart: Bool
    public let isPaused: Bool
    public let canPause: Bool
    public let canResume: Bool
    public let sourceLabel: String
    public let selectedDate: String
    public let availableDates: [String]
    public let totalRecordedMs: UInt64
    public let eventCount: Int
    public let pauseCount: Int
    public let gapCount: Int
    public let spans: [AllDaySpanSnapshot]
    public let reviewTasks: [WorkspaceSourcedItemSnapshot]
    public let reviewMemories: [WorkspaceSourcedItemSnapshot]
    public let reviewDecisions: [AllDayDecisionSnapshot]
    public let dailyReview: AllDayDailyReviewSnapshot?

    private enum CodingKeys: String, CodingKey {
        case isActive, canStart, isPaused, canPause, canResume, sourceLabel
        case selectedDate, availableDates, totalRecordedMs, eventCount, pauseCount, gapCount
        case spans, reviewTasks, reviewMemories, reviewDecisions, dailyReview
    }

    public init(
        isActive: Bool,
        canStart: Bool = true,
        isPaused: Bool,
        canPause: Bool,
        canResume: Bool,
        sourceLabel: String,
        selectedDate: String,
        availableDates: [String],
        totalRecordedMs: UInt64,
        eventCount: Int,
        pauseCount: Int,
        gapCount: Int,
        spans: [AllDaySpanSnapshot],
        reviewTasks: [WorkspaceSourcedItemSnapshot],
        reviewMemories: [WorkspaceSourcedItemSnapshot],
        reviewDecisions: [AllDayDecisionSnapshot],
        dailyReview: AllDayDailyReviewSnapshot?
    ) {
        self.isActive = isActive
        self.canStart = canStart
        self.isPaused = isPaused
        self.canPause = canPause
        self.canResume = canResume
        self.sourceLabel = sourceLabel
        self.selectedDate = selectedDate
        self.availableDates = availableDates
        self.totalRecordedMs = totalRecordedMs
        self.eventCount = eventCount
        self.pauseCount = pauseCount
        self.gapCount = gapCount
        self.spans = spans
        self.reviewTasks = reviewTasks
        self.reviewMemories = reviewMemories
        self.reviewDecisions = reviewDecisions
        self.dailyReview = dailyReview
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        isActive = try c.decode(Bool.self, forKey: .isActive)
        canStart = try c.decodeIfPresent(Bool.self, forKey: .canStart) ?? false
        isPaused = try c.decode(Bool.self, forKey: .isPaused)
        canPause = try c.decode(Bool.self, forKey: .canPause)
        canResume = try c.decode(Bool.self, forKey: .canResume)
        sourceLabel = try c.decode(String.self, forKey: .sourceLabel)
        selectedDate = try c.decode(String.self, forKey: .selectedDate)
        availableDates = try c.decode([String].self, forKey: .availableDates)
        totalRecordedMs = try c.decode(UInt64.self, forKey: .totalRecordedMs)
        eventCount = try c.decode(Int.self, forKey: .eventCount)
        pauseCount = try c.decode(Int.self, forKey: .pauseCount)
        gapCount = try c.decode(Int.self, forKey: .gapCount)
        spans = try c.decode([AllDaySpanSnapshot].self, forKey: .spans)
        reviewTasks = try c.decode([WorkspaceSourcedItemSnapshot].self, forKey: .reviewTasks)
        reviewMemories = try c.decode([WorkspaceSourcedItemSnapshot].self, forKey: .reviewMemories)
        reviewDecisions = try c.decode([AllDayDecisionSnapshot].self, forKey: .reviewDecisions)
        dailyReview = try c.decodeIfPresent(AllDayDailyReviewSnapshot.self, forKey: .dailyReview)
    }

    public static let empty = AllDayWorkspaceSnapshot(
        isActive: false,
        canStart: true,
        isPaused: false,
        canPause: false,
        canResume: false,
        sourceLabel: "系统默认麦克风",
        selectedDate: "1970-01-01",
        availableDates: [],
        totalRecordedMs: 0,
        eventCount: 0,
        pauseCount: 0,
        gapCount: 0,
        spans: [],
        reviewTasks: [],
        reviewMemories: [],
        reviewDecisions: [],
        dailyReview: nil
    )
}

public struct MeetingCoverageSnapshot: Codable, Equatable, Sendable {
    public let audioDurationMs: UInt64
    public let transcribedDurationMs: UInt64
    public let transcriptPercent: Int
    public let totalSegments: Int
    public let groundedSegments: Int
    public let minutesPercent: Int
    public let consolidationStage: String
    public let consolidationLabel: String
}

public struct PastMeetingSnapshot: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let createdAtEpochSec: UInt64
    public let durationMs: UInt64
    public let source: String
    public let status: String
    public let segmentCount: Int
    public let decisionCount: Int
}

public struct LiveMinutesWorkspaceSnapshot: Codable, Equatable, Sendable {
    public let isActive: Bool
    public let canStart: Bool
    public let phase: String
    public let configured: Bool
    public let sourceLabel: String
    public let activeRecordId: String?
    public let selectedRecordId: String?
    public let selectedTitle: String?
    public let minutesStale: Bool
    public let canSummarize: Bool
    public let error: String?
    public let coverage: MeetingCoverageSnapshot?
    public let segments: [SegmentSnapshot]
    public let drafts: [String]
    public let liveSections: [SummarySnapshot]
    public let finalSections: [SummarySnapshot]
    public let actionItems: [WorkspaceSourcedItemSnapshot]
    public let pastMeetings: [PastMeetingSnapshot]

    private enum CodingKeys: String, CodingKey {
        case isActive, canStart, phase, configured, sourceLabel, activeRecordId
        case selectedRecordId, selectedTitle, minutesStale, canSummarize, error, coverage
        case segments, drafts, liveSections, finalSections, actionItems, pastMeetings
    }

    public init(
        isActive: Bool, canStart: Bool = true, phase: String, configured: Bool,
        sourceLabel: String, activeRecordId: String?, selectedRecordId: String?,
        selectedTitle: String?, minutesStale: Bool, canSummarize: Bool, error: String?,
        coverage: MeetingCoverageSnapshot?, segments: [SegmentSnapshot], drafts: [String],
        liveSections: [SummarySnapshot], finalSections: [SummarySnapshot],
        actionItems: [WorkspaceSourcedItemSnapshot], pastMeetings: [PastMeetingSnapshot]
    ) {
        self.isActive = isActive; self.canStart = canStart; self.phase = phase
        self.configured = configured; self.sourceLabel = sourceLabel
        self.activeRecordId = activeRecordId; self.selectedRecordId = selectedRecordId
        self.selectedTitle = selectedTitle; self.minutesStale = minutesStale
        self.canSummarize = canSummarize; self.error = error; self.coverage = coverage
        self.segments = segments; self.drafts = drafts
        self.liveSections = liveSections; self.finalSections = finalSections
        self.actionItems = actionItems; self.pastMeetings = pastMeetings
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        isActive = try c.decode(Bool.self, forKey: .isActive)
        canStart = try c.decodeIfPresent(Bool.self, forKey: .canStart) ?? false
        phase = try c.decode(String.self, forKey: .phase)
        configured = try c.decode(Bool.self, forKey: .configured)
        sourceLabel = try c.decode(String.self, forKey: .sourceLabel)
        activeRecordId = try c.decodeIfPresent(String.self, forKey: .activeRecordId)
        selectedRecordId = try c.decodeIfPresent(String.self, forKey: .selectedRecordId)
        selectedTitle = try c.decodeIfPresent(String.self, forKey: .selectedTitle)
        minutesStale = try c.decode(Bool.self, forKey: .minutesStale)
        canSummarize = try c.decode(Bool.self, forKey: .canSummarize)
        error = try c.decodeIfPresent(String.self, forKey: .error)
        coverage = try c.decodeIfPresent(MeetingCoverageSnapshot.self, forKey: .coverage)
        segments = try c.decode([SegmentSnapshot].self, forKey: .segments)
        drafts = try c.decode([String].self, forKey: .drafts)
        liveSections = try c.decode([SummarySnapshot].self, forKey: .liveSections)
        finalSections = try c.decode([SummarySnapshot].self, forKey: .finalSections)
        actionItems = try c.decode([WorkspaceSourcedItemSnapshot].self, forKey: .actionItems)
        pastMeetings = try c.decode([PastMeetingSnapshot].self, forKey: .pastMeetings)
    }

    public static let empty = LiveMinutesWorkspaceSnapshot(
        isActive: false, canStart: true, phase: "idle", configured: false,
        sourceLabel: "系统默认麦克风", activeRecordId: nil, selectedRecordId: nil,
        selectedTitle: nil, minutesStale: false, canSummarize: false, error: nil,
        coverage: nil, segments: [], drafts: [], liveSections: [], finalSections: [],
        actionItems: [], pastMeetings: []
    )

    public var phaseBadgeLabel: String {
        switch phase {
        case "starting": "正在启动"
        case "recording": "会议记录中"
        case "paused": "已暂停"
        case "finishing": "正在收尾"
        case "ended": "已结束"
        default: "待开始"
        }
    }
}
