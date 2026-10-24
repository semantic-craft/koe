import Foundation

@main
struct DualSpeechRetryCheck {
    static func main() {
        var mic = DualSpeechRetryGate()
        var starts = 1
        mic.failed(noSpeech: true, at: 0)
        // Replay the device failure followed by 30 seconds of silent frames.
        // The former per-frame restart starved the other Speech request.
        for frame in 1...300 {
            let time = Double(frame) / 10
            if mic.mayStart(at: time, hasVoice: false) {
                starts += 1
                mic.failed(noSpeech: true, at: time)
            }
        }
        precondition(starts == 1, "silence must not restart a request for each frame")
        precondition(mic.mayStart(at: 31, hasVoice: true), "new speech resumes the lane")
        mic.failed(noSpeech: true, at: 31)
        precondition(!mic.mayStart(at: 31.1, hasVoice: true), "noise cannot cause a rapid retry")
        precondition(mic.mayStart(at: 34, hasVoice: true))
        mic.failed(noSpeech: false, at: 35)
        precondition(!mic.mayStart(at: 100, hasVoice: true), "unavailable recognition waits for explicit retry")
        let system = DualSpeechRetryGate()
        precondition(system.mayStart(at: 1, hasVoice: true), "microphone failures do not block system speech")
        print("PASS silent lane retry, new speech recovery, backoff and lane independence")
    }
}
