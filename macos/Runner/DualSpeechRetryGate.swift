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

enum DualSpeechRouteDecision: Equatable {
    case ignore
    case start
    case append
    case switchLane(from: String)
}

/// Coordinates on-device Speech recognition across the microphone and system
/// lanes so at most one SFSpeechRecognitionTask is active in the process at a
/// time (Apple's localspeechrecognition daemon cancels a first task with 1110
/// when the same process starts a second concurrent task).
struct DualSpeechTurnArbiter {
    private var gates: [String: DualSpeechRetryGate] = [
        "microphone": DualSpeechRetryGate(),
        "system": DualSpeechRetryGate(),
    ]
    private var lastVoiceTime: [String: Double] = [:]
    private var lastVoiceRms: [String: Float] = [:]
    private(set) var activeLane: String?
    private var activeStartedAt = 0.0
    private let holdSilenceSeconds = 1.2
    private let maxRequestSeconds = 50.0

    mutating func reset() {
        gates = [
            "microphone": DualSpeechRetryGate(),
            "system": DualSpeechRetryGate(),
        ]
        lastVoiceTime = [:]
        lastVoiceRms = [:]
        activeLane = nil
        activeStartedAt = 0
    }

    mutating func failed(lane: String, noSpeech: Bool, at time: Double) {
        var gate = gates[lane] ?? DualSpeechRetryGate()
        gate.failed(noSpeech: noSpeech, at: time)
        gates[lane] = gate
        if activeLane == lane {
            activeLane = nil
        }
    }

    mutating func requestEnded(lane: String) {
        if activeLane == lane {
            activeLane = nil
        }
    }

    mutating func route(lane: String, samples: [Float], at time: Double) -> DualSpeechRouteDecision {
        let (peak, rms) = Self.signalMetrics(samples)
        let hasVoice = isVoice(lane: lane, peak: peak, rms: rms, at: time)
        if hasVoice {
            lastVoiceTime[lane] = time
            lastVoiceRms[lane] = rms
        }
        let gate = gates[lane] ?? DualSpeechRetryGate()

        if activeLane == lane {
            if time - activeStartedAt > maxRequestSeconds {
                guard hasVoice, gate.mayStart(at: time, hasVoice: true) else { return .ignore }
                gates[lane] = DualSpeechRetryGate()
                activeStartedAt = time
                return .start
            }
            let lastActiveVoice = lastVoiceTime[lane] ?? activeStartedAt
            if hasVoice || time - lastActiveVoice <= holdSilenceSeconds {
                return .append
            }
            return .ignore
        }

        guard hasVoice, gate.mayStart(at: time, hasVoice: true) else {
            return .ignore
        }

        guard let currentLane = activeLane else {
            gates[lane] = DualSpeechRetryGate()
            activeLane = lane
            activeStartedAt = time
            return .start
        }

        let currentLastVoice = lastVoiceTime[currentLane] ?? activeStartedAt
        guard time - currentLastVoice >= holdSilenceSeconds else {
            return .ignore
        }

        gates[lane] = DualSpeechRetryGate()
        activeLane = lane
        activeStartedAt = time
        return .switchLane(from: currentLane)
    }

    private func isVoice(lane: String, peak: Float, rms: Float, at time: Double) -> Bool {
        if lane == "system" {
            return peak >= 0.015 && rms >= 0.004
        }
        guard peak >= 0.035 && rms >= 0.010 else { return false }
        if let systemVoiceAt = lastVoiceTime["system"], time - systemVoiceAt < holdSilenceSeconds {
            let systemRms = lastVoiceRms["system"] ?? 0
            return rms >= max(0.015, systemRms * 0.75)
        }
        return true
    }

    private static func signalMetrics(_ samples: [Float]) -> (peak: Float, rms: Float) {
        guard !samples.isEmpty else { return (0, 0) }
        var peak: Float = 0
        var sumSquares: Float = 0
        for sample in samples {
            let magnitude = abs(sample)
            if magnitude > peak { peak = magnitude }
            sumSquares += sample * sample
        }
        let rms = sqrt(sumSquares / Float(samples.count))
        return (peak, rms)
    }
}
