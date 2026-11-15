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

    public static let empty = AllDayWorkspaceSnapshot(
        isActive: false,
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

    public static let empty = LiveMinutesWorkspaceSnapshot(
        isActive: false,
        phase: "idle",
        configured: false,
        sourceLabel: "系统默认麦克风",
        activeRecordId: nil,
        selectedRecordId: nil,
        selectedTitle: nil,
        minutesStale: false,
        canSummarize: false,
        error: nil,
        coverage: nil,
        segments: [],
        drafts: [],
        liveSections: [],
        finalSections: [],
        actionItems: [],
        pastMeetings: []
    )
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
    public let companionSequence: UInt64
    public let lastDictationText: String?
    public let bridgeSocketPath: String?
    public let boundaryNote: String
    public let steps: [VoiceInputStepSnapshot]

    public static let empty = VoiceInputWorkspaceSnapshot(
        sessionEnabled: false,
        canToggleSession: true,
        standbyReady: false,
        deviceConnected: false,
        deviceName: "Soundcore Work",
        batteryPercent: nil,
        captureActive: false,
        companionSubscribers: 0,
        companionSequence: 0,
        lastDictationText: nil,
        bridgeSocketPath: nil,
        boundaryNote: "Koe 负责维护录音豆低延迟待命音频流与桥接通道；快捷键监听、语音识别与系统光标上屏由 Responsay 管理。",
        steps: []
    )
}
