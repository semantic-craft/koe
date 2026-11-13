import Foundation

public enum CaptureMode: String, Codable, Sendable {
    case quickNote = "quick_note"
    case allDay = "all_day"
    case meeting
    case dictation
}

public enum CaptureAction: String, Codable, Sendable {
    case pause
    case resume
    case end
    case endDictation = "end_dictation"
    case retrySave = "retry_save"
    case retryStop = "retry_stop"
    case cancel
}

public struct CaptureModeSnapshot: Codable, Equatable, Identifiable, Sendable {
    public var id: CaptureMode { mode }
    public let mode: CaptureMode
    public let sourceLabel: String
    public let available: Bool
}

public struct ActiveCaptureSnapshot: Codable, Equatable, Sendable {
    public let mode: CaptureMode
    public let phase: String
    public let sourceLabel: String
    public let durationMs: UInt64
    public let actions: [CaptureAction]
    public let dictating: Bool
    public let error: String?
    public let level: Double?
}

public struct JournalSummarySnapshot: Codable, Equatable, Identifiable, Sendable {
    public var id: String { recordId }
    public let recordId: String
    public let title: String
    public let text: String
}

public struct JournalSnapshot: Codable, Equatable, Sendable {
    public let dateEpochSec: UInt64
    public let recordIds: [String]
    public let summaries: [JournalSummarySnapshot]
    public let noteRecordIds: [String]

    static let empty = Self(dateEpochSec: 0, recordIds: [], summaries: [], noteRecordIds: [])
}
