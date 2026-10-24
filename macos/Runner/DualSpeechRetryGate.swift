import Foundation

/// Keeps a silent or unavailable lane from restarting Speech on every frame.
/// Audio capture and the other lane continue independently.
struct DualSpeechRetryGate {
    private var waitingForVoice = false
    private var retryAfter = 0.0
    private var unavailable = false

    mutating func failed(noSpeech: Bool, at time: Double) {
        if noSpeech {
            waitingForVoice = true
            retryAfter = time + 3
        } else {
            unavailable = true
        }
    }

    func mayStart(at time: Double, hasVoice: Bool) -> Bool {
        !unavailable && (!waitingForVoice || (time >= retryAfter && hasVoice))
    }
}
