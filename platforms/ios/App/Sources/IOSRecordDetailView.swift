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
    var onOpenRelatedSource: (SourceSnapshot) -> Void = { _ in }
    var onAsk: () -> Void = {}
    @Environment(\.dismiss) private var dismiss
    @State private var edit: IOSRecordEdit?
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
                    .frame(maxWidth: 760)
                    .padding(16)
                }
                .background(IOSColors.bgPanel)
            }

            IOSPlayerBarView(store: store, recordId: recordId)
        }
        .sheet(item: $edit) { IOSRecordEditorSheet(store: store, edit: $0) }
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
                HStack {
                    Text(detail.title)
                    Spacer()
                    Menu {
                        Button("重命名") { edit = .title(detail) }
                        .accessibilityIdentifier("detail-rename")
                        Button("问这条记录") {
                            if store.sendReturningError(.setAskScope(scope: "record", recordId: detail.id)) == nil { onAsk() }
                        }
                        .accessibilityIdentifier("detail-ask")
                        Button("移入回收站", role: .destructive) {
                            guard detail.canTrash, store.navigation.savingRecordId != detail.id else { return }
                            if store.sendReturningError(.trashRecord(recordId: detail.id)) == nil { dismiss() }
                        }
                        .disabled(!detail.canTrash || store.navigation.savingRecordId == detail.id)
                        .accessibilityIdentifier("detail-trash")
                    } label: {
                        Label("记录操作", systemImage: "ellipsis.circle").labelStyle(.iconOnly)
                    }
                    .accessibilityIdentifier("detail-menu")
                }
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
                    .accessibilityIdentifier("detail-archive")
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
        if detail.minutesStale {
            IOSCard {
                VStack(alignment: .leading, spacing: 8) {
                    Label("原文已修改，当前纪要需要更新", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(IOSColors.warning)
                    Button("重新整理纪要") { store.send(.summarize(recordId: detail.id)) }
                        .disabled(detail.isProcessing || detail.segments.isEmpty)
                }
            }
        }
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
                        Text(item.section.title).textSelection(.enabled)
                            .font(.system(size: AppFontSizes.md, weight: .semibold))
                            .foregroundStyle(IOSColors.textPrimary)
                        Text(item.section.text).textSelection(.enabled)
                            .font(.system(size: AppFontSizes.sm))
                            .foregroundStyle(IOSColors.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        IOSWorkspaceSources(sources: item.section.sources, onOpenSource: openSource)
                    }
                }
            }
        }

        if !slice.recordTasks.isEmpty {
            Text("关联待办").font(.headline)
            ForEach(slice.recordTasks) { task in
                IOSTaskCard(store: store, task: task, onOpenSource: openSource)
            }
        }
        if !slice.recordMemories.isEmpty {
            Text("关联记忆").font(.headline)
            ForEach(slice.recordMemories) { memory in
                IOSMemoryCard(store: store, memory: memory, onOpenSource: openSource)
            }
        }
    }

    private func openSource(_ source: SourceSnapshot) {
        guard source.recordId == recordId else {
            onOpenRelatedSource(source)
            return
        }
        if store.sendReturningError(.openSource(recordId: source.recordId, segmentId: source.segmentId)) == nil {
            selectedTab = .transcript
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
                            IOSSegmentPlaybackButton(store: store, recordID: detail.id, segment: segment)
                            Menu {
                                Button("修改本段说话人") { edit = .speaker(detail.id, segment) }
                                .accessibilityIdentifier("segment-speaker-edit-\(segment.id)")
                                if let speaker = segment.speaker, !speaker.isEmpty {
                                    Button("改名或合并说话人") { edit = .renameSpeaker(detail.id, speaker) }
                                    .accessibilityIdentifier("segment-speaker-merge-\(segment.id)")
                                }
                            } label: {
                                IOSBadge(segment.speaker ?? "说话人", tint: IOSColors.textSecondary)
                            }.disabled(!detail.canEditTranscript)
                            .accessibilityIdentifier("segment-speaker-\(segment.id)")
                            if isFocused {
                                IOSBadge("定位段落", tint: IOSColors.accent)
                                .accessibilityIdentifier("segment-focused-\(segment.id)")
                            }
                            Spacer()
                        }
                        Text(segment.text).textSelection(.enabled)
                            .font(.system(size: AppFontSizes.sm))
                            .foregroundStyle(IOSColors.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                        if segment.isEdited, let original = segment.originalText {
                            DisclosureGroup("对照改前原文") { Text(original).textSelection(.enabled) }
                            .accessibilityIdentifier("segment-original-\(segment.id)")
                        }
                        Button("编辑原文") { edit = .text(detail.id, segment) }
                        .accessibilityIdentifier("segment-edit-\(segment.id)")
                            .disabled(!detail.canEditTranscript)
                        HStack(spacing: 8) {
                            IOSPrimaryButton("标重点", isPrimary: false) {
                                store.send(.addHighlight(recordId: detail.id, segmentId: segment.id))
                            }
                            .accessibilityIdentifier("segment-highlight-\(segment.id)")
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
