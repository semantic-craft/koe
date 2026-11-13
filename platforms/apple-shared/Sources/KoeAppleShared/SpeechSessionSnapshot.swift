import Foundation

public struct SpeechModelSnapshot: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let sizeBytes: UInt64
    public let state: String
    public let downloadedBytes: UInt64
    public let message: String?
}

public struct SpeechSnapshot: Codable, Equatable, Sendable {
    public let engine: String
    public let modelId: String?
    public let models: [SpeechModelSnapshot]
    public let appleState: String
    public let appleMessage: String?

    public static let empty = SpeechSnapshot(
        engine: "apple_speech", modelId: nil, models: [], appleState: "unavailable", appleMessage: nil
    )
}

public struct AllDaySnapshot: Codable, Equatable, Sendable {
    public let state: String
    public let source: String?
    public let runId: String?
    public let segmentCount: Int
    public let message: String?

    public static let empty = AllDaySnapshot(state: "idle", source: nil, runId: nil, segmentCount: 0, message: nil)
}

public struct DictationSnapshot: Codable, Equatable, Sendable {
    public let active: Bool
    public static let empty = DictationSnapshot(active: false)
}
