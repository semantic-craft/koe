import AVFAudio
import Foundation
import os

public struct CapturedPCM: Sendable {
    public let samples: [Int16]
    public let capturedStartNs: UInt64

    public init(samples: [Int16], capturedStartNs: UInt64) {
        self.samples = samples
        self.capturedStartNs = capturedStartNs
    }

    public static func sampleRate(for format: AVAudioFormat, expectedSampleRate: UInt32?) throws -> UInt32 {
        guard format.sampleRate >= 8_000, format.sampleRate <= 96_000,
              format.sampleRate.rounded() == format.sampleRate, format.channelCount > 0,
              format.commonFormat == .pcmFormatFloat32, !format.isInterleaved else {
            throw CaptureError("麦克风没有可用的 PCM 输入格式。")
        }
        let rate = UInt32(format.sampleRate)
        guard expectedSampleRate == nil || expectedSampleRate == rate else {
            throw CaptureError("麦克风采样率发生变化，已保留此前收到的音频。")
        }
        return rate
    }

    public static func capture(_ buffer: AVAudioPCMBuffer, when: AVAudioTime,
                               expectedSampleRate: UInt32) throws -> CapturedPCM {
        guard when.isHostTimeValid else { throw CaptureError("音频缺少有效采样时钟。") }
        guard buffer.format.sampleRate == Double(expectedSampleRate),
              buffer.format.channelCount > 0, buffer.format.commonFormat == .pcmFormatFloat32,
              !buffer.format.isInterleaved, let channels = buffer.floatChannelData else {
            throw CaptureError("麦克风输入格式已改变。")
        }
        let count = Int(buffer.frameLength)
        guard count > 0, count <= 8192 else { throw CaptureError("麦克风音频块超过接收上限。") }
        let channelCount = Int(buffer.format.channelCount)
        let samples = [Int16](unsafeUninitializedCapacity: count) { output, initializedCount in
            for frame in 0..<count {
                var value: Float = 0
                for channel in 0..<channelCount { value += channels[channel][frame] / Float(channelCount) }
                output[frame] = value.isFinite ? Int16(max(-1, min(1, value)) * 32767) : 0
            }
            initializedCount = count
        }
        return CapturedPCM(samples: samples, capturedStartNs: try HostAudioClock.nanoseconds(when.hostTime))
    }
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

public protocol MicrophoneSource: AnyObject {
    func requestPermission(_ completion: @escaping @Sendable (Bool) -> Void)
    func start(inputID: String, expectedSampleRate: UInt32?, receive: @escaping @Sendable (CapturedPCM) -> Void,
               failed: @escaping @Sendable (String) -> Void) throws -> UInt32
    func stop()
}

/// Bounded per-lane queue: overflow stops that lane instead of silently dropping audio.
final class MicrophoneMailbox: Sendable {
    struct Block: Sendable { let sequence: UInt64; let pcm: CapturedPCM }
    private struct State: Sendable {
        var ring: [Block?]
        var head = 0
        var buffered = 0
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
            guard !pcm.samples.isEmpty, pcm.samples.count <= 8192, state.buffered < limit else {
                state.failure = "音频处理未能跟上采集，已停止并保留已接收的音频。"
                state.closed = true
                return
            }
            let tail = (state.head + state.buffered) % state.ring.count
            state.ring[tail] = Block(sequence: state.sequence, pcm: pcm)
            state.buffered += 1
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
            for offset in 0..<state.buffered {
                state.ring[(state.head + offset) % state.ring.count] = nil
            }
            state.head = 0
            state.buffered = 0
            state.sequence = nextSequence
        }
    }

    func peek() -> Block? {
        state.withLock { state in
            guard state.buffered > 0 else { return nil }
            return state.ring[state.head]
        }
    }

    func acknowledge(_ sequence: UInt64) {
        state.withLock { state in
            guard state.buffered > 0, state.ring[state.head]?.sequence == sequence else { return }
            state.ring[state.head] = nil
            state.head = (state.head + 1) % state.ring.count
            state.buffered -= 1
        }
    }

    var error: String? { state.withLock(\.failure) }
    var finalSequence: UInt64 { state.withLock(\.sequence) }
}

public struct CaptureError: LocalizedError {
    private let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
