import Foundation

public struct WorkspaceExportRequest: Equatable, Sendable {
    public var recordId: String?
    public var date: String?
    public var suggestedFilename: String
    public var includeAnalysis: Bool
    public var includeSources: Bool

    public init(
        recordId: String? = nil,
        date: String? = nil,
        suggestedFilename: String,
        includeAnalysis: Bool = true,
        includeSources: Bool = true
    ) {
        self.recordId = recordId
        self.date = date
        self.suggestedFilename = suggestedFilename
        self.includeAnalysis = includeAnalysis
        self.includeSources = includeSources
    }

    public static func forQuickNote(
        _ card: QuickNoteCardSnapshot,
        includeAnalysis: Bool = true,
        includeSources: Bool = true
    ) -> WorkspaceExportRequest {
        let baseTitle = card.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let sanitized = (baseTitle.isEmpty ? "随心闪记" : baseTitle)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        return WorkspaceExportRequest(
            recordId: card.id,
            date: nil,
            suggestedFilename: "\(sanitized).md",
            includeAnalysis: includeAnalysis,
            includeSources: includeSources
        )
    }

    public static func forAllDay(
        date: String,
        includeAnalysis: Bool = true,
        includeSources: Bool = true
    ) -> WorkspaceExportRequest {
        let safeDate = date.replacingOccurrences(of: "/", with: "-")
        return WorkspaceExportRequest(
            recordId: nil,
            date: date,
            suggestedFilename: "全天听记-\(safeDate).md",
            includeAnalysis: includeAnalysis,
            includeSources: includeSources
        )
    }

    public static func forMeeting(
        recordId: String,
        title: String?,
        includeAnalysis: Bool = true,
        includeSources: Bool = true
    ) -> WorkspaceExportRequest {
        let raw = (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let sanitized = (raw.isEmpty ? "实时纪要" : raw)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        return WorkspaceExportRequest(
            recordId: recordId,
            date: nil,
            suggestedFilename: "\(sanitized).md",
            includeAnalysis: includeAnalysis,
            includeSources: includeSources
        )
    }

    public func commandPayload(path: String) -> [String: Any] {
        var payload: [String: Any] = [
            "path": path,
            "includeAnalysis": includeAnalysis,
            "includeSources": includeSources
        ]
        if let recordId { payload["recordId"] = recordId }
        if let date { payload["date"] = date }
        return payload
    }
}

public enum QuickNoteFilterSelection: Equatable, Sendable {
    case all
    case inbox
    case project(String)
}

public enum RecordFilterCategory: String, CaseIterable, Identifiable, Sendable {
    case all
    case quickNote
    case inbox
    case allDay
    case meeting
    case archived

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .all: "全部"
        case .quickNote: "随心闪记"
        case .inbox: "收件箱"
        case .allDay: "全天听记"
        case .meeting: "实时纪要"
        case .archived: "已归档"
        }
    }
}

extension RecordSnapshot {
    public var effectiveMode: String {
        if let mode, !mode.isEmpty { return mode }
        return runId != nil ? "all_day" : "quick_note"
    }

    public var modeLabel: String {
        switch effectiveMode {
        case "all_day": "全天听记"
        case "meeting": "实时纪要"
        case "dictation": "语音输入"
        default: "随心闪记"
        }
    }

    public var isQuickNoteInbox: Bool {
        effectiveMode == "quick_note"
            && (project?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            && !archived
    }

    public func matches(filter: RecordFilterCategory, query: String) -> Bool {
        let passesCategory: Bool = switch filter {
        case .all: true
        case .quickNote: effectiveMode == "quick_note"
        case .inbox: isQuickNoteInbox
        case .allDay: effectiveMode == "all_day"
        case .meeting: effectiveMode == "meeting"
        case .archived: archived
        }
        guard passesCategory else { return false }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        return title.localizedCaseInsensitiveContains(trimmed)
            || preview.localizedCaseInsensitiveContains(trimmed)
            || source.localizedCaseInsensitiveContains(trimmed)
            || (project?.localizedCaseInsensitiveContains(trimmed) == true)
    }
}

extension RecordDetailSnapshot {
    public var modeLabel: String {
        switch mode ?? "quick_note" {
        case "all_day": "全天听记"
        case "meeting": "实时纪要"
        case "dictation": "语音输入"
        default: "随心闪记"
        }
    }
}

public struct ModeWorkspacesSnapshot: Codable, Equatable, Sendable {
    public let picker: ModePickerSnapshot
    public let quickNote: QuickNoteWorkspaceSnapshot
    public let allDay: AllDayWorkspaceSnapshot
    public let liveMinutes: LiveMinutesWorkspaceSnapshot
    public let voiceInput: VoiceInputWorkspaceSnapshot

    public static let empty = ModeWorkspacesSnapshot(
        picker: .empty,
        quickNote: .empty,
        allDay: .empty,
        liveMinutes: .empty,
        voiceInput: .empty
    )
}

public struct ModePickerSnapshot: Codable, Equatable, Sendable {
    public let sourceLabel: String
    public let sourceBadge: String
    public let cards: [ModePickerCardSnapshot]

