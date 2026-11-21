import Foundation

public struct HostPlatformSnapshot: Codable, Equatable, Sendable {
    public let id: String
    public let hostDisplayName: String
    public let supportsNativeSpeech: Bool
    public let supportsSystemAudio: Bool
    public let supportsSelfUpdate: Bool
    public let nativeSpeechLabel: String

    public init(
        id: String,
        hostDisplayName: String,
        supportsSystemAudio: Bool,
        supportsSelfUpdate: Bool,
        nativeSpeechLabel: String,
        supportsNativeSpeech: Bool? = nil
    ) {
        self.supportsNativeSpeech = supportsNativeSpeech ?? (id != "android")
        self.id = id
        self.hostDisplayName = hostDisplayName
        self.supportsSystemAudio = supportsSystemAudio
        self.supportsSelfUpdate = supportsSelfUpdate
        self.nativeSpeechLabel = nativeSpeechLabel
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: values.decode(String.self, forKey: .id),
            hostDisplayName: values.decode(String.self, forKey: .hostDisplayName),
            supportsSystemAudio: values.decode(Bool.self, forKey: .supportsSystemAudio),
            supportsSelfUpdate: values.decode(Bool.self, forKey: .supportsSelfUpdate),
            nativeSpeechLabel: values.decode(String.self, forKey: .nativeSpeechLabel),
            supportsNativeSpeech: values.decodeIfPresent(Bool.self, forKey: .supportsNativeSpeech)
        )
    }

    public static let macosDefault = HostPlatformSnapshot(
        id: "macos",
        hostDisplayName: "Mac",
        supportsSystemAudio: true,
        supportsSelfUpdate: true,
        nativeSpeechLabel: "Apple 本机"
    )
}
