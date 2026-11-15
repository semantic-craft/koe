import Foundation
import KoeAppleShared

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
    let limit: Int
    private let lock = NSLock()
    private var blocks: [Block] = []
    private var sequence: UInt64
    private var closed = false
    private var failure: String?
    init(nextSequence: UInt64, limit: Int = 64) {
        sequence = nextSequence
        self.limit = limit
    }
    func append(_ pcm: CapturedPCM) {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return }
        guard !pcm.samples.isEmpty, pcm.samples.count <= 8192, blocks.count < limit else {
            failure = "音频处理未能跟上采集，已停止并保留已接收的音频。"
            closed = true
            return
        }
        blocks.append(Block(sequence: sequence, pcm: pcm))
        sequence += 1
    }
    func fail(_ message: String) {
        lock.lock(); defer { lock.unlock() }
        failure = failure ?? message
        closed = true
    }
    func close() { lock.lock(); defer { lock.unlock() }; closed = true }
    func discardUnaccepted(nextSequence: UInt64) {
        lock.lock(); defer { lock.unlock() }
        closed = true
        blocks.removeAll()
        sequence = nextSequence
    }
    func peek() -> Block? { lock.lock(); defer { lock.unlock() }; return blocks.first }
    func acknowledge(_ sequence: UInt64) {
        lock.lock(); defer { lock.unlock() }
        if blocks.first?.sequence == sequence { blocks.removeFirst() }
    }
    var error: String? { lock.lock(); defer { lock.unlock() }; return failure }
    var finalSequence: UInt64 { lock.lock(); defer { lock.unlock() }; return sequence }
}
