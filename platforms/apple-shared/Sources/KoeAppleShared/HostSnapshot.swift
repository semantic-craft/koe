import Foundation

public struct SourceSnapshot: Codable, Equatable, Identifiable, Sendable {
    public var id: String { "\(recordId):\(segmentId)" }
    public let recordId: String
    public let segmentId: String
    public let title: String
    public let quote: String
    public let startMs: UInt64
}

public struct SpeakerSummarySnapshot: Codable, Equatable, Identifiable, Sendable {
    public var id: String { name }
    public let name: String
    public let segmentCount: Int
    public let firstSegmentId: String

    public init(name: String, segmentCount: Int, firstSegmentId: String) {
        self.name = name
        self.segmentCount = segmentCount
        self.firstSegmentId = firstSegmentId
    }
}

public struct SegmentSnapshot: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let text: String
    public let originalText: String?
    public let isEdited: Bool
    public let startMs: UInt64
    public let endMs: UInt64
    public var timed: Bool? = nil
    public let speaker: String?

    private enum CodingKeys: String, CodingKey {
        case id, text, originalText, isEdited, startMs, endMs, timed, speaker
    }

    public init(id: String, text: String, originalText: String? = nil, isEdited: Bool = false,
                startMs: UInt64, endMs: UInt64, timed: Bool? = nil, speaker: String? = nil) {
        self.id = id; self.text = text; self.originalText = originalText; self.isEdited = isEdited
        self.startMs = startMs; self.endMs = endMs; self.timed = timed; self.speaker = speaker
    }
}

extension SegmentSnapshot {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        text = try c.decode(String.self, forKey: .text)
        originalText = try c.decodeIfPresent(String.self, forKey: .originalText)
        isEdited = try c.decodeIfPresent(Bool.self, forKey: .isEdited) ?? false
        startMs = try c.decode(UInt64.self, forKey: .startMs)
        endMs = try c.decode(UInt64.self, forKey: .endMs)
        timed = try c.decodeIfPresent(Bool.self, forKey: .timed)
        speaker = try c.decodeIfPresent(String.self, forKey: .speaker)
    }
}

public struct RecordSnapshot: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let createdAtEpochSec: UInt64
    public let durationMs: UInt64
    public let source: String
    public let status: String
    public let segmentCount: Int
    public let preview: String
    public let archived: Bool
    public var runId: String? = nil
    public var ordinal: UInt64? = nil
    public var mode: String? = nil
    public var project: String? = nil
    public var isTranscribing: Bool { status == "转写中" || status == "等待转写" }

    private enum CodingKeys: String, CodingKey {
        case id, title, createdAtEpochSec, durationMs, source, status, segmentCount, preview, archived, runId, ordinal, mode, project
    }
}

extension RecordSnapshot {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        createdAtEpochSec = try c.decode(UInt64.self, forKey: .createdAtEpochSec)
        durationMs = try c.decode(UInt64.self, forKey: .durationMs)
        source = try c.decode(String.self, forKey: .source)
        status = try c.decode(String.self, forKey: .status)
        segmentCount = try c.decode(Int.self, forKey: .segmentCount)
        preview = try c.decode(String.self, forKey: .preview)
        archived = try c.decodeIfPresent(Bool.self, forKey: .archived) ?? false
        runId = try c.decodeIfPresent(String.self, forKey: .runId)
        ordinal = try c.decodeIfPresent(UInt64.self, forKey: .ordinal)
        mode = try c.decodeIfPresent(String.self, forKey: .mode)
        project = try c.decodeIfPresent(String.self, forKey: .project)
    }
}

public struct SummarySnapshot: Codable, Equatable, Identifiable, Sendable {
    public let title: String
    public let text: String
    public let sources: [SourceSnapshot]

    public var id: String { "\(title)\u{1F}\(text)" }
}

public struct SummarySectionItem: Identifiable, Equatable, Sendable {
    public let id: String
    public let section: SummarySnapshot

    public static func keyed(_ sections: [SummarySnapshot]) -> [SummarySectionItem] {
        var used: Set<String> = []
        return sections.map { section in
            let base = section.id
            var candidate = base
            var suffix = 2
            while used.contains(candidate) {
                candidate = "\(base)#\(suffix)"
                suffix += 1
            }
            used.insert(candidate)
            return SummarySectionItem(id: candidate, section: section)
        }
    }
}

