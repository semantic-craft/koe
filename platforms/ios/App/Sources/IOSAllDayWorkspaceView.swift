import KoeAppleCore
import SwiftUI

struct IOSAllDayWorkspaceView: View {
    let store: HostSessionStore
    let onSelectRecord: (String) -> Void
    let onOpenSource: (SourceSnapshot) -> Void
    private var workspace: AllDayWorkspaceSnapshot { store.allDayWorkspace }

    var body: some View {
        IOSWorkspaceCaptureHeader(store: store, mode: .allDay, title: workspace.selectedDate,
                                  source: workspace.sourceLabel, status: workspace.isActive ? (workspace.isPaused ? "已暂停" : "记录中") : "待机",
                                  isActive: workspace.isActive, canStart: workspace.canStart)
        if !workspace.availableDates.isEmpty {
            Picker("查看日期", selection: Binding(get: { workspace.selectedDate }, set: { store.send(.selectAllDayDate(date: $0)) })) {
                ForEach(workspace.availableDates, id: \.self) { day in Text(day).tag(day) }
            }.pickerStyle(.menu)
        }
        Text("事件 \(workspace.eventCount)  |  已录 \(TimeLabel.duration(workspace.totalRecordedMs))  |  空档 \(workspace.gapCount)")
            .font(.subheadline).foregroundStyle(.secondary)
        IOSCard {
            VStack(alignment: .leading, spacing: 8) {
                Text("当日回顾").font(.headline)
                if let review = workspace.dailyReview {
                    Text(review.overview)
                    ForEach(IOSWorkspaceLine.keyed(review.highlights)) { line in Text("• " + line.text) }
                    IOSWorkspaceSources(sources: review.sources, onOpenSource: onOpenSource)
                } else {
                    Text("当日暂无带原话引用的回顾。").foregroundStyle(.secondary)
                }
            }
        }
        Text("时间线").font(.headline)
        if workspace.spans.isEmpty {
            Text("当日暂无时间线").foregroundStyle(.secondary)
        }
        ForEach(workspace.spans) { span in
            IOSAllDaySpanRow(span: span, onSelectRecord: onSelectRecord, onOpenSource: onOpenSource)
        }
        IOSCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("集中复查").font(.headline)
                ForEach(workspace.reviewTasks) { item in
                    IOSWorkspaceReviewRow(item: item, store: store, onOpenSource: onOpenSource)
                }
                ForEach(workspace.reviewMemories) { item in
                    IOSWorkspaceReviewRow(item: item, store: store, onOpenSource: onOpenSource)
                }
                ForEach(workspace.reviewDecisions) { decision in
                    IOSBadge("决策")
                    Text(decision.text)
                    IOSWorkspaceSources(sources: decision.sources, onOpenSource: onOpenSource)
                }
                if workspace.reviewTasks.isEmpty && workspace.reviewMemories.isEmpty && workspace.reviewDecisions.isEmpty {
                    Text("当日暂无待复查内容。").foregroundStyle(.secondary)
                }
            }
        }
        IOSWorkspaceExport(title: "导出当日 Markdown") { analysis, sources in
            .forAllDay(date: workspace.selectedDate, includeAnalysis: analysis, includeSources: sources)
        }.accessibilityIdentifier("all-day-export-markdown")
    }
}

struct IOSAllDaySpanRow: View {
    let span: AllDaySpanSnapshot
    let onSelectRecord: (String) -> Void
    let onOpenSource: (SourceSnapshot) -> Void

    var body: some View {
        if span.kind == "pause" || span.kind == "unrecorded_gap" {
            Label(span.statusSummaryLabel, systemImage: span.kind == "pause" ? "pause" : "ellipsis")
                .font(.caption).foregroundStyle(.secondary)
                .padding(.horizontal, 12).padding(.vertical, 4)
        } else {
            IOSCard {
                VStack(alignment: .leading, spacing: 8) {
                    Text(span.title ?? "对话片段").font(.headline)
                    Text(span.statusSummaryLabel).font(.caption).monospacedDigit()
                    if let badge = span.sliceBadgeText { IOSBadge(badge) }
                    if !span.speakers.isEmpty { Text(span.speakers.joined(separator: "、")).foregroundStyle(.secondary) }
                    if !span.preview.isEmpty { Text(span.preview) }
                    ForEach(IOSWorkspaceLine.keyed(span.summaryPoints)) { point in Text("• " + point.text) }
                    if let source = span.firstSegment {
                        IOSPrimaryButton("回到原文", isPrimary: false) { onOpenSource(source) }
                    } else if let id = span.primaryRecordId ?? span.recordId {
                        IOSPrimaryButton("打开记录", isPrimary: false) { onSelectRecord(id) }
                    }
                }
            }
        }
    }
}
