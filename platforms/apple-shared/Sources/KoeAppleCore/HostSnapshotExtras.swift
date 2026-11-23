import Foundation

public struct ReviewCountsSnapshot: Codable, Equatable, Sendable {
    public let proposedTaskCount: Int
    public let proposedMemoryCount: Int
    public let proposedActionCount: Int
    public let activeMemoryCount: Int

    public init(
        proposedTaskCount: Int = 0,
        proposedMemoryCount: Int = 0,
        proposedActionCount: Int = 0,
        activeMemoryCount: Int = 0
    ) {
        self.proposedTaskCount = proposedTaskCount
        self.proposedMemoryCount = proposedMemoryCount
        self.proposedActionCount = proposedActionCount
        self.activeMemoryCount = activeMemoryCount
    }
}

public struct CaptureSpanSnapshot: Codable, Equatable, Sendable {
    public let epoch: UInt64
    public let startNs: UInt64
    public let sampleOffset: UInt64
    public let sampleCount: UInt64

    public init(epoch: UInt64, startNs: UInt64, sampleOffset: UInt64, sampleCount: UInt64) {
        self.epoch = epoch
        self.startNs = startNs
        self.sampleOffset = sampleOffset
        self.sampleCount = sampleCount
    }
}

public struct CaptureLaneDetailSnapshot: Codable, Equatable, Identifiable, Sendable {
    public var id: String { lane }
    public let lane: String
    public let audioPath: String?
    public let sampleRate: UInt32?
    public let durationMs: UInt64
    public let interruption: String?
    public let timeline: [CaptureSpanSnapshot]

    private enum CodingKeys: String, CodingKey {
        case lane, audioPath, sampleRate, durationMs, interruption, timeline
    }

    public init(
        lane: String,
        audioPath: String? = nil,
        sampleRate: UInt32? = nil,
        durationMs: UInt64 = 0,
        interruption: String? = nil,
        timeline: [CaptureSpanSnapshot] = []
    ) {
        self.lane = lane
        self.audioPath = audioPath
        self.sampleRate = sampleRate
        self.durationMs = durationMs
        self.interruption = interruption
        self.timeline = timeline
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        lane = try c.decode(String.self, forKey: .lane)
        audioPath = try c.decodeIfPresent(String.self, forKey: .audioPath)
        sampleRate = try c.decodeIfPresent(UInt32.self, forKey: .sampleRate)
        durationMs = try c.decodeIfPresent(UInt64.self, forKey: .durationMs) ?? 0
        interruption = try c.decodeIfPresent(String.self, forKey: .interruption)
        timeline = try c.decodeIfPresent([CaptureSpanSnapshot].self, forKey: .timeline) ?? []
    }
}