public struct RecordDetailSnapshot: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let createdAtEpochSec: UInt64
    public let durationMs: UInt64
    public let source: String
    public let status: String
    public let archived: Bool
    public var mode: String? = nil
    public var project: String? = nil
    public let segments: [SegmentSnapshot]
    public let summary: [SummarySnapshot]
    public let highlights: [SourceSnapshot]
    public let audioPath: String?
    public let canRetranscribe: Bool
    public let isProcessing: Bool
    public let minutesStale: Bool
    public let canEditTranscript: Bool
    public let speakers: [SpeakerSummarySnapshot]

    private enum CodingKeys: String, CodingKey {
        case id, title, createdAtEpochSec, durationMs, source, status, archived, mode, project
        case segments, summary, highlights, audioPath, canRetranscribe, isProcessing
        case minutesStale, canEditTranscript, speakers
    }

    public init(id: String, title: String, createdAtEpochSec: UInt64, durationMs: UInt64,
                source: String, status: String, archived: Bool = false, mode: String? = nil,
                project: String? = nil, segments: [SegmentSnapshot],
                summary: [SummarySnapshot], highlights: [SourceSnapshot], audioPath: String? = nil,
                canRetranscribe: Bool = false, isProcessing: Bool = false, minutesStale: Bool = false,
                canEditTranscript: Bool = false, speakers: [SpeakerSummarySnapshot] = []) {
        self.id = id; self.title = title; self.createdAtEpochSec = createdAtEpochSec; self.durationMs = durationMs
        self.source = source; self.status = status; self.archived = archived; self.mode = mode; self.project = project
        self.segments = segments; self.summary = summary; self.highlights = highlights; self.audioPath = audioPath
        self.canRetranscribe = canRetranscribe; self.isProcessing = isProcessing
        self.minutesStale = minutesStale; self.canEditTranscript = canEditTranscript; self.speakers = speakers
    }
}

extension RecordDetailSnapshot {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        createdAtEpochSec = try c.decode(UInt64.self, forKey: .createdAtEpochSec)
        durationMs = try c.decode(UInt64.self, forKey: .durationMs)
        source = try c.decode(String.self, forKey: .source)
        status = try c.decode(String.self, forKey: .status)
        archived = try c.decodeIfPresent(Bool.self, forKey: .archived) ?? false
        mode = try c.decodeIfPresent(String.self, forKey: .mode)
        project = try c.decodeIfPresent(String.self, forKey: .project)
        segments = try c.decode([SegmentSnapshot].self, forKey: .segments)
        summary = try c.decode([SummarySnapshot].self, forKey: .summary)
        highlights = try c.decode([SourceSnapshot].self, forKey: .highlights)
        audioPath = try c.decodeIfPresent(String.self, forKey: .audioPath)
        canRetranscribe = try c.decode(Bool.self, forKey: .canRetranscribe)
        isProcessing = try c.decode(Bool.self, forKey: .isProcessing)
        minutesStale = try c.decodeIfPresent(Bool.self, forKey: .minutesStale) ?? false
        canEditTranscript = try c.decodeIfPresent(Bool.self, forKey: .canEditTranscript) ?? false
        speakers = try c.decodeIfPresent([SpeakerSummarySnapshot].self, forKey: .speakers) ?? []
    }
}

public struct TrashRecordSnapshot: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let createdAtEpochSec: UInt64
    public let durationMs: UInt64
    public let source: String
    public let segmentCount: Int
    public let preview: String
    public let trashedAtMs: UInt64
    public let expiresAtMs: UInt64
    public let remainingDays: Int
}

public struct UndoTrashSnapshot: Codable, Equatable, Sendable {
    public let recordId: String
    public let title: String

    public init(recordId: String, title: String) {
        self.recordId = recordId
        self.title = title
    }
}

public struct TaskSnapshot: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let text: String
    public let state: String
    public let completed: Bool
    public let due: String?
    public let sources: [SourceSnapshot]
}

public struct MemorySnapshot: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let text: String
    public let state: String
    public let sources: [SourceSnapshot]
}

public struct AskMessageSnapshot: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let role: String
    public let text: String
    public let mode: String
    public let sources: [SourceSnapshot]
}

public struct AskSnapshot: Codable, Equatable, Sendable {
    public let scope: String
    public let recordId: String?
    public let phase: String
    public let messages: [AskMessageSnapshot]
}

public struct ProviderSnapshot: Codable, Equatable, Sendable {
    public let meetingAudioPolicy: String
    public let meetingAudioStatus: String?
    public let meetingAudioPolicyError: String?
    public let configured: Bool
    public let model: String
    public let asrEndpoint: String
    public let chatEndpoint: String
    public let credentialState: String
    public let isolated: Bool

