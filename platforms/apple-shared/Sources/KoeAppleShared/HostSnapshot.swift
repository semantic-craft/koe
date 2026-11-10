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
    public let speaker: String?
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
    public let segments: [SegmentSnapshot]
    public let summary: [SummarySnapshot]
    public let highlights: [SourceSnapshot]
    public let audioPath: String?
    public let canRetranscribe: Bool
    public let isProcessing: Bool
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

public struct DeviceFileSnapshot: Codable, Equatable, Identifiable, Sendable {
    public let id: UInt32
    public let title: String
    public let durationMs: UInt64
}

public struct DeviceSnapshot: Codable, Equatable, Sendable {
    public let state: String
    public let connected: Bool
    public let busy: Bool
    public let files: [DeviceFileSnapshot]
    public let progress: Double
}

public struct ProviderSnapshot: Codable, Equatable, Sendable {
    public let configured: Bool
    public let model: String
}

public struct PlaybackSnapshot: Codable, Equatable, Sendable {
    public let recordId: String?
    public let positionMs: UInt64
    public let isPlaying: Bool
}

public struct HostSnapshot: Codable, Equatable, Sendable {
    public let version: UInt32
    public let generation: UInt64
    public let section: String
    public let canGoBack: Bool
    public let selectedRecordId: String?
    public let focusSegmentId: String?
    public let records: [RecordSnapshot]
    public let todayRecordIds: [String]
    public let detail: RecordDetailSnapshot?
    public let tasks: [TaskSnapshot]
    public let memories: [MemorySnapshot]
    public let ask: AskSnapshot
    public let device: DeviceSnapshot
    public let provider: ProviderSnapshot
    public let playback: PlaybackSnapshot
    public let error: String?
    public let notice: String?

    public static let empty = HostSnapshot(
        version: 2, generation: 0, section: "today", canGoBack: false,
        selectedRecordId: nil, focusSegmentId: nil, records: [], todayRecordIds: [],
        detail: nil, tasks: [], memories: [],
        ask: AskSnapshot(scope: "all", recordId: nil, phase: "idle", messages: []),
        device: DeviceSnapshot(state: "未连接", connected: false, busy: false, files: [], progress: 0),
        provider: ProviderSnapshot(configured: false, model: ""),
        playback: PlaybackSnapshot(recordId: nil, positionMs: 0, isPlaying: false),
        error: nil, notice: nil
    )
}
