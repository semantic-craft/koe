import Foundation

public enum RecordSortOrder: String, CaseIterable, Identifiable, Sendable {
    case newest
    case oldest
    case longest
    case shortest
    case title

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .newest: "最新优先"
        case .oldest: "最早优先"
        case .longest: "时长最长"
        case .shortest: "时长最短"
        case .title: "标题排序"
        }
    }

    public func sort(_ records: [RecordSnapshot]) -> [RecordSnapshot] {
        records.sorted { lhs, rhs in
            switch self {
            case .newest:
                if lhs.createdAtEpochSec != rhs.createdAtEpochSec {
                    return lhs.createdAtEpochSec > rhs.createdAtEpochSec
                }
                return lhs.id < rhs.id
            case .oldest:
                if lhs.createdAtEpochSec != rhs.createdAtEpochSec {
                    return lhs.createdAtEpochSec < rhs.createdAtEpochSec
                }
                return lhs.id < rhs.id
            case .longest:
                if lhs.durationMs != rhs.durationMs {
                    return lhs.durationMs > rhs.durationMs
                }
                return lhs.createdAtEpochSec > rhs.createdAtEpochSec
            case .shortest:
                if lhs.durationMs != rhs.durationMs {
                    return lhs.durationMs < rhs.durationMs
                }
                return lhs.createdAtEpochSec > rhs.createdAtEpochSec
            case .title:
                let cmp = lhs.title.localizedStandardCompare(rhs.title)
                if cmp != .orderedSame {
                    return cmp == .orderedAscending
                }
                return lhs.createdAtEpochSec > rhs.createdAtEpochSec
            }
        }
    }
}

public enum RecordProjectFilter: Equatable, Hashable, Sendable {
    case all
    case unassigned
    case project(String)

    public var title: String {
        switch self {
        case .all: "全部项目"
        case .unassigned: "未归类"
        case let .project(name): name
        }
    }
}

extension RecordSnapshot {
    public var canTrash: Bool {
        !archived && status != "转写中" && status != "整理中"
    }

    public func matches(
        filter: RecordFilterCategory,
        projectFilter: RecordProjectFilter,
        query: String
    ) -> Bool {
        guard matches(filter: filter, query: query) else { return false }
        let normalizedProject = project?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        switch projectFilter {
        case .all:
            return true
        case .unassigned:
            return normalizedProject.isEmpty
        case let .project(name):
            return normalizedProject == name
        }
    }
}

public enum RecordListFormatting {
    public static func totalDurationLabel(ms: UInt64) -> String? {
        guard ms > 0 else { return nil }
        let totalSec = ms / 1000
        let hours = totalSec / 3600
        let minutes = (totalSec % 3600) / 60
        let seconds = totalSec % 60
        if hours > 0 {
            return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }

    public static func distinctProjects(from records: [RecordSnapshot]) -> [String] {
        var counts: [String: Int] = [:]
        for record in records {
            if let raw = record.project?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
                counts[raw, default: 0] += 1
            }
        }
        return counts.keys.sorted { lhs, rhs in
            let lc = counts[lhs, default: 0]
            let rc = counts[rhs, default: 0]
            if lc != rc { return lc > rc }
            return lhs.localizedStandardCompare(rhs) == .orderedAscending
        }
    }
}