    private enum CodingKeys: String, CodingKey {
        case configured, model, asrEndpoint, chatEndpoint, credentialState, isolated
        case meetingAudioPolicy, meetingAudioStatus, meetingAudioPolicyError
    }

    static let empty = ProviderSnapshot(
        meetingAudioPolicy: "local_only",
        meetingAudioStatus: nil,
        meetingAudioPolicyError: nil,
        configured: false,
        model: "",
        asrEndpoint: "",
        chatEndpoint: "",
        credentialState: "missing",
        isolated: true
    )
}

extension ProviderSnapshot {
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        meetingAudioPolicy = try values.decodeIfPresent(String.self, forKey: .meetingAudioPolicy) ?? "local_only"
        meetingAudioStatus = try values.decodeIfPresent(String.self, forKey: .meetingAudioStatus)
        meetingAudioPolicyError = try values.decodeIfPresent(String.self, forKey: .meetingAudioPolicyError)
        let configured = try values.decode(Bool.self, forKey: .configured)
        self.configured = configured
        model = try values.decode(String.self, forKey: .model)
        asrEndpoint = try values.decodeIfPresent(String.self, forKey: .asrEndpoint) ?? ""
        chatEndpoint = try values.decodeIfPresent(String.self, forKey: .chatEndpoint) ?? ""
        credentialState = try values.decodeIfPresent(String.self, forKey: .credentialState) ?? (configured ? "ready" : "missing")
        isolated = try values.decodeIfPresent(Bool.self, forKey: .isolated) ?? true
    }
}

public struct LifecycleSnapshot: Codable, Equatable, Sendable {
    public let keepAwake: Bool
    public let quitPhase: String
    public let message: String?

    public init(keepAwake: Bool, quitPhase: String, message: String? = nil) {
        self.keepAwake = keepAwake
        self.quitPhase = quitPhase
        self.message = message
    }
}

public struct CaptureLaneSnapshot: Codable, Equatable, Sendable {
    public let nextSequence: UInt64
    public let sampleRate: UInt32?
    public let started: Bool
    public let stopped: Bool
    public let error: String?
    public let interruption: String?
}

public struct MicrophoneSnapshot: Codable, Equatable, Sendable {
    public let recordId: String
    public let sessionId: String
    public let lane: String
    public let inputId: String
    public var inputLabel: String = "Mac 麦克风"
    public var inputBadge: String = "系统默认"
    public let phase: String
    public let nextSequence: UInt64
    public let durationMs: UInt64
    public var level: Double = 0.0
    public let error: String?
    public let interruption: String?
    public let epoch: UInt64
    public let clockNs: UInt64?
    public let lanes: [String: CaptureLaneSnapshot]

    public var phaseSummaryLabel: String {
        switch phase {
        case "paused": "已暂停"
        case "saving": "正在保存"
        case "stopping": "正在停止并保存"
        case "pausing": "正在暂停"
        case "cancelling": "正在取消"
        case "starting": "等待权限"
        default: "正在录音"
        }
    }

    private enum CodingKeys: String, CodingKey {
        case recordId, sessionId, lane, inputId, inputLabel, inputBadge, phase, nextSequence, durationMs
        case level, error, interruption, epoch, clockNs, lanes
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        recordId = try c.decode(String.self, forKey: .recordId)
        sessionId = try c.decode(String.self, forKey: .sessionId)
        lane = try c.decode(String.self, forKey: .lane)
        inputId = try c.decode(String.self, forKey: .inputId)
        inputLabel = try c.decodeIfPresent(String.self, forKey: .inputLabel) ?? "Mac 麦克风"
        inputBadge = try c.decodeIfPresent(String.self, forKey: .inputBadge) ?? "系统默认"
        phase = try c.decode(String.self, forKey: .phase)
        nextSequence = try c.decode(UInt64.self, forKey: .nextSequence)
        durationMs = try c.decode(UInt64.self, forKey: .durationMs)
        level = try c.decodeIfPresent(Double.self, forKey: .level) ?? 0.0
        error = try c.decodeIfPresent(String.self, forKey: .error)
        interruption = try c.decodeIfPresent(String.self, forKey: .interruption)
        epoch = try c.decode(UInt64.self, forKey: .epoch)
        clockNs = try c.decodeIfPresent(UInt64.self, forKey: .clockNs)
        lanes = try c.decode([String: CaptureLaneSnapshot].self, forKey: .lanes)
    }
}

