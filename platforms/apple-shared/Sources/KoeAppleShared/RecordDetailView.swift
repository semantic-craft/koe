import SwiftUI

struct RecordDetailView: View {
    let store: HostSessionStore
    @State private var tab = "summary"
    @State private var renaming = false
    @State private var titleDraft = ""
    var body: some View {
        let slice = store.recordDetail
        if let detail = slice.detail {
            VStack(alignment: .leading, spacing: 0) {
                heading(detail).padding(28)
                HStack(spacing: 22) {
                    tabButton("summary", "纪要")
                    tabButton("transcript", "原文")
                    tabButton("highlights", "重点 \(detail.highlights.count)")
                    Spacer()
                }.padding(.horizontal, 28).padding(.bottom, 12)
                Divider().overlay(AppColors.border)
                HStack(alignment: .top, spacing: 0) {
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(alignment: .leading, spacing: 24) {
                                switch tab {
                                case "transcript":
                                    TranscriptDetailView(detail: detail, store: store) { segmentId in
                                        proxy.scrollTo(segmentId, anchor: .center)
                                    }
                                case "highlights": highlights(detail)
                                default: summary(detail)
                                }
                            }.padding(28).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .onChange(of: slice.focusSegmentId, initial: true) { _, focus in
                            guard let focus else { return }
                            tab = "transcript"
                            Task { @MainActor in
                                await Task.yield()
                                proxy.scrollTo(focus, anchor: .center)
                            }
                        }
                    }
                    Rectangle().fill(AppColors.border).frame(width: 1)
                    inspector(tasks: slice.recordTasks, memories: slice.recordMemories).padding(20).frame(width: 250)
                }
            }
            .onChange(of: detail.id) { _, _ in
                renaming = false
                tab = store.recordDetail.focusSegmentId == nil ? "summary" : "transcript"
            }
        } else {
            EmptyState(icon: "doc.text", title: "请选择一条记录", detail: "从所有记录或今天的时间线打开。")
        }
    }
    private func heading(_ detail: RecordDetailSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            Text(TimeLabel.date(detail.createdAtEpochSec)).font(.system(size: AppFontSizes.xs)).foregroundStyle(AppColors.textMuted)
            HStack(spacing: 10) {
                if renaming {
                    TextField("记录标题", text: $titleDraft).font(.system(size: AppFontSizes.lg)).onSubmit { rename(detail.id) }
                    KoeActionButton("保存") { rename(detail.id) }
                    Button("取消") { renaming = false }.buttonStyle(.borderless)
                } else {
                    Text(detail.title).font(.system(size: AppFontSizes.lg, weight: .semibold)).textSelection(.enabled)
                    Button { titleDraft = detail.title; renaming = true } label: {
                        Image(systemName: "pencil").frame(width: 30, height: 30).contentShape(Rectangle())
                    }.buttonStyle(.plain).foregroundStyle(AppColors.textMuted).help("重命名")
                }
                Spacer()
                if !renaming {
                    KoeActionButton(
                        detail.archived ? "取消归档" : "归档保护",
                        systemImage: detail.archived ? "lock.open" : "lock"
                    ) {
                        store.send(.setRecordArchived(recordId: detail.id, archived: !detail.archived))
                    }
                    KoeActionButton("移到回收站", systemImage: "trash") {
                        store.send(.trashRecord(recordId: detail.id))
                    }
                    .disabled(detail.archived || detail.isProcessing)
                    .help(detail.archived ? "已开启归档保护，取消归档后可移入回收站" : "")
                }
            }
            HStack(spacing: 12) {
                KoeBadge(detail.status)
                if detail.archived {
                    KoeBadge("已归档", tint: AppColors.textSecondary)
                }
                Text(detail.source)
                if detail.durationMs > 0 { Text(TimeLabel.duration(detail.durationMs)) }
                Text("\(detail.segments.count) 段原文")
            }.font(.system(size: AppFontSizes.xs)).foregroundStyle(AppColors.textMuted)
        }
    }
    private func tabButton(_ key: String, _ title: String) -> some View {
        Button { tab = key } label: {
            Text(title).font(.system(size: AppFontSizes.sm, weight: tab == key ? .medium : .regular))
                .foregroundStyle(tab == key ? AppColors.accent : AppColors.textMuted)
                .frame(minHeight: 32).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
    @ViewBuilder private func summary(_ detail: RecordDetailSnapshot) -> some View {
        if detail.summary.isEmpty {
            EmptyState(icon: "text.alignleft", title: "纪要还没有生成", detail: "原始内容已经保留。整理后，这里会显示结论和对应的原话。")
            KoeActionButton("整理纪要", systemImage: "sparkles", isPrimary: true) {
                store.send(.summarize(recordId: detail.id))
            }.disabled(detail.segments.isEmpty || detail.isProcessing)
        } else {
            if detail.minutesStale {
                StaleMinutesBanner(recordId: detail.id, isProcessing: detail.isProcessing, store: store)
            }
            ForEach(Array(detail.summary.enumerated()), id: \.offset) { _, block in
                VStack(alignment: .leading, spacing: 12) {
                    Text(block.title).font(.system(size: AppFontSizes.md, weight: .semibold))
                    Text(block.text).font(.system(size: AppFontSizes.sm)).lineSpacing(7).textSelection(.enabled)
                    ForEach(block.sources) { source in SourceLink(source: source, store: store) }
                }
            }
        }
    }
    @ViewBuilder private func highlights(_ detail: RecordDetailSnapshot) -> some View {
        if detail.highlights.isEmpty {
            EmptyState(icon: "bookmark", title: "还没有标记重点", detail: "在原文中标记值得再次回看的段落。")
        }
        ForEach(detail.highlights) { source in
            KoeCard {
                VStack(alignment: .leading, spacing: 10) {
                    Text(source.quote).font(.system(size: AppFontSizes.sm)).lineSpacing(6)
                    SourceLink(source: source, store: store)
                }
            }
        }
    }
    private func inspector(tasks: [TaskSnapshot], memories: [MemorySnapshot]) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("记录里的行动").font(.system(size: AppFontSizes.sm, weight: .medium))
                if tasks.isEmpty { Text("从原文中提取一项待办。").font(.system(size: AppFontSizes.xs)).foregroundStyle(AppColors.textMuted) }
                ForEach(tasks) { item in
                    VStack(alignment: .leading, spacing: 9) {
                        Text(item.text).font(.system(size: AppFontSizes.xs)).lineSpacing(4).strikethrough(item.completed)
                        if item.state == "proposed" {
                            HStack(spacing: 14) {
                                Button("确认待办") { store.send(.reviewItem(itemId: item.id, decision: "accept")) }
                                Button("忽略") { store.send(.reviewItem(itemId: item.id, decision: "dismiss")) }
                            }
                        } else {
                            Button(item.completed ? "恢复为未完成" : "标为完成") {
                                store.send(.completeTask(itemId: item.id, completed: !item.completed))
                            }
                        }
                    }.font(.system(size: AppFontSizes.xs)).buttonStyle(.borderless)
                }
                Divider().overlay(AppColors.border)
                Text("值得记住").font(.system(size: AppFontSizes.sm, weight: .medium))
                if memories.isEmpty { Text("选择一段原文，留作长期记忆。").font(.system(size: AppFontSizes.xs)).foregroundStyle(AppColors.textMuted) }
                ForEach(memories) { item in
                    VStack(alignment: .leading, spacing: 9) {
                        Text(item.text).font(.system(size: AppFontSizes.xs)).lineSpacing(4)
                        Button(item.state == "proposed" ? "记住这条" : "移除") {
                            store.send(.reviewItem(itemId: item.id, decision: item.state == "proposed" ? "accept" : "dismiss"))
                        }.font(.system(size: AppFontSizes.xs)).buttonStyle(.borderless)
                    }
                }
            }
        }
    }
    private func rename(_ id: String) {
        store.send(.renameRecord(recordId: id, title: titleDraft))
        if store.navigation.effectiveError == nil { renaming = false }
    }
}
