import KoeAppleCore
import SwiftUI

private enum IOSRecordDetailTab: String, CaseIterable, Identifiable {
    case summary = "纪要"
    case transcript = "原文"
    case highlights = "重点"

    var id: String { rawValue }
}

struct IOSRecordDetailView: View {
    let store: HostSessionStore
    let recordId: String
    @Environment(IOSFileActions.self) private var files

    @State private var selectedTab: IOSRecordDetailTab = .summary

    var body: some View {
        let slice = store.recordDetail
        let detail = slice.detail?.id == recordId ? slice.detail : nil
        let fallbackRecord = store.records.first(where: { $0.id == recordId })

        VStack(spacing: 0) {
            Picker("内容视图", selection: $selectedTab) {
                ForEach(IOSRecordDetailTab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(IOSColors.bgPanel)

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if let detail {
                            headerCard(detail)
                            switch selectedTab {
                            case .summary:
                                summarySection(detail, slice: slice)
                            case .transcript:
                                VStack(alignment: .leading, spacing: 14) {
                                    transcriptSection(detail, focusSegmentId: focusTarget)
                                }
                                .onChange(of: focusTarget, initial: true) {
                                    if let focusTarget { proxy.scrollTo(focusTarget, anchor: .center) }
                                }
                            case .highlights:
                                highlightsSection(detail)
                            }
                        } else if let record = fallbackRecord {
                            IOSCard {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(record.title)
                                        .font(.system(size: AppFontSizes.lg, weight: .semibold))
                                        .foregroundStyle(IOSColors.textPrimary)
                                    Text(record.preview.isEmpty ? "正在读取记录详情…" : record.preview)
                                        .font(.system(size: AppFontSizes.sm))
                                        .foregroundStyle(IOSColors.textSecondary)
                                }
                            }
                        } else {
                            IOSEmptyState(
                                icon: "doc.text",
                                title: "未找到记录详情",
                                detail: "该记录可能已移入回收站。"
                            )
                        }
                    }
                    .padding(16)
                }
                .background(IOSColors.bgPanel)
            }

