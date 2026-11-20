import KoeAppleCore
import SwiftUI

enum IOSModeWorkspaceRoute: Hashable {
    case quickNote
    case allDay
    case liveMinutes

    var title: String {
        switch self {
        case .quickNote: CaptureMode.quickNote.title
        case .allDay: CaptureMode.allDay.title
        case .liveMinutes: CaptureMode.meeting.title
        }
    }
}

struct IOSModeWorkspacesView: View {
    let store: HostSessionStore
    let route: IOSModeWorkspaceRoute
    let onSelectRecord: (String) -> Void
    @Environment(IOSFileActions.self) private var files

    @State private var quickNoteFilter: QuickNoteFilterSelection = .all

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                switch route {
                case .quickNote:
                    quickNoteContent
                case .allDay:
                    allDayContent
                case .liveMinutes:
                    liveMinutesContent
                }
            }
            .padding(16)
        }
        .background(IOSColors.bgPanel)
        .navigationTitle(route.title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var quickNoteContent: some View {
        let workspace = store.quickNoteWorkspace
        let filtered = workspace.filteredCards(for: quickNoteFilter)
        return VStack(alignment: .leading, spacing: 12) {
            IOSCard {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("收件箱 \(workspace.inboxCount)  |  共 \(workspace.totalCount) 条")
                            .font(.system(size: AppFontSizes.sm, weight: .semibold))
                            .foregroundStyle(IOSColors.textPrimary)
                        Text(workspace.sourceLabel)
                            .font(.system(size: AppFontSizes.xs))
                            .foregroundStyle(IOSColors.textMuted)
                    }
                    Spacer()
                    IOSBadge(
                        workspace.isActive ? "记录中" : "就绪",
                        tint: workspace.isActive ? IOSColors.success : IOSColors.textSecondary
                    )
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    filterChip("全部", active: quickNoteFilter == .all) {
                        quickNoteFilter = .all
                    }
                    filterChip("收件箱 (\(workspace.inboxCount))", active: quickNoteFilter == .inbox) {
                        quickNoteFilter = .inbox
                    }
                    ForEach(workspace.projects) { project in
                        filterChip(
                            "\(project.name) (\(project.count))",
                            active: quickNoteFilter == .project(project.name)
                        ) {
                            quickNoteFilter = .project(project.name)
                        }
                    }
                }
            }

            if filtered.isEmpty {
                IOSEmptyState(
                    icon: "bolt.horizontal",
                    title: "暂无随心闪记",
                    detail: "可在今天页输入文字闪记，或通过麦克风记录想法。"
                )
            } else {
                ForEach(filtered) { card in
                    Button {
                        store.send(.selectQuickNoteRecord(recordId: card.id))
                        onSelectRecord(card.id)
                    } label: {
                        IOSCard {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(card.title)
                                        .font(.system(size: AppFontSizes.sm, weight: .semibold))
                                        .foregroundStyle(IOSColors.textPrimary)
                                        .lineLimit(1)
                                    Spacer()
                                    if let project = card.project, !project.isEmpty {
                                        IOSBadge(project, tint: IOSColors.textSecondary)
                                    }
                                }
                                if let gist = card.gist, !gist.isEmpty {
                                    Text(gist)
                                        .font(.system(size: AppFontSizes.xs))
                                        .foregroundStyle(IOSColors.textSecondary)
                                        .lineLimit(2)
                                }
                                Text("\(TimeLabel.date(card.createdAtEpochSec))  |  \(card.status)")
                                    .font(.system(size: AppFontSizes.xs))
                                    .foregroundStyle(IOSColors.textMuted)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var allDayContent: some View {
        let workspace = store.allDayWorkspace
        return VStack(alignment: .leading, spacing: 12) {
            IOSCard {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(workspace.selectedDate)
                            .font(.system(size: AppFontSizes.md, weight: .semibold))
                            .foregroundStyle(IOSColors.textPrimary)
                        Spacer()
                        IOSBadge(
                            workspace.isActive ? (workspace.isPaused ? "已暂停" : "记录中") : "待机",
                            tint: workspace.isActive ? IOSColors.success : IOSColors.textSecondary
                        )
                    }
                    Text("事件 \(workspace.eventCount)  |  已录 \(TimeLabel.duration(workspace.totalRecordedMs))  |  空档 \(workspace.gapCount)")
                        .font(.system(size: AppFontSizes.xs))
                        .foregroundStyle(IOSColors.textMuted)
                        .monospacedDigit()
                    IOSPrimaryButton("导出当日 Markdown", systemImage: "square.and.arrow.up", isPrimary: false) {
                        files.exportWorkspace(.forAllDay(date: workspace.selectedDate))
                    }
                    .accessibilityIdentifier("all-day-export-markdown")
                }
            }

            if !workspace.availableDates.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(workspace.availableDates, id: \.self) { day in
                            filterChip(day, active: day == workspace.selectedDate) {
                                store.send(.selectAllDayDate(date: day))
                            }
                        }
                    }
                }
            }

            if workspace.spans.isEmpty {
                IOSEmptyState(
                    icon: "clock",
                    title: "当日暂无时间线",
                    detail: "全天听记会按对话事件与空档自动整理当日回顾。"
                )
            } else {
                ForEach(workspace.spans) { span in
                    IOSCard {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(span.title ?? (span.kind == "pause" ? "暂停区间" : "未录音空档"))
                                    .font(.system(size: AppFontSizes.sm, weight: .semibold))
                                    .foregroundStyle(IOSColors.textPrimary)
                                Spacer()
                                if let sliceBadge = span.sliceBadgeText {
                                    IOSBadge(sliceBadge, tint: IOSColors.textSecondary)
                                }
                            }
                            Text(span.statusSummaryLabel)
                                .font(.system(size: AppFontSizes.xs))
                                .foregroundStyle(IOSColors.textMuted)
                            if !span.preview.isEmpty {
                                Text(span.preview)
                                    .font(.system(size: AppFontSizes.xs))
                                    .foregroundStyle(IOSColors.textSecondary)
                                    .lineLimit(3)
                            }
                            if let recordId = span.primaryRecordId ?? span.recordId {
                                IOSPrimaryButton("打开记录", isPrimary: false) {
                                    onSelectRecord(recordId)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private var liveMinutesContent: some View {
        let workspace = store.liveMinutesWorkspace
        let sections = workspace.finalSections.isEmpty ? workspace.liveSections : workspace.finalSections
        let keyedSections = SummarySectionItem.keyed(sections)

        return VStack(alignment: .leading, spacing: 12) {
            IOSCard {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(workspace.selectedTitle ?? "实时会议纪要")
                            .font(.system(size: AppFontSizes.md, weight: .semibold))
                            .foregroundStyle(IOSColors.textPrimary)
                        Text(workspace.sourceLabel)
                            .font(.system(size: AppFontSizes.xs))
                            .foregroundStyle(IOSColors.textMuted)
                    }
                    Spacer()
                    IOSBadge(
                        workspace.phaseBadgeLabel,
                        tint: workspace.isActive ? IOSColors.success : IOSColors.textSecondary
                    )
                }
            }

            IOSLiveMinutesCoverageSlotView(store: store)

            if !keyedSections.isEmpty {
                ForEach(keyedSections) { item in
                    IOSCard {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(item.section.title)
                                .font(.system(size: AppFontSizes.sm, weight: .semibold))
                                .foregroundStyle(IOSColors.textPrimary)
                            Text(item.section.text)
                                .font(.system(size: AppFontSizes.xs))
                                .foregroundStyle(IOSColors.textSecondary)
                        }
                    }
                }
            } else if workspace.segments.isEmpty {
                IOSEmptyState(
                    icon: "waveform.path.ecg",
                    title: "暂无实时纪要",
                    detail: "开始实时纪要后，将边听边整理议题与待办。"
                )
            }

            if !workspace.pastMeetings.isEmpty {
                Text("往期会议")
                    .font(.system(size: AppFontSizes.sm, weight: .semibold))
                    .foregroundStyle(IOSColors.textPrimary)
                ForEach(workspace.pastMeetings) { meeting in
                    Button {
                        store.send(.selectLiveMinutesRecord(recordId: meeting.id))
                        onSelectRecord(meeting.id)
                    } label: {
                        IOSCard {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(meeting.title)
                                        .font(.system(size: AppFontSizes.sm, weight: .semibold))
                                        .foregroundStyle(IOSColors.textPrimary)
                                    Text("\(TimeLabel.duration(meeting.durationMs))  |  \(meeting.segmentCount) 段原文")
                                        .font(.system(size: AppFontSizes.xs))
                                        .foregroundStyle(IOSColors.textMuted)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.system(size: AppFontSizes.xs))
                                    .foregroundStyle(IOSColors.textMuted)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func filterChip(_ title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: AppFontSizes.xs, weight: active ? .semibold : .medium))
                .foregroundStyle(active ? IOSColors.onAccent : IOSColors.textSecondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(active ? IOSColors.accent : IOSColors.surface1, in: Capsule())
                .overlay(Capsule().stroke(active ? IOSColors.accent : IOSColors.border, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
