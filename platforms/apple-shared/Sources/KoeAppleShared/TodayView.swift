import SwiftUI

struct TodayView: View {
    let store: HostSessionStore
    private var records: [RecordSnapshot] {
        store.snapshot.records.filter { store.snapshot.todayRecordIds.contains($0.id) }
    }
    private var proposedTasks: [TaskSnapshot] { store.snapshot.tasks.filter { $0.state == "proposed" } }
    private var proposedMemories: [MemorySnapshot] { store.snapshot.memories.filter { $0.state == "proposed" } }
    var body: some View {
        ScrollView {
            HStack(alignment: .top, spacing: 30) {
                VStack(alignment: .leading, spacing: 28) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(Date.now.formatted(.dateTime.month().day().weekday(.wide)))
                            .font(.system(size: AppFontSizes.xs)).foregroundStyle(AppColors.textMuted)
                        PageHeading(title: "今天", subtitle: "让值得记住的事，有个去处。")
                    }
                    if store.snapshot.device.busy {
                        KoeCard {
                            VStack(alignment: .leading, spacing: 10) {
                                Label("正在取回录音", systemImage: "arrow.down.circle")
                                ProgressView(value: store.snapshot.device.progress)
                                Text("取回完成后，记录会出现在这里。")
                                    .font(.system(size: AppFontSizes.xs)).foregroundStyle(AppColors.textMuted)
                            }
                        }
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        sectionHeader("需要你确认", count: proposedTasks.count + proposedMemories.count)
                        if proposedTasks.isEmpty && proposedMemories.isEmpty {
                            HStack(spacing: 12) {
                                Image(systemName: "checkmark.circle").foregroundStyle(AppColors.success)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text("暂时没有待确认的内容").font(.system(size: AppFontSizes.sm))
                                    Text("整理记录后，需要你判断的事会出现在这里。")
                                        .font(.system(size: AppFontSizes.xs)).foregroundStyle(AppColors.textMuted)
                                }
                            }.padding(.vertical, 16)
                        }
                        ForEach(proposedTasks.prefix(3)) { item in TaskRow(item: item, store: store) }
                        ForEach(proposedMemories.prefix(2)) { item in MemoryRow(item: item, store: store) }
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        sectionHeader("今天的记录", count: records.count)
                        if records.isEmpty {
                            EmptyState(icon: "waveform", title: "从第一条记录开始", detail: "导入一段文字或录音，也可以连接录音豆。真实的内容会在这里形成今天的时间线。")
                        }
                        ForEach(records) { record in RecordRow(record: record, store: store) }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: 25) {
                    Text("接下来").font(.system(size: AppFontSizes.sm, weight: .semibold))
                    let tasks = store.snapshot.tasks.filter { $0.state == "accepted" && !$0.completed }
                    if tasks.isEmpty {
                        Text("这里暂时没有待办。确认一项行动后，就可以开始推进。")
                            .font(.system(size: AppFontSizes.xs)).foregroundStyle(AppColors.textMuted).lineSpacing(5)
                    }
                    ForEach(tasks.prefix(4)) { item in
                        Button { store.send("complete_task", ["itemId": item.id, "completed": true]) } label: {
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "circle").foregroundStyle(AppColors.accent)
                                Text(item.text).multilineTextAlignment(.leading)
                            }.font(.system(size: AppFontSizes.xs)).frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                    Button("管理待办 →") { store.send("navigate", ["section": "tasks"]) }
                        .font(.system(size: AppFontSizes.xs)).buttonStyle(.borderless)
                    Divider().overlay(AppColors.border)
                    VStack(alignment: .leading, spacing: 13) {
                        Label("值得记住", systemImage: "sparkles").font(.system(size: AppFontSizes.sm, weight: .medium))
                        if let memory = store.snapshot.memories.first(where: { $0.state == "accepted" }) {
                            Text(memory.text).font(.system(size: AppFontSizes.md)).lineSpacing(7)
                            if let source = memory.sources.first { SourceLink(source: source, store: store) }
                        } else {
                            Text("把长期有用的决定和想法留在记忆里。")
                                .font(.system(size: AppFontSizes.xs)).foregroundStyle(AppColors.textMuted).lineSpacing(5)
                        }
                    }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
                        .background(AppColors.accentSoft, in: RoundedRectangle(cornerRadius: 8))
                    KoeActionButton("今天有什么值得回顾？", systemImage: "sparkles") {
                        store.send("navigate", ["section": "ask"])
                    }
                }.frame(width: 235).padding(.top, 7)
            }.padding(30)
        }
    }
    private func sectionHeader(_ title: String, count: Int) -> some View {
        HStack {
            Text(title).font(.system(size: AppFontSizes.sm, weight: .semibold))
            Text("\(count)").font(.system(size: AppFontSizes.xs)).foregroundStyle(AppColors.textMuted)
            Spacer()
        }
    }
}

struct RecordListView: View {
    let store: HostSessionStore
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                PageHeading(title: "所有记录", subtitle: "每次讨论、每个想法，都可以回到原处。")
                if store.snapshot.records.isEmpty {
                    EmptyState(icon: "rectangle.stack", title: "还没有记录", detail: "通过右上角导入文字、Markdown、WAV 或资料包，也可以新建文字记录。")
                }
                LazyVStack(spacing: 0) {
                    ForEach(store.snapshot.records) { record in RecordRow(record: record, store: store) }
                }
            }.padding(30)
        }
    }
}

struct RecordRow: View {
    let record: RecordSnapshot
    let store: HostSessionStore
    var body: some View {
        Button { store.send("select_record", ["recordId": record.id]) } label: {
            HStack(spacing: 14) {
                Image(systemName: record.durationMs > 0 ? "waveform" : "doc.text")
                    .foregroundStyle(AppColors.accent).frame(width: 38, height: 38)
                    .background(AppColors.bgSubtle, in: RoundedRectangle(cornerRadius: 7))
                VStack(alignment: .leading, spacing: 6) {
                    Text(record.title).font(.system(size: AppFontSizes.sm, weight: .medium)).lineLimit(1)
                    Text(record.preview.isEmpty ? record.source : record.preview)
                        .font(.system(size: AppFontSizes.xs)).foregroundStyle(AppColors.textMuted).lineLimit(1)
                    Text(TimeLabel.date(record.createdAtEpochSec)).font(.system(size: AppFontSizes.xs))
                        .foregroundStyle(AppColors.textMuted)
                }
                Spacer(minLength: 10)
                KoeBadge(record.status)
                Image(systemName: "chevron.right").font(.system(size: AppFontSizes.xs)).foregroundStyle(AppColors.textMuted)
            }.padding(.vertical, 16).frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .bottom) { Rectangle().fill(AppColors.border).frame(height: 1) }
                .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}
