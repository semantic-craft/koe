import Foundation

public struct HostPlatformSnapshot: Codable, Equatable, Sendable {
    public let id: String
    public let hostDisplayName: String
    public let supportsSystemAudio: Bool
    public let supportsSelfUpdate: Bool
    public let nativeSpeechLabel: String

    public init(
        id: String,
        hostDisplayName: String,
        supportsSystemAudio: Bool,
        supportsSelfUpdate: Bool,
        nativeSpeechLabel: String
    ) {
        self.id = id
        self.hostDisplayName = hostDisplayName
        self.supportsSystemAudio = supportsSystemAudio
        self.supportsSelfUpdate = supportsSelfUpdate
        self.nativeSpeechLabel = nativeSpeechLabel
    }

    public static let macosDefault = HostPlatformSnapshot(
        id: "macos",
        hostDisplayName: "Mac",
        supportsSystemAudio: true,
        supportsSelfUpdate: true,
        nativeSpeechLabel: "Apple 本机"
    )
}
