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

    public static func resolved(from snapshot: HostSnapshot) -> LiveMinutesWorkspaceSnapshot {
        if let projected = snapshot.workspaces?.liveMinutes {
            return projected
        }
        guard let legacy = snapshot.liveMinutes else {
            return .empty
        }
        let lastPart = legacy.parts.last
        let mergedSegments = legacy.parts.flatMap(\.segments)
        let mergedDrafts = legacy.parts.flatMap(\.drafts)
        let mergedSections = legacy.parts.flatMap(\.summary)
        let active = legacy.phase != .ended && legacy.phase != .idle
        return LiveMinutesWorkspaceSnapshot(
            isActive: active,
            canStart: snapshot.capture.canStart && !active,
            phase: legacy.phase.rawValue,
            configured: legacy.configured,
            sourceLabel: snapshot.capture.selectedLabel,
            activeRecordId: active ? lastPart?.recordId : nil,
            selectedRecordId: lastPart?.recordId,
            selectedTitle: lastPart?.title,
            minutesStale: legacy.parts.contains(where: \.minutesStale),
            canSummarize: false,
            error: legacy.parts.compactMap(\.error).first,
            coverage: nil,
            segments: mergedSegments,
            drafts: mergedDrafts,
            liveSections: mergedSections,
            finalSections: legacy.phase == .ended ? mergedSections : [],
            actionItems: [],
            pastMeetings: []
        )
    }
}

public struct VoiceInputStepSnapshot: Codable, Equatable, Identifiable, Sendable {
    public let number: Int
    public let id: String
    public let title: String
    public let status: String
    public let statusLabel: String
    public let detail: String
    public let actionLabel: String?
    public let actionCommand: String?
}

public struct VoiceInputWorkspaceSnapshot: Codable, Equatable, Sendable {
    public let sessionEnabled: Bool
    public let canToggleSession: Bool
    public let standbyReady: Bool
    public let deviceConnected: Bool
    public let deviceName: String
    public let batteryPercent: Int?
    public let captureActive: Bool
    public let companionSubscribers: Int
    public let companionEpoch: String
    public let companionSequence: UInt64
    public let forwardedAudioFrames: UInt64
    public let lastDictationText: String?
    public let bridgeSocketPath: String?
    public let boundaryNote: String
    public let steps: [VoiceInputStepSnapshot]

    private enum CodingKeys: String, CodingKey {
        case sessionEnabled, canToggleSession, standbyReady, deviceConnected, deviceName
        case batteryPercent, captureActive, companionSubscribers, companionEpoch
        case companionSequence, forwardedAudioFrames, lastDictationText
        case bridgeSocketPath, boundaryNote, steps
    }

    public init(
        sessionEnabled: Bool, canToggleSession: Bool, standbyReady: Bool,
        deviceConnected: Bool, deviceName: String, batteryPercent: Int?,
        captureActive: Bool, companionSubscribers: Int, companionEpoch: String = "",
        companionSequence: UInt64, forwardedAudioFrames: UInt64 = 0,
        lastDictationText: String?, bridgeSocketPath: String?,
        boundaryNote: String, steps: [VoiceInputStepSnapshot]
    ) {
        self.sessionEnabled = sessionEnabled; self.canToggleSession = canToggleSession
        self.standbyReady = standbyReady; self.deviceConnected = deviceConnected
        self.deviceName = deviceName; self.batteryPercent = batteryPercent
        self.captureActive = captureActive; self.companionSubscribers = companionSubscribers
        self.companionEpoch = companionEpoch; self.companionSequence = companionSequence
        self.forwardedAudioFrames = forwardedAudioFrames; self.lastDictationText = lastDictationText
        self.bridgeSocketPath = bridgeSocketPath; self.boundaryNote = boundaryNote
        self.steps = steps
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sessionEnabled = try c.decode(Bool.self, forKey: .sessionEnabled)
        canToggleSession = try c.decode(Bool.self, forKey: .canToggleSession)
        standbyReady = try c.decode(Bool.self, forKey: .standbyReady)
        deviceConnected = try c.decode(Bool.self, forKey: .deviceConnected)
        deviceName = try c.decode(String.self, forKey: .deviceName)
        batteryPercent = try c.decodeIfPresent(Int.self, forKey: .batteryPercent)
        captureActive = try c.decode(Bool.self, forKey: .captureActive)
        companionSubscribers = try c.decode(Int.self, forKey: .companionSubscribers)
        companionEpoch = try c.decodeIfPresent(String.self, forKey: .companionEpoch) ?? ""
        companionSequence = try c.decode(UInt64.self, forKey: .companionSequence)
        forwardedAudioFrames = try c.decodeIfPresent(UInt64.self, forKey: .forwardedAudioFrames) ?? 0
        lastDictationText = try c.decodeIfPresent(String.self, forKey: .lastDictationText)
        bridgeSocketPath = try c.decodeIfPresent(String.self, forKey: .bridgeSocketPath)
        boundaryNote = try c.decode(String.self, forKey: .boundaryNote)
        steps = try c.decode([VoiceInputStepSnapshot].self, forKey: .steps)
    }

    public static let empty = VoiceInputWorkspaceSnapshot(
        sessionEnabled: false, canToggleSession: true, standbyReady: false,
        deviceConnected: false, deviceName: "Soundcore Work", batteryPercent: nil,
        captureActive: false, companionSubscribers: 0, companionEpoch: "",
        companionSequence: 0, forwardedAudioFrames: 0, lastDictationText: nil,
        bridgeSocketPath: nil,
        boundaryNote: "Koe 负责维护录音豆低延迟待命音频流与桥接通道；快捷键监听、语音识别与系统光标上屏由 Responsay 管理。",
        steps: []
    )

    public func evaluateCursorTest(
        text: String,
        baselineEpoch: String,
        baselineAudioFrames: UInt64,
        baselineDictationText: String?
    ) -> VoiceInputTestEvaluation {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return VoiceInputTestEvaluation(
                state: .idle,
                statusBadge: "待测试",
                detail: "将光标置于下方输入框，按 Fn / 右 Option 或双击录音豆正面说话。"
            )
        }
        let dictationChanged = lastDictationText != nil && lastDictationText != baselineDictationText
        let audioAdvanced = companionEpoch == baselineEpoch
            ? forwardedAudioFrames > baselineAudioFrames
            : forwardedAudioFrames > 0
        if captureActive || audioAdvanced || dictationChanged {
            return VoiceInputTestEvaluation(
                state: .streamVerified,
                statusBadge: "已观测伴侣流",
                detail: "输入期间检测到录音豆伴侣流事件推进。"
            )
        }
        return VoiceInputTestEvaluation(
            state: .manualInputOnly,
            statusBadge: "仅检测到手动输入",
            detail: "输入框已有文字，但期间未观测到录音豆伴侣语音流变化；语音识别链路仍待真机说话验证。"
        )
    }
}

public struct VoiceInputTestEvaluation: Equatable, Sendable {
    public enum State: String, Equatable, Sendable {
        case idle
        case manualInputOnly
        case streamVerified
    }

    public let state: State
    public let statusBadge: String
    public let detail: String
}
