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
