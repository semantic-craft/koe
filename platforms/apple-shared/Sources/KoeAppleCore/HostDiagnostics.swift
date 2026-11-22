import Foundation
import os
import OSLog

public enum HostDiagnosticLevel: String, Codable, Equatable, Sendable {
    case info
    case warning
    case error
}

public struct HostDiagnosticEntry: Codable, Equatable, Sendable {
    public let timestampEpochMs: UInt64
    public let level: String
    public let category: String
    public let event: String
    public let detail: String
    public let errorCode: String?

    public init(
        timestampEpochMs: UInt64,
        level: String,
        category: String,
        event: String,
        detail: String,
        errorCode: String? = nil
    ) {
        self.timestampEpochMs = timestampEpochMs
        self.level = level
        self.category = category
        self.event = event
        self.detail = detail
        self.errorCode = errorCode
    }
}

public final class HostDiagnosticLog: Sendable {
    public static let shared = HostDiagnosticLog()
    public static let defaultMaxCapacity = 200
    public static let maxDetailUTF8Bytes = 300

    private static let jsonAuthorizationRegex = try? NSRegularExpression(
        pattern: #"(?i)"authorization"\s*:\s*"[^"]*(?:"|$)"#
    )
    private static let kvAuthorizationRegex = try? NSRegularExpression(
        pattern: #"(?i)\bauthorization\s*([:=])\s*(?:"[^"]*(?:"|$)|'[^']*(?:'|$)|(?:[A-Za-z][A-Za-z0-9_-]*[ \t]+)?[^\s,;&}"'\]]+)"#
    )
    private static let bearerRegex = try? NSRegularExpression(
        pattern: #"(?i)\bBearer\s+[A-Za-z0-9._~+/=-]+"#
    )
    private static let apiKeyTokenRegex = try? NSRegularExpression(
        pattern: #"(?<![A-Za-z0-9])sk-[A-Za-z0-9_.-]+"#
    )
    private static let jsonSecretRegex = try? NSRegularExpression(
        pattern: #"(?i)"([A-Za-z0-9_.-]*(?:api[_-]?key|token|secret|password|private[_-]?key))"\s*:\s*"[^"]*(?:"|$)"#
    )
    private static let kvSecretRegex = try? NSRegularExpression(
        pattern: #"(?i)(?<![A-Za-z0-9_.-])(["']?)([A-Za-z0-9_.-]*(?:api[_-]?key|token|secret|password|private[_-]?key))\1\s*([:=])\s*(?:"(?!\[REDACTED\]")[^"]*(?:"|$)|'[^']*(?:'|$)|[^\s,;&}\]]+)"#
    )

    private struct State: Sendable {
        var entries: [HostDiagnosticEntry] = []
    }

    private let maxCapacity: Int
    private let subsystem: String
    private let sink: (@Sendable (HostDiagnosticEntry) -> Void)?
    private let state = OSAllocatedUnfairLock(initialState: State())

    public init(
        maxCapacity: Int = defaultMaxCapacity,
        subsystem: String = "com.semanticcraft.koe",
        sink: (@Sendable (HostDiagnosticEntry) -> Void)? = nil
    ) {
        self.maxCapacity = max(1, maxCapacity)
        self.subsystem = subsystem
        self.sink = sink
    }

    public func recentEntries() -> [HostDiagnosticEntry] {
        state.withLock(\.entries)
    }

    public func clear() {
        state.withLock { $0.entries.removeAll() }
    }

    @discardableResult
    public func record(
        level: HostDiagnosticLevel,
        category: String,
        event: String,
        detail: String,
        errorCode: String? = nil
    ) -> HostDiagnosticEntry {
        let sanitizedDetail = Self.redact(detail)
        let sanitizedCode = errorCode.map { Self.redact($0) }
        let timestampEpochMs = UInt64(max(0, Date().timeIntervalSince1970 * 1000))
        let entry = HostDiagnosticEntry(
            timestampEpochMs: timestampEpochMs,
            level: level.rawValue,
            category: category,
            event: event,
            detail: sanitizedDetail,
            errorCode: sanitizedCode
        )
        state.withLock { box in
            box.entries.append(entry)
            if box.entries.count > maxCapacity {
                box.entries.removeFirst(box.entries.count - maxCapacity)
            }
        }
        emitToOSLog(entry, level: level)
        sink?(entry)
        return entry
    }

    @discardableResult
    public func info(
        category: String,
        event: String,
        detail: String = "",
        errorCode: String? = nil
    ) -> HostDiagnosticEntry {
        record(level: .info, category: category, event: event, detail: detail, errorCode: errorCode)
    }

    @discardableResult
    public func warning(
        category: String,
        event: String,
        detail: String,
        errorCode: String? = nil
    ) -> HostDiagnosticEntry {
        record(level: .warning, category: category, event: event, detail: detail, errorCode: errorCode)
    }

    @discardableResult
    public func warning(
        category: String,
        event: String,
        detailPrefix: String = "",
        error: any Error
    ) -> HostDiagnosticEntry {
        record(
            level: .warning,
            category: category,
            event: event,
            detail: "\(detailPrefix)\(Self.describe(error: error))",
            errorCode: Self.errorCode(for: error)
        )
    }

