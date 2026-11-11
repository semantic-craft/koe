import Foundation

public struct SourceSnapshot: Codable, Equatable, Identifiable, Sendable {
    public var id: String { "\(recordId):\(segmentId)" }
    public let recordId: String
    public let segmentId: String
    public let title: String
    public let quote: String
    public let startMs: UInt64
}

public struct SegmentSnapshot: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let text: String
    public let startMs: UInt64
    public let endMs: UInt64
    public var timed: Bool? = nil
    public let speaker: String?
}

public typealias KoeColors = AppColors

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
    public var isTranscribing: Bool { status == "转写中" || status == "等待转写" }

    private enum CodingKeys: String, CodingKey {
        case id, title, createdAtEpochSec, durationMs, source, status, segmentCount, preview, archived
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
    }
}

public struct SummarySnapshot: Codable, Equatable, Sendable {
    public let title: String
    public let text: String
    public let sources: [SourceSnapshot]
}

public struct RecordDetailSnapshot: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let createdAtEpochSec: UInt64
    public let durationMs: UInt64
    public let source: String
    public let status: String
    public let archived: Bool
    public let segments: [SegmentSnapshot]
    public let summary: [SummarySnapshot]
    public let highlights: [SourceSnapshot]
    public let audioPath: String?
    public let canRetranscribe: Bool
    public let isProcessing: Bool

    private enum CodingKeys: String, CodingKey {
        case id, title, createdAtEpochSec, durationMs, source, status, archived
        case segments, summary, highlights, audioPath, canRetranscribe, isProcessing
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
        segments = try c.decode([SegmentSnapshot].self, forKey: .segments)
        summary = try c.decode([SummarySnapshot].self, forKey: .summary)
        highlights = try c.decode([SourceSnapshot].self, forKey: .highlights)
        audioPath = try c.decodeIfPresent(String.self, forKey: .audioPath)
        canRetranscribe = try c.decode(Bool.self, forKey: .canRetranscribe)
        isProcessing = try c.decode(Bool.self, forKey: .isProcessing)
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

public struct MigrationReportSnapshot: Codable, Equatable, Sendable, Identifiable {
    public var id: String { fingerprint }
    public let fingerprint: String
    public let archivePath: String
    public let recordCount: Int
    public let pending: [String]
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
    public let phase: String
    public let nextSequence: UInt64
    public let durationMs: UInt64
    public let error: String?
    public let interruption: String?
    public let epoch: UInt64
    public let clockNs: UInt64?
    public let lanes: [String: CaptureLaneSnapshot]
}

public struct HostSnapshot: Codable, Equatable, Sendable {
    public var microphone: MicrophoneSnapshot? = nil
    public var lifecycle: LifecycleSnapshot? = nil
    public let version: UInt32
    public let generation: UInt64
    public let section: String
    public let canGoBack: Bool
    public let selectedRecordId: String?
    public let focusSegmentId: String?
    public let records: [RecordSnapshot]
    public let todayRecordIds: [String]
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
    public var migrationReports: [MigrationReportSnapshot]? = nil
    public let notice: String?

    private enum CodingKeys: String, CodingKey {
        case microphone, lifecycle, version, generation, section, canGoBack
        case selectedRecordId, focusSegmentId, records, todayRecordIds
        case trashRecords, undoTrash, detail, tasks, memories, ask
        case device, provider, playback, error, migrationReports, notice
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
        selectedRecordId: nil, focusSegmentId: nil, records: [], todayRecordIds: [],
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
        microphone = try c.decodeIfPresent(MicrophoneSnapshot.self, forKey: .microphone)
        lifecycle = try c.decodeIfPresent(LifecycleSnapshot.self, forKey: .lifecycle)
        version = try c.decode(UInt32.self, forKey: .version)
        generation = try c.decode(UInt64.self, forKey: .generation)
        section = try c.decode(String.self, forKey: .section)
        canGoBack = try c.decode(Bool.self, forKey: .canGoBack)
        selectedRecordId = try c.decodeIfPresent(String.self, forKey: .selectedRecordId)
        focusSegmentId = try c.decodeIfPresent(String.self, forKey: .focusSegmentId)
        records = try c.decode([RecordSnapshot].self, forKey: .records)
        todayRecordIds = try c.decode([String].self, forKey: .todayRecordIds)
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
        migrationReports = try c.decodeIfPresent([MigrationReportSnapshot].self, forKey: .migrationReports)
        notice = try c.decodeIfPresent(String.self, forKey: .notice)
    }
}
