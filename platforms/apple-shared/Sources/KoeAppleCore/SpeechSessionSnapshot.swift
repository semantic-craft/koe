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

public struct LiveCaptionSnapshot: Codable, Equatable, Sendable {
    public let recordId: String
    public let text: String
    public let status: String

    public init(recordId: String, text: String, status: String) {
        self.recordId = recordId
        self.text = text
        self.status = status
    }
}
