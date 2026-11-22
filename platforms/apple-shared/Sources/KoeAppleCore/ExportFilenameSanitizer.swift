import Foundation

public enum ExportFilenameSanitizer {
    public static let defaultFallback = "Koe 记录"
    public static let maxStemUTF8Bytes = 180

    private static let edgePadding = CharacterSet.whitespacesAndNewlines
        .union(CharacterSet(charactersIn: "."))
    private static let invalidCharacters = CharacterSet(charactersIn: "/:\\")
        .union(.controlCharacters)
    private static let trailingTruncationTrim = edgePadding
        .union(CharacterSet(charactersIn: "-"))
    private static let emptyCheckCharacters = invalidCharacters
        .union(trailingTruncationTrim)

    public static func markdownFilename(
        stem: String?,
        fallback: String = defaultFallback
    ) -> String {
        let safeFallback = cleanStem(fallback) ?? defaultFallback
        let safeStem = cleanStem(stem ?? "") ?? safeFallback
        return "\(safeStem).md"
    }

    public static func sanitizeMarkdownFilename(
        _ filename: String,
        fallback: String = defaultFallback
    ) -> String {
        let trimmed = filename.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawStem = trimmed.lowercased().hasSuffix(".md")
            ? String(trimmed.dropLast(3))
            : trimmed
        return markdownFilename(stem: rawStem, fallback: fallback)
    }

    public static func validatedMarkdownFilename(
        _ filename: String,
        fallback: String = defaultFallback
    ) -> String? {
        guard filename.lowercased().hasSuffix(".md") else { return nil }
        return markdownFilename(stem: String(filename.dropLast(3)), fallback: fallback)
    }

    private static func cleanStem(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: edgePadding)
        guard !trimmed.trimmingCharacters(in: emptyCheckCharacters).isEmpty else {
            return nil
        }
        var safe = trimmed
            .components(separatedBy: invalidCharacters)
            .joined(separator: "-")
        if safe.utf8.count > maxStemUTF8Bytes {
            safe = safe.truncatedToUTF8Bytes(maxStemUTF8Bytes)
            while let last = safe.unicodeScalars.last, trailingTruncationTrim.contains(last) {
                safe.unicodeScalars.removeLast()
            }
            guard !safe.trimmingCharacters(in: emptyCheckCharacters).isEmpty else {
                return nil
            }
        }
        return safe
    }
}
