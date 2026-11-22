import AVFoundation
import Foundation
import os

final class IOSAudioSession: Sendable {
    enum Owner: String, Sendable { case microphone, playback }

    static let playbackLogger = Logger(subsystem: "com.semanticcraft.koe.ios", category: "playback")
    private let setSystemActive: @Sendable (Bool) throws -> Void
    private let transitionLock = NSLock()
    private let owners = OSAllocatedUnfairLock<Set<Owner>>(initialState: [])

    init(setActive: @escaping @Sendable (Bool) throws -> Void = { active in
        try AVAudioSession.sharedInstance().setActive(active, options: active ? [] : .notifyOthersOnDeactivation)
    }) {
        setSystemActive = setActive
    }

    // Input discovery needs a recording category when idle. Never change an owned route.
    func prepareInputDiscovery() throws -> Bool {
        transitionLock.lock()
        defer { transitionLock.unlock() }
        let current = owners.withLock { $0 }
        guard current != [.playback] else { return false }
        if current.isEmpty { try configure(microphone: true) }
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
        transitionLock.lock()
        defer { transitionLock.unlock() }
        let current = owners.withLock { $0 }
        guard current.contains(owner) != active else { return }
        let updated = active ? current.union([owner]) : current.subtracting([owner])
        if !updated.isEmpty {
            try configure(microphone: updated.contains(.microphone))
        }
        if current.isEmpty != updated.isEmpty {
            try setSystemActive(active)
            Self.playbackLogger.info("Audio session active=\(active), owner=\(owner.rawValue, privacy: .public)")
        }
        owners.withLock { $0 = updated }
    }
}
