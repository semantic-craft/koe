import Foundation

public struct SpeechModelSnapshot: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let sizeBytes: UInt64
    public let languages: [String]
    public let state: String
    public let downloadedBytes: UInt64
    public let message: String?

    private enum CodingKeys: String, CodingKey {
        case id, name, sizeBytes, languages, state, downloadedBytes, message
    }

    public init(
        id: String,
        name: String,
        sizeBytes: UInt64,
        languages: [String] = [],
        state: String,
        downloadedBytes: UInt64,
        message: String?
    ) {
        self.id = id
        self.name = name
        self.sizeBytes = sizeBytes
        self.languages = languages
        self.state = state
        self.downloadedBytes = downloadedBytes
        self.message = message
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        sizeBytes = try c.decode(UInt64.self, forKey: .sizeBytes)
        languages = try c.decodeIfPresent([String].self, forKey: .languages) ?? []
        state = try c.decode(String.self, forKey: .state)
        downloadedBytes = try c.decode(UInt64.self, forKey: .downloadedBytes)
        message = try c.decodeIfPresent(String.self, forKey: .message)
    }
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
