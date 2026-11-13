import Foundation

public struct VoiceInputSnapshot: Codable, Equatable, Sendable {
    public let sourceLabel: String
    public let canPrepare: Bool
    public let deviceStatus: String
    public let message: String

    static let empty = Self(sourceLabel: "soundcore Work", canPrepare: false, deviceStatus: "等待录音豆连接", message: "")
}

public struct HostAction: Decodable, Sendable {
    public enum Kind: String, Decodable, Sendable {
        case openResponsay = "open_responsay"
    }

    public let type: Kind
}
