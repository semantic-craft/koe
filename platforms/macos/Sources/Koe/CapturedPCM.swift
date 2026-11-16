import Foundation
import KoeAppleShared
import os

struct CapturedPCM: Sendable {
    let samples: [Int16]
    let capturedStartNs: UInt64
}

/// Binds every lane callback to one Rust capture session epoch.
struct CaptureSession: Equatable, Sendable {
    let recordId: String
    let sessionId: String
    let epoch: UInt64
    init(_ snapshot: MicrophoneSnapshot) {
        recordId = snapshot.recordId
        sessionId = snapshot.sessionId
        epoch = snapshot.epoch
    }
}

struct CaptureIdentity: Equatable, Sendable {
    let recordId: String
    let sessionId: String
    let lane: String
    let epoch: UInt64
    init(_ snapshot: MicrophoneSnapshot, lane: String) {
        recordId = snapshot.recordId
        sessionId = snapshot.sessionId
        self.lane = lane
        epoch = snapshot.epoch
    }
}

protocol MicrophoneSource: AnyObject {
    func requestPermission(_ completion: @escaping (Bool) -> Void)
    func start(inputID: String, expectedSampleRate: UInt32?, receive: @escaping (CapturedPCM) -> Void,
               failed: @escaping (String) -> Void) throws -> UInt32
    func stop()
}

/// Bounded per-lane queue: overflow stops that lane instead of silently dropping audio.
final class MicrophoneMailbox: @unchecked Sendable {
    struct Block { let sequence: UInt64; let pcm: CapturedPCM }
    private struct State {
        var ring: [Block?]
        var head = 0
        var count = 0
        var sequence: UInt64
        var closed = false
        var failure: String?

        init(nextSequence: UInt64, capacity: Int) {
            ring = Array(repeating: nil, count: max(1, capacity))
            sequence = nextSequence
        }
    }

    let limit: Int
    private let state: OSAllocatedUnfairLock<State>

    init(nextSequence: UInt64, limit: Int = 64) {
        self.limit = limit
        state = OSAllocatedUnfairLock(initialState: State(nextSequence: nextSequence, capacity: limit))
    }

    func append(_ pcm: CapturedPCM) {
        state.withLock { state in
            guard !state.closed else { return }
            guard !pcm.samples.isEmpty, pcm.samples.count <= 8192, state.count < limit else {
                state.failure = "音频处理未能跟上采集，已停止并保留已接收的音频。"
                state.closed = true
                return
            }
            let tail = (state.head + state.count) % state.ring.count
            state.ring[tail] = Block(sequence: state.sequence, pcm: pcm)
            state.count += 1
            state.sequence += 1
        }
    }

    func fail(_ message: String) {
        state.withLock { state in
            state.failure = state.failure ?? message
            state.closed = true
        }
    }

    func close() {
        state.withLock { $0.closed = true }
    }

    func discardUnaccepted(nextSequence: UInt64) {
        state.withLock { state in
            state.closed = true
            for offset in 0..<state.count {
                state.ring[(state.head + offset) % state.ring.count] = nil
            }
            state.head = 0
            state.count = 0
            state.sequence = nextSequence
        }
    }

    func peek() -> Block? {
        state.withLock { state in
            guard state.count > 0 else { return nil }
            return state.ring[state.head]
        }
    }

    func acknowledge(_ sequence: UInt64) {
        state.withLock { state in
            guard state.count > 0, state.ring[state.head]?.sequence == sequence else { return }
            state.ring[state.head] = nil
            state.head = (state.head + 1) % state.ring.count
            state.count -= 1
        }
    }

    var error: String? { state.withLock(\.failure) }
    var finalSequence: UInt64 { state.withLock(\.sequence) }
}
