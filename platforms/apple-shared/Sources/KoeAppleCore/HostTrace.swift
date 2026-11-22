import Foundation

public struct HostTraceEntry: Codable, Equatable, Sendable {
    public let kind: String
    public let name: String
    public let generation: UInt64
    public let section: String
    public let hasError: Bool
    public let timestampEpochMs: UInt64
    public let errorDetail: String?

    public init(
        kind: String,
        name: String,
        generation: UInt64,
        section: String,
        hasError: Bool,
        timestampEpochMs: UInt64,
        errorDetail: String? = nil
    ) {
        self.kind = kind
        self.name = name
        self.generation = generation
        self.section = section
        self.hasError = hasError
        self.timestampEpochMs = timestampEpochMs
        self.errorDetail = errorDetail
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

    func exportJSON(diagnostics: HostDiagnosticLog = .shared) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        do {
            let data = try encoder.encode(entries)
            guard let text = String(data: data, encoding: .utf8) else {
                diagnostics.error(
                    category: "trace",
                    event: "export_trace_utf8_failed",
                    detail: "encoded trace data was not valid UTF-8",
                    errorCode: "trace_utf8_failed"
                )
                return "[]"
            }
            return text
        } catch {
            diagnostics.error(category: "trace", event: "export_trace_failed", error: error)
            return "[]"
        }
    }
}
