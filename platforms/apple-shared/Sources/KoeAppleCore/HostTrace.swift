import Foundation

public struct HostTraceEntry: Codable, Equatable, Sendable {
    public let kind: String
    public let name: String
    public let generation: UInt64
    public let section: String
    public let hasError: Bool
    public let timestampEpochMs: UInt64

    public init(
        kind: String,
        name: String,
        generation: UInt64,
        section: String,
        hasError: Bool,
        timestampEpochMs: UInt64
    ) {
        self.kind = kind
        self.name = name
        self.generation = generation
        self.section = section
        self.hasError = hasError
        self.timestampEpochMs = timestampEpochMs
    }
}

struct HostTraceRingBuffer: Sendable {
    private let capacity: Int
    private(set) var entries: [HostTraceEntry] = []

    init(capacity: Int = 20) {
        self.capacity = max(1, capacity)
    }

    mutating func append(_ entry: HostTraceEntry) {
        entries.append(entry)
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }
    }

    func exportJSON() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(entries),
              let text = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return text
    }
}
