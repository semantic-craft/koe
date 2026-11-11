import SwiftUI

struct RecordDetailView: View {
    let store: HostSessionStore
    @State private var tab = "summary"
    @State private var renaming = false
    @State private var titleDraft = ""
    var body: some View {
        if let detail = store.snapshot.detail {
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
                                case "transcript": transcript(detail)
                                case "highlights": highlights(detail)
                                default: summary(detail)
                                }
                            }.padding(28).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .onChange(of: store.snapshot.focusSegmentId, initial: true) { _, focus in
                            guard let focus else { return }
                            tab = "transcript"
                            Task { @MainActor in
                                await Task.yield()
                                proxy.scrollTo(focus, anchor: .center)
                            }
                        }
                    }
                    Rectangle().fill(AppColors.border).frame(width: 1)
                    inspector(detail).padding(20).frame(width: 250)
                }
            }
            .onChange(of: detail.id) { _, _ in tab = store.snapshot.focusSegmentId == nil ? "summary" : "transcript" }
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
                        store.send("set_record_archived", ["recordId": detail.id, "archived": !detail.archived])
                    }
                    KoeActionButton("移到回收站", systemImage: "trash") {
                        store.send("trash_record", ["recordId": detail.id])
                    }
                    .disabled(detail.archived || detail.isProcessing)
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
                store.send("summarize", ["recordId": detail.id])
            }.disabled(detail.segments.isEmpty || detail.isProcessing)
        } else {
            ForEach(Array(detail.summary.enumerated()), id: \.offset) { _, block in
                VStack(alignment: .leading, spacing: 12) {
                    Text(block.title).font(.system(size: AppFontSizes.md, weight: .semibold))
                    Text(block.text).font(.system(size: AppFontSizes.sm)).lineSpacing(7).textSelection(.enabled)
                    ForEach(block.sources) { source in SourceLink(source: source, store: store) }
                }
            }
        }
    }
    @ViewBuilder private func transcript(_ detail: RecordDetailSnapshot) -> some View {
        if detail.segments.isEmpty {
            EmptyState(icon: "text.bubble", title: "还没有文字", detail: detail.audioPath == nil ? "这条记录尚未包含原文。" : "录音已保留，配置转写服务后可以开始转写。")
            if detail.audioPath != nil {
                KoeActionButton("转写并整理", isPrimary: true) { store.send("transcribe", ["recordId": detail.id]) }
                    .disabled(detail.isProcessing)
            }
        } else if detail.canRetranscribe {
            VStack(alignment: .leading, spacing: 8) {
                KoeActionButton("重新转写完整录音", systemImage: "arrow.clockwise") {
                    store.send("transcribe", ["recordId": detail.id])
                }.disabled(detail.isProcessing)
                Text("保留原记录和来源，在新副本中重新转写完整录音。")
                    .font(.system(size: AppFontSizes.xs)).foregroundStyle(AppColors.textMuted)
            }
        }
        ForEach(detail.segments) { segment in
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Text(segment.timed == false ? "无时码" : TimeLabel.duration(segment.startMs)).monospacedDigit().foregroundStyle(AppColors.accent)
                    Text(segment.speaker ?? "原文").foregroundStyle(AppColors.textMuted)
                    Spacer()
                    Menu {
                        Button("标记重点") { sourceCommand("add_highlight", detail.id, segment.id) }
                        Button("设为待办") { sourceCommand("create_task", detail.id, segment.id) }
                        Button("记住") { sourceCommand("save_memory", detail.id, segment.id) }
                    } label: { Image(systemName: "ellipsis").frame(width: 26, height: 26) }
                    .menuStyle(.borderlessButton).frame(width: 28)
                }.font(.system(size: AppFontSizes.xs))
                Text(segment.text).font(.system(size: AppFontSizes.sm)).lineSpacing(7).textSelection(.enabled)
                HStack(spacing: 16) {
                    Button("标记重点") { sourceCommand("add_highlight", detail.id, segment.id) }
                    Button("设为待办") { sourceCommand("create_task", detail.id, segment.id) }
                    Button("记住") { sourceCommand("save_memory", detail.id, segment.id) }
                }.buttonStyle(.borderless).font(.system(size: AppFontSizes.xs)).foregroundStyle(AppColors.textMuted)
            }
            .padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(store.snapshot.focusSegmentId == segment.id ? AppColors.accentSoft : AppColors.surface1,
                        in: RoundedRectangle(cornerRadius: 7)).id(segment.id)
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
    private func inspector(_ detail: RecordDetailSnapshot) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("记录里的行动").font(.system(size: AppFontSizes.sm, weight: .medium))
                let tasks = store.snapshot.tasks.filter { $0.state != "dismissed" && $0.sources.contains { $0.recordId == detail.id } }
                if tasks.isEmpty { Text("从原文中提取一项待办。").font(.system(size: AppFontSizes.xs)).foregroundStyle(AppColors.textMuted) }
                ForEach(tasks) { item in
                    VStack(alignment: .leading, spacing: 9) {
                        Text(item.text).font(.system(size: AppFontSizes.xs)).lineSpacing(4).strikethrough(item.completed)
                        if item.state == "proposed" {
                            HStack(spacing: 14) {
                                Button("确认待办") { store.send("review_item", ["itemId": item.id, "decision": "accept"]) }
                                Button("忽略") { store.send("review_item", ["itemId": item.id, "decision": "dismiss"]) }
                            }
                        } else {
                            Button(item.completed ? "恢复为未完成" : "标为完成") {
                                store.send("complete_task", ["itemId": item.id, "completed": !item.completed])
                            }
                        }
                    }.font(.system(size: AppFontSizes.xs)).buttonStyle(.borderless)
                }
                Divider().overlay(AppColors.border)
                Text("值得记住").font(.system(size: AppFontSizes.sm, weight: .medium))
                let memories = store.snapshot.memories.filter { $0.state != "dismissed" && $0.sources.contains { $0.recordId == detail.id } }
                if memories.isEmpty { Text("选择一段原文，留作长期记忆。").font(.system(size: AppFontSizes.xs)).foregroundStyle(AppColors.textMuted) }
                ForEach(memories) { item in
                    VStack(alignment: .leading, spacing: 9) {
                        Text(item.text).font(.system(size: AppFontSizes.xs)).lineSpacing(4)
                        Button(item.state == "proposed" ? "记住这条" : "移除") {
                            store.send("review_item", ["itemId": item.id, "decision": item.state == "proposed" ? "accept" : "dismiss"])
                        }.font(.system(size: AppFontSizes.xs)).buttonStyle(.borderless)
                    }
                }
            }
        }
    }
    private func sourceCommand(_ command: String, _ record: String, _ segment: String) {
        store.send(command, ["recordId": record, "segmentId": segment])
    }
    private func rename(_ id: String) {
        store.send("rename_record", ["recordId": id, "title": titleDraft])
        if store.snapshot.error == nil { renaming = false }
    }
}
