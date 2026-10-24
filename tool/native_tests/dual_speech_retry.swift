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

        var arbiter = DualSpeechTurnArbiter()
        let roomNoise = [Float](repeating: 0.008, count: 1600)
        let systemVoice = [Float](repeating: 0.12, count: 1600)
        let micBleed = [Float](repeating: 0.025, count: 1600)
        let micVoice = [Float](repeating: 0.18, count: 1600)
        let silence = [Float](repeating: 0.0, count: 1600)

        precondition(
            arbiter.route(lane: "microphone", samples: roomNoise, at: 0.1) == .ignore,
            "ambient microphone noise must not start a speech task"
        )
        precondition(
            arbiter.route(lane: "system", samples: systemVoice, at: 0.2) == .start,
            "system voice starts the single active speech task"
        )
        for step in 1...40 {
            let time = 0.2 + Double(step) * 0.1
            precondition(
                arbiter.route(lane: "system", samples: systemVoice, at: time) == .append,
                "active system speech keeps streaming without interruption"
            )
            precondition(
                arbiter.route(lane: "microphone", samples: micBleed, at: time + 0.02) == .ignore,
                "speaker bleed on microphone must not steal the recognizer every 3 seconds"
            )
        }
        // Brief pause in system speech keeps feeding the active request for natural phrasing.
        precondition(
            arbiter.route(lane: "system", samples: silence, at: 4.5) == .append,
            "short pause inside an utterance still feeds the active recognizer"
        )
        // Once system audio has been silent for >= 1.2s and the user speaks into the microphone,
        // the arbiter hands the single speech recognizer over to the microphone lane.
        precondition(
            arbiter.route(lane: "microphone", samples: micVoice, at: 5.6) == .switchLane(from: "system"),
            "microphone speech takes over after system speech finishes"
        )
        precondition(
            arbiter.route(lane: "microphone", samples: micVoice, at: 5.8) == .append,
            "microphone continues streaming after taking over"
        )
        print("PASS silent lane retry, new speech recovery, backoff and lane independence")
    }
}