            IOSPlayerBarView(store: store, recordId: recordId)
        }
        .navigationTitle(detail?.title ?? fallbackRecord?.title ?? "记录详情")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: focusTarget) {
            if focusTarget != nil { selectedTab = .transcript }
        }
        .onAppear {
            if focusTarget != nil { selectedTab = .transcript }
            if store.recordDetail.detail?.id != recordId {
                store.send(.selectRecord(recordId: recordId))
            }
        }
    }

    var focusTarget: String? {
        let slice = store.recordDetail
        guard let detail = slice.detail, detail.id == recordId, let id = slice.focusSegmentId,
              !id.isEmpty, detail.segments.contains(where: { $0.id == id }) else { return nil }
        return id
    }

    private func headerCard(_ detail: RecordDetailSnapshot) -> some View {
        IOSCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    IOSBadge(detail.modeLabel, tint: IOSColors.accent)
                    IOSBadge(detail.status, tint: IOSColors.textSecondary)
                    Spacer()
                    Text(TimeLabel.duration(detail.durationMs))
                        .font(.system(size: AppFontSizes.xs, weight: .medium))
                        .foregroundStyle(IOSColors.textMuted)
                        .monospacedDigit()
                }
                Text(detail.title)
                    .font(.system(size: AppFontSizes.lg, weight: .semibold))
                    .foregroundStyle(IOSColors.textPrimary)
                Text("\(TimeLabel.date(detail.createdAtEpochSec))  |  \(detail.source)  |  \(detail.segments.count) 段原文")
                    .font(.system(size: AppFontSizes.xs))
                    .foregroundStyle(IOSColors.textMuted)
                HStack(spacing: 8) {
                    if detail.canRetranscribe {
                        IOSPrimaryButton("重新转写", isPrimary: false) {
                            store.send(.transcribe(recordId: detail.id))
                        }
                    }
                    IOSPrimaryButton("整理纪要", isPrimary: false) {
                        store.send(.summarize(recordId: detail.id))
                    }
                    IOSPrimaryButton(detail.archived ? "取消归档" : "归档", isPrimary: false) {
                        store.send(.setRecordArchived(recordId: detail.id, archived: !detail.archived))
                    }
                }
                IOSPrimaryButton("导出 Markdown", systemImage: "square.and.arrow.up", isPrimary: false) {
                    files.exportRecord(detail.id)
                }
                .accessibilityIdentifier("record-export-markdown")
            }
        }
    }

    @ViewBuilder
    private func summarySection(_ detail: RecordDetailSnapshot, slice: RecordDetailSlice) -> some View {
        let sections = SummarySectionItem.keyed(detail.summary)
        if sections.isEmpty {
            IOSEmptyState(
                icon: "doc.plaintext",
                title: "暂无纪要摘要",
                detail: "可在原文中标记重点，或点击上方整理纪要生成结构化总结。"
            )
        } else {
            ForEach(sections) { item in
                IOSCard {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(item.section.title)
                            .font(.system(size: AppFontSizes.md, weight: .semibold))
                            .foregroundStyle(IOSColors.textPrimary)
                        Text(item.section.text)
                            .font(.system(size: AppFontSizes.sm))
                            .foregroundStyle(IOSColors.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }

        if !slice.recordTasks.isEmpty {
            IOSCard {
                VStack(alignment: .leading, spacing: 8) {
                    Text("关联待办 (\(slice.recordTasks.count))")
                        .font(.system(size: AppFontSizes.sm, weight: .semibold))
                        .foregroundStyle(IOSColors.textPrimary)
                    ForEach(slice.recordTasks) { task in
                        HStack(spacing: 8) {
                            Image(systemName: task.completed ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(task.completed ? IOSColors.success : IOSColors.textMuted)
                            Text(task.text)
                                .font(.system(size: AppFontSizes.xs))
                                .foregroundStyle(IOSColors.textPrimary)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func transcriptSection(_ detail: RecordDetailSnapshot, focusSegmentId: String?) -> some View {
        if detail.segments.isEmpty {
            IOSEmptyState(
                icon: "text.alignleft",
                title: "暂无原文段落",
                detail: "录音完成转写后将按时间顺序展示原文。"
            )
        } else {
            ForEach(detail.segments) { segment in
                let isFocused = focusSegmentId == segment.id
                IOSCard {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            Text(TimeLabel.duration(segment.startMs))
                                .font(.system(size: AppFontSizes.xs, weight: .medium))
                                .foregroundStyle(IOSColors.textMuted)
                                .monospacedDigit()
                            if let speaker = segment.speaker, !speaker.isEmpty {
                                IOSBadge(speaker, tint: IOSColors.textSecondary)
                            }
                            if isFocused {
                                IOSBadge("定位段落", tint: IOSColors.accent)
                            }
                            Spacer()
                        }
                        Text(segment.text)
                            .font(.system(size: AppFontSizes.sm))
                            .foregroundStyle(IOSColors.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 8) {
                            IOSPrimaryButton("标重点", isPrimary: false) {
                                store.send(.addHighlight(recordId: detail.id, segmentId: segment.id))
                            }
                            IOSPrimaryButton("建待办", isPrimary: false) {
                                store.send(.createTask(recordId: detail.id, segmentId: segment.id))
                            }
                            IOSPrimaryButton("存记忆", isPrimary: false) {
                                store.send(.saveMemory(recordId: detail.id, segmentId: segment.id))
                            }
                        }
                    }
                }
                .overlay(
                    RoundedRectangle(cornerRadius: IOSRadii.card)
                        .stroke(isFocused ? IOSColors.accent : Color.clear, lineWidth: 1.5)
                )
                .id(segment.id)
            }
        }
    }

    @ViewBuilder
    private func highlightsSection(_ detail: RecordDetailSnapshot) -> some View {
        if detail.highlights.isEmpty {
            IOSEmptyState(
                icon: "star",
                title: "暂无重点摘录",
                detail: "在原文页签中点击标重点，将关键句收敛到这里。"
            )
        } else {
            ForEach(detail.highlights) { highlight in
                IOSCard {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(TimeLabel.duration(highlight.startMs))
                            .font(.system(size: AppFontSizes.xs, weight: .medium))
                            .foregroundStyle(IOSColors.textMuted)
                            .monospacedDigit()
                        Text(highlight.quote)
                            .font(.system(size: AppFontSizes.sm))
                            .foregroundStyle(IOSColors.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }
}
