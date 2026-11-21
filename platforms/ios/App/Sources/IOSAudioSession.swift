import AVFoundation
import os

final class IOSAudioSession {
    enum Owner: String { case microphone, playback }

    static let playbackLogger = Logger(subsystem: "com.semanticcraft.koe.ios", category: "playback")
    private let setSystemActive: (Bool) throws -> Void
    private var owners: Set<Owner> = []

    init(setActive: @escaping (Bool) throws -> Void = { active in
        try AVAudioSession.sharedInstance().setActive(active, options: active ? [] : .notifyOthersOnDeactivation)
    }) {
        setSystemActive = setActive
    }

    // Input discovery needs a recording category when idle. Never change an owned route.
    func prepareInputDiscovery() throws -> Bool {
        guard owners != [.playback] else { return false }
        if owners.isEmpty { try configure(microphone: true) }
        return true
    }

    private func configure(microphone: Bool) throws {
        let session = AVAudioSession.sharedInstance()
        let category: AVAudioSession.Category = microphone ? .playAndRecord : .playback
        let options: AVAudioSession.CategoryOptions = microphone ? [.defaultToSpeaker, .allowBluetoothHFP] : []
        if session.category != category || session.mode != .default || session.categoryOptions != options {
            try session.setCategory(category, mode: .default, options: options)
        }
    }

    func setActive(_ active: Bool, for owner: Owner) throws {
        guard owners.contains(owner) != active else { return }
        let updated = active ? owners.union([owner]) : owners.subtracting([owner])
        if !updated.isEmpty {
            try configure(microphone: updated.contains(.microphone))
        }
        if owners.isEmpty != updated.isEmpty {
            try setSystemActive(active)
            Self.playbackLogger.info("Audio session active=\(active), owner=\(owner.rawValue, privacy: .public)")
        }
        owners = updated
    }
}
