import AVFoundation
import os

final class IOSAudioSession {
    enum Owner: String { case microphone, playback }

    static let playbackLogger = Logger(subsystem: "com.semanticcraft.koe.ios", category: "playback")
    private let setSystemActive: (Bool) throws -> Void
    private var owners: Set<Owner> = []

    init(setActive: @escaping (Bool) throws -> Void = { active in
        let session = AVAudioSession.sharedInstance()
        if active { try IOSAudioSession.configure(session) }
        try session.setActive(active, options: active ? [] : .notifyOthersOnDeactivation)
    }) {
        setSystemActive = setActive
    }

    static func configure(_ session: AVAudioSession) throws {
        let options: AVAudioSession.CategoryOptions = [.defaultToSpeaker, .allowBluetoothHFP]
        if session.category != .playAndRecord || session.mode != .default ||
            !session.categoryOptions.isSuperset(of: options) {
            try session.setCategory(.playAndRecord, mode: .default, options: options)
        }
    }

    func setActive(_ active: Bool, for owner: Owner) throws {
        guard owners.contains(owner) != active else { return }
        let updated = active ? owners.union([owner]) : owners.subtracting([owner])
        if owners.isEmpty != updated.isEmpty {
            try setSystemActive(active)
            Self.playbackLogger.info("Audio session active=\(active), owner=\(owner.rawValue, privacy: .public)")
        }
        owners = updated
    }
}
