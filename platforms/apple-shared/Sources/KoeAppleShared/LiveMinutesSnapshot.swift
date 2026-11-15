import Foundation

public struct LiveMinutesSnapshot: Codable, Equatable, Sendable {
    public struct Scope: Codable, Equatable, Sendable {
        public enum Kind: String, Codable, Sendable {
            case record
            case beanStarting = "bean_starting"
            case allDay = "all_day"
        }

        public let kind: Kind
        public let id: String?
    }

    public enum Phase: String, Codable, Sendable {
        case idle, starting, recording, paused, finishing, ended
    }

    public struct Part: Codable, Equatable, Identifiable, Sendable {
        public enum Analysis: String, Codable, Sendable {
            case unconfigured, waiting, queued, summarizing, ready, stale, failed, interrupted
            case awaitingTranscript = "awaiting_transcript"
        }

        public var id: String { recordId }
        public let recordId: String
        public let title: String
        public let ordinal: UInt64?
        public let segments: [SegmentSnapshot]
        public let drafts: [String]
        public let summary: [SummarySnapshot]
        public let analysis: Analysis
        public let minutesStale: Bool
        public let error: String?
    }

    public let scope: Scope
    public let phase: Phase
    public let configured: Bool
    public let parts: [Part]
}