    @discardableResult
    public func error(
        category: String,
        event: String,
        detail: String,
        errorCode: String? = nil
    ) -> HostDiagnosticEntry {
        record(level: .error, category: category, event: event, detail: detail, errorCode: errorCode)
    }

    @discardableResult
    public func error(
        category: String,
        event: String,
        detailPrefix: String = "",
        error: any Error
    ) -> HostDiagnosticEntry {
        record(
            level: .error,
            category: category,
            event: event,
            detail: "\(detailPrefix)\(Self.describe(error: error))",
            errorCode: Self.errorCode(for: error)
        )
    }

    public static func redact(_ text: String) -> String {
        var result = text
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
        result = replacingMatches(in: result, regex: jsonAuthorizationRegex, template: "\"authorization\":\"[REDACTED]\"")
        result = replacingMatches(in: result, regex: kvAuthorizationRegex, template: "Authorization$1 [REDACTED]")
        result = replacingMatches(in: result, regex: bearerRegex, template: "Bearer [REDACTED]")
        result = replacingMatches(in: result, regex: apiKeyTokenRegex, template: "[REDACTED]")
        result = replacingMatches(in: result, regex: jsonSecretRegex, template: "\"$1\":\"[REDACTED]\"")
        result = replacingMatches(in: result, regex: kvSecretRegex, template: "$1$2$1$3[REDACTED]")
        return truncateUTF8(result, maxBytes: maxDetailUTF8Bytes)
    }

    public static func describe(error: any Error) -> String {
        let raw: String
        switch error {
        case let DecodingError.keyNotFound(key, context):
            let path = formatCodingPath(context.codingPath, appending: key)
            raw = "keyNotFound path=\(path)"
        case let DecodingError.typeMismatch(type, context):
            let path = formatCodingPath(context.codingPath)
            raw = "typeMismatch expected=\(String(describing: type)) path=\(path)"
        case let DecodingError.valueNotFound(type, context):
            let path = formatCodingPath(context.codingPath)
            raw = "valueNotFound expected=\(String(describing: type)) path=\(path)"
        case let DecodingError.dataCorrupted(context):
            let path = formatCodingPath(context.codingPath)
            let underlying = context.underlyingError.map { " underlying=\(describe(error: $0))" } ?? ""
            raw = "dataCorrupted path=\(path) detail=\(redact(context.debugDescription))\(underlying)"
        case let EncodingError.invalidValue(_, context):
            let path = formatCodingPath(context.codingPath)
            raw = "invalidValue path=\(path) detail=\(redact(context.debugDescription))"
        default:
            let nsError = error as NSError
            raw = "domain=\(nsError.domain) code=\(nsError.code) detail=\(redact(error.localizedDescription))"
        }
        return redact(raw)
    }

    public static func errorCode(for error: any Error) -> String {
        switch error {
        case DecodingError.keyNotFound:
            return "decoding_key_not_found"
        case DecodingError.typeMismatch:
            return "decoding_type_mismatch"
        case DecodingError.valueNotFound:
            return "decoding_value_not_found"
        case DecodingError.dataCorrupted:
            return "decoding_data_corrupted"
        case EncodingError.invalidValue:
            return "encoding_invalid_value"
        default:
            let nsError = error as NSError
            return "\(nsError.domain):\(nsError.code)"
        }
    }

    private func emitToOSLog(_ entry: HostDiagnosticEntry, level: HostDiagnosticLevel) {
        let logger = Logger(subsystem: subsystem, category: entry.category)
        let codePart = entry.errorCode.map { " code=\($0)" } ?? ""
        switch level {
        case .info:
            logger.info("\(entry.event, privacy: .public)\(codePart, privacy: .public) \(entry.detail, privacy: .public)")
        case .warning:
            logger.warning("\(entry.event, privacy: .public)\(codePart, privacy: .public) \(entry.detail, privacy: .public)")
        case .error:
            logger.error("\(entry.event, privacy: .public)\(codePart, privacy: .public) \(entry.detail, privacy: .public)")
        }
    }

    private static func formatCodingPath(_ codingPath: [any CodingKey], appending extra: (any CodingKey)? = nil) -> String {
        let keys = extra.map { codingPath + [$0] } ?? codingPath
        guard !keys.isEmpty else { return "<root>" }
        var output = ""
        for key in keys {
            if let index = key.intValue {
                output += "[\(index)]"
            } else {
                if !output.isEmpty { output += "." }
                output += key.stringValue
            }
        }
        return output
    }

    private static func replacingMatches(
        in input: String,
        regex: NSRegularExpression?,
        template: String
    ) -> String {
        guard let regex else { return input }
        let range = NSRange(input.startIndex..<input.endIndex, in: input)
        return regex.stringByReplacingMatches(in: input, range: range, withTemplate: template)
    }

    private static func truncateUTF8(_ text: String, maxBytes: Int) -> String {
        guard text.utf8.count > maxBytes else { return text }
        let ellipsis = "..."
        let limit = max(0, maxBytes - ellipsis.utf8.count)
        var kept = ""
        var used = 0
        for character in text {
            let bytes = character.utf8.count
            if used + bytes > limit { break }
            kept.append(character)
            used += bytes
        }
        return kept + ellipsis
    }
}