public struct HostSnapshot: Codable, Equatable, Sendable {
    public var speech: SpeechSnapshot = .empty
    public var appUpdate: AppUpdateSnapshot = .empty
    public var liveCaption: LiveCaptionSnapshot? = nil
    public var microphone: MicrophoneSnapshot? = nil
    public var capture: CaptureStudioSnapshot = .empty
    public var lifecycle: LifecycleSnapshot? = nil
    public var activeCapture: ActiveCaptureSnapshot? = nil
    public var workspaces: ModeWorkspacesSnapshot? = nil
    public let version: UInt32
    public let generation: UInt64
    public let section: String
    public let canGoBack: Bool
    public let selectedRecordId: String?
    public let focusSegmentId: String?
    public let records: [RecordSnapshot]
    public let trashRecords: [TrashRecordSnapshot]
    public let undoTrash: UndoTrashSnapshot?
    public let detail: RecordDetailSnapshot?
    public let tasks: [TaskSnapshot]
    public let memories: [MemorySnapshot]
    public let ask: AskSnapshot
    public let device: DeviceSnapshot
    public let provider: ProviderSnapshot
    public let playback: PlaybackSnapshot
    public let error: String?
    public let notice: String?

    private enum CodingKeys: String, CodingKey {
        case liveCaption, speech, appUpdate
        case activeCapture, workspaces
        case microphone, capture, lifecycle, version, generation, section, canGoBack
        case selectedRecordId, focusSegmentId, records
        case trashRecords, undoTrash, detail, tasks, memories, ask
        case device, provider, playback, error, notice
    }

    public var activeLiveRecord: RecordSnapshot? {
        if let liveId = device.liveRecordId,
           let matched = records.first(where: { $0.id == liveId }) {
            return matched
        }
        return records.first(where: \.isTranscribing)
    }

    public static let empty = HostSnapshot(
        version: 2, generation: 0, section: "today", canGoBack: false,
        selectedRecordId: nil, focusSegmentId: nil, records: [],
        trashRecords: [], undoTrash: nil, detail: nil, tasks: [], memories: [],
        ask: AskSnapshot(scope: "all", recordId: nil, phase: "idle", messages: []),
        device: .empty,
        provider: .empty,
        playback: PlaybackSnapshot(recordId: nil, positionMs: 0, isPlaying: false, requestId: 0, lane: nil, lanes: [], asset: nil),
        error: nil, notice: nil
    )
}

extension HostSnapshot {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        speech = try c.decodeIfPresent(SpeechSnapshot.self, forKey: .speech) ?? .empty
        appUpdate = try c.decodeIfPresent(AppUpdateSnapshot.self, forKey: .appUpdate) ?? .empty
        liveCaption = try c.decodeIfPresent(LiveCaptionSnapshot.self, forKey: .liveCaption)
        microphone = try c.decodeIfPresent(MicrophoneSnapshot.self, forKey: .microphone)
        capture = try c.decodeIfPresent(CaptureStudioSnapshot.self, forKey: .capture) ?? .empty
        lifecycle = try c.decodeIfPresent(LifecycleSnapshot.self, forKey: .lifecycle)
        activeCapture = try c.decodeIfPresent(ActiveCaptureSnapshot.self, forKey: .activeCapture)
        workspaces = try c.decodeIfPresent(ModeWorkspacesSnapshot.self, forKey: .workspaces)
        version = try c.decode(UInt32.self, forKey: .version)
        generation = try c.decode(UInt64.self, forKey: .generation)
        section = try c.decode(String.self, forKey: .section)
        canGoBack = try c.decode(Bool.self, forKey: .canGoBack)
        selectedRecordId = try c.decodeIfPresent(String.self, forKey: .selectedRecordId)
        focusSegmentId = try c.decodeIfPresent(String.self, forKey: .focusSegmentId)
        records = try c.decode([RecordSnapshot].self, forKey: .records)
        trashRecords = try c.decodeIfPresent([TrashRecordSnapshot].self, forKey: .trashRecords) ?? []
        undoTrash = try c.decodeIfPresent(UndoTrashSnapshot.self, forKey: .undoTrash)
        detail = try c.decodeIfPresent(RecordDetailSnapshot.self, forKey: .detail)
        tasks = try c.decode([TaskSnapshot].self, forKey: .tasks)
        memories = try c.decode([MemorySnapshot].self, forKey: .memories)
        ask = try c.decode(AskSnapshot.self, forKey: .ask)
        device = try c.decode(DeviceSnapshot.self, forKey: .device)
        provider = try c.decode(ProviderSnapshot.self, forKey: .provider)
        playback = try c.decode(PlaybackSnapshot.self, forKey: .playback)
        error = try c.decodeIfPresent(String.self, forKey: .error)
        notice = try c.decodeIfPresent(String.self, forKey: .notice)
    }
}
