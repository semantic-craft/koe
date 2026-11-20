import Foundation

/// Canonical navigation sections shared across the sidebar, root header, and macOS status menu.
public enum HostSection: String, CaseIterable, Sendable {
    case today
    case notes
    case allDay = "all_day"
    case liveMinutes = "live_minutes"
    case ask
    case records
    case tasks
    case memory
    case settings
    case capture
    case trash
    case detail

    /// Ordered top-level items displayed in the sidebar and macOS menu bar menu.
    public static let menuSections: [HostSection] = [
        .today, .notes, .allDay, .liveMinutes, .ask, .records, .tasks, .settings
    ]

    public var title: String {
        switch self {
        case .today: "模式选择"
        case .notes: CaptureMode.quickNote.title
        case .allDay: CaptureMode.allDay.title
        case .liveMinutes: CaptureMode.meeting.title
        case .ask: "问 AI"
        case .records: "所有记录"
        case .tasks: "行动"
        case .memory: "记忆"
        case .settings: "模型设置"
        case .capture: "录音管理"
        case .trash: "回收站"
        case .detail: "记录"
        }
    }

    public var icon: String {
        switch self {
        case .today: "square.grid.2x2"
        case .notes: "bolt.horizontal"
        case .allDay: "clock"
        case .liveMinutes: "waveform.path.ecg"
        case .ask: "bubble.left.and.text.bubble.right"
        case .records: "tray.full"
        case .tasks: "checklist"
        case .memory: "brain"
        case .settings: "slider.horizontal.3"
        case .capture: "mic"
        case .trash: "trash"
        case .detail: "doc.text"
        }
    }

    public static func title(for rawSection: String, detailTitle: String? = nil) -> String {
        guard let section = HostSection(rawValue: rawSection) else {
            return HostSection.today.title
        }
        if section == .detail {
            return detailTitle ?? section.title
        }
        return section.title
    }
}