    public static let defaultCards: [ModePickerCardSnapshot] = [
        ModePickerCardSnapshot(
            id: "notes",
            mode: "quick_note",
            title: "随心闪记",
            subtitle: "想到就记，原文优先，收件箱与项目自由归类",
            isSessionActive: false,
            canToggleSession: true,
            statusBadge: "就绪",
            metricText: "共 0 条闪记，收件箱 0 条"
        ),
        ModePickerCardSnapshot(
            id: "all_day",
            mode: "all_day",
            title: "全天听记",
            subtitle: "按事件回看全天对话，自动标记暂停与未录音空档",
            isSessionActive: false,
            canToggleSession: true,
            statusBadge: "待开启",
            metricText: "今日 0 个事件，已录 0 分钟"
        ),
        ModePickerCardSnapshot(
            id: "live_minutes",
            mode: "meeting",
            title: "实时纪要",
            subtitle: "边听边整理议题与待办，会后核对完整纪要",
            isSessionActive: false,
            canToggleSession: true,
            statusBadge: "就绪",
            metricText: "往期会议 0 场"
        ),
        ModePickerCardSnapshot(
            id: "voice_input",
            mode: "dictation",
            title: "语音输入",
            subtitle: "录音豆待命流桥接光标听写，一步步检查可用状态",
            isSessionActive: false,
            canToggleSession: true,
            statusBadge: "未开启",
            metricText: "等待录音豆连接"
        )
    ]

    public static let empty = ModePickerSnapshot(
        sourceLabel: "系统默认麦克风",
        sourceBadge: "系统默认",
        cards: defaultCards
    )
}

public struct ModePickerCardSnapshot: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let mode: String
    public let title: String
    public let subtitle: String
    public let isSessionActive: Bool
    public let canToggleSession: Bool
    public let statusBadge: String
    public let metricText: String
}

public struct QuickNoteProjectCountSnapshot: Codable, Equatable, Identifiable, Sendable {
    public var id: String { name }
    public let name: String
    public let count: Int
}

public struct QuickNoteTopicSnapshot: Codable, Equatable, Identifiable, Sendable {
    public var id: String { "\(title):\(summary)" }
    public let title: String
    public let summary: String
    public let sources: [SourceSnapshot]
}

public struct WorkspaceSourcedItemSnapshot: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let kind: String
    public let text: String
    public let state: String
    public let completed: Bool
    public let due: String?
    public let sources: [SourceSnapshot]
}

public struct QuickNoteCardSnapshot: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let createdAtEpochSec: UInt64
    public let durationMs: UInt64
    public let source: String
    public let status: String
    public let archived: Bool
    public let project: String?
    public let isInbox: Bool
    public let minutesStale: Bool
    public let canSummarize: Bool
    public let segments: [SegmentSnapshot]
    public let gist: String?
    public let topics: [QuickNoteTopicSnapshot]
    public let nextSteps: [WorkspaceSourcedItemSnapshot]
}

public struct QuickNoteWorkspaceSnapshot: Codable, Equatable, Sendable {
    public let isActive: Bool
    public let sourceLabel: String
    public let inboxCount: Int
    public let totalCount: Int
    public let projects: [QuickNoteProjectCountSnapshot]
    public let selectedRecordId: String?
    public let mcpReadNote: String
    public let cards: [QuickNoteCardSnapshot]

    public static let empty = QuickNoteWorkspaceSnapshot(
        isActive: false,
        sourceLabel: "系统默认麦克风",
        inboxCount: 0,
        totalCount: 0,
        projects: [],
        selectedRecordId: nil,
        mcpReadNote: "外部 Agent 可通过只读 MCP 检索已保存闪记原文与已采纳行动，不会自动改写记录。",
        cards: []
    )

    public func filteredCards(for filter: QuickNoteFilterSelection) -> [QuickNoteCardSnapshot] {
        switch filter {
        case .all:
            return cards
        case .inbox:
            return cards.filter(\.isInbox)
        case .project(let name):
            return cards.filter { $0.project == name }
        }
    }

    public func resolvedSelectedCard(for filter: QuickNoteFilterSelection) -> QuickNoteCardSnapshot? {
        let visible = filteredCards(for: filter)
        if let selectedRecordId, let matched = visible.first(where: { $0.id == selectedRecordId }) {
            return matched
        }
        return visible.first
    }
}

extension HostSessionStore {
    public func toggleModeSession(_ card: ModePickerCardSnapshot) {
        if card.id == "voice_input" || card.mode == "dictation" {
            send("set_voice_input_session", [
                "enabled": !card.isSessionActive,
                "openResponsay": false
            ])
        } else if card.isSessionActive {
            send("capture_action", ["action": "end"])
        } else {
            send("start_capture_mode", [
                "mode": card.mode,
                "stayOnPage": true
            ])
        }
        NotificationCenter.default.post(name: Notification.Name("KoeFlushBleOutbound"), object: nil)
    }

    public func performVoiceInputStepAction(_ command: String) {
        switch command {
        case "enable_voice_input", "set_voice_input_session":
            send("set_voice_input_session", [
                "enabled": true,
                "openResponsay": false
            ])
            NotificationCenter.default.post(name: Notification.Name("KoeFlushBleOutbound"), object: nil)
        case "open_responsay_app":
            send("open_responsay_app")
        case "device_open_guide":
            send("device_open_guide")
        default:
            break
        }
    }
}
