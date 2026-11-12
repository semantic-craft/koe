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
                    if let mic = store.snapshot.microphone {
                        activeMicrophoneBanner(mic)
                    }
                    if store.snapshot.device.recording || store.snapshot.device.stopping || store.snapshot.device.transferPhase == "streaming_realtime" {
                        liveRecordingCard
                    } else if store.snapshot.device.busy {
                        KoeCard {
                            VStack(alignment: .leading, spacing: 10) {
                                HStack {
                                    Label("正在取回录音", systemImage: "arrow.down.circle")
                                        .font(.system(size: AppFontSizes.sm, weight: .medium))
                                    Spacer()
                                    Text("\(Int((store.snapshot.device.progress * 100).rounded()))%")
                                        .font(.system(size: AppFontSizes.xs, design: .monospaced))
                                        .foregroundStyle(KoeColors.textSecondary)
                                }
                                ProgressView(value: store.snapshot.device.progress)
                                Text("取回完成后，记录会出现在这里。")
                                    .font(.system(size: AppFontSizes.xs)).foregroundStyle(AppColors.textMuted)
                            }
                        }
                    }
                    if store.snapshot.device.connected
                        && !store.snapshot.device.recording
                        && !store.snapshot.device.busy
                        && !store.snapshot.device.files.isEmpty
                    {
                        deviceFilesCard
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
    private func activeMicrophoneBanner(_ mic: MicrophoneSnapshot) -> some View {
        KoeCard {
            HStack(spacing: 12) {
                Circle()
                    .fill(mic.phase == "paused" ? AppColors.warning : KoeColors.danger)
                    .frame(width: 8, height: 8)
                Text(mic.phase == "paused" ? "\(store.snapshot.capture.selectedLabel) 已暂停" : "\(store.snapshot.capture.selectedLabel) 正在录音")
                    .font(.system(size: AppFontSizes.sm, weight: .medium))
                Spacer()
                Text(TimeLabel.duration(mic.durationMs))
                    .font(.system(size: AppFontSizes.xs, design: .monospaced))
                    .foregroundStyle(KoeColors.textSecondary)
                KoeActionButton("查看录音实况", systemImage: "waveform") {
                    store.send("navigate", ["section": "capture"])
                }
            }
        }
    }
    private var liveRecordingCard: some View {
        let liveRecord = store.snapshot.activeLiveRecord
        return KoeCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Circle().fill(KoeColors.danger).frame(width: 8, height: 8)
                    Text(store.snapshot.device.stopping ? "正在等待录音豆停止" : "录音豆正在录音")
                        .font(.system(size: AppFontSizes.sm, weight: .medium))
                        .foregroundStyle(KoeColors.textPrimary)
                    Spacer()
                    Text(TimeLabel.duration(store.snapshot.device.liveDurationMs))
                        .font(.system(size: AppFontSizes.xs, design: .monospaced))
                        .foregroundStyle(KoeColors.textSecondary)
                    Button {
                        store.send("device_stop")
                        NotificationCenter.default.post(name: Notification.Name("KoeFlushBleOutbound"), object: nil)
                    } label: {
                        Text(store.snapshot.device.stopping ? "重试停止" : "停止录音")
                            .font(.system(size: AppFontSizes.xs, weight: .medium))
                            .foregroundStyle(KoeColors.danger)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(KoeColors.bgSubtle, in: RoundedRectangle(cornerRadius: AppRadii.control))
                            .overlay(RoundedRectangle(cornerRadius: AppRadii.control).stroke(KoeColors.border))
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
                if let liveRecord, !liveRecord.preview.isEmpty {
                    Text(liveRecord.preview)
                        .font(.system(size: AppFontSizes.sm))
                        .foregroundStyle(KoeColors.textPrimary)
                        .lineLimit(3)
                } else {
                    Text(
                        store.snapshot.device.liveBytes > 0
                            ? "正在接收实时语音流 (\(store.snapshot.device.liveBytes) B)..."
                            : "正在等待录音豆语音帧..."
                    )
                    .font(.system(size: AppFontSizes.xs))
                    .foregroundStyle(KoeColors.textSecondary)
                }
                if let liveRecord {
                    Button {
                        store.send("select_record", ["recordId": liveRecord.id])
                    } label: {
                        HStack(spacing: 5) {
                            Text("查看实时字幕")
                            Image(systemName: "chevron.right")
                        }
                        .font(.system(size: AppFontSizes.xs, weight: .medium))
                        .foregroundStyle(KoeColors.accent)
                        .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
            }
        }
    }
    private var deviceFilesCard: some View {
        KoeCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("录音豆文件 (\(store.snapshot.device.files.count))")
                    .font(.system(size: AppFontSizes.sm, weight: .medium))
                    .foregroundStyle(KoeColors.textPrimary)
                ForEach(store.snapshot.device.files.prefix(3)) { file in
                    HStack(spacing: 10) {
                        Text("#\(file.fileId)")
                            .font(.system(size: AppFontSizes.xs, design: .monospaced))
                            .foregroundStyle(KoeColors.textPrimary)
                        Text(TimeLabel.duration(file.durationMs))
                            .font(.system(size: AppFontSizes.xs, design: .monospaced))
                            .foregroundStyle(KoeColors.textSecondary)
                        Spacer()
                        Button {
                            store.send("device_download", ["fileId": file.fileId])
                            NotificationCenter.default.post(name: Notification.Name("KoeFlushBleOutbound"), object: nil)
                        } label: {
                            Text("取回")
                                .font(.system(size: AppFontSizes.xs, weight: .medium))
                                .foregroundStyle(KoeColors.textPrimary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(KoeColors.bgSubtle, in: RoundedRectangle(cornerRadius: AppRadii.control))
                                .overlay(RoundedRectangle(cornerRadius: AppRadii.control).stroke(KoeColors.border))
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }
            }
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
    @State private var showArchivedOnly = false
    private var archivedCount: Int {
        store.snapshot.records.filter(\.archived).count
    }
    private var filtered: [RecordSnapshot] {
        showArchivedOnly ? store.snapshot.records.filter(\.archived) : store.snapshot.records
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                PageHeading(title: "所有记录", subtitle: "每次讨论、每个想法，都可以回到原处。")
                if !store.snapshot.records.isEmpty || showArchivedOnly {
                    HStack(spacing: 8) {
                        filterPill("全部", count: store.snapshot.records.count, isSelected: !showArchivedOnly) {
                            showArchivedOnly = false
                        }
                        filterPill("已归档", count: archivedCount > 0 ? archivedCount : nil, isSelected: showArchivedOnly) {
                            showArchivedOnly = true
                        }
                        Spacer()
                    }
                }
                if store.snapshot.records.isEmpty && !showArchivedOnly {
                    EmptyState(icon: "rectangle.stack", title: "还没有记录", detail: "通过右上角导入文字、Markdown、WAV 或资料包，也可以新建文字记录。")
                } else if showArchivedOnly && filtered.isEmpty {
                    EmptyState(icon: "lock", title: "还没有已归档的记录", detail: "在记录上右键选择“归档保护”，或在详情页开启归档保护，防止重要录音被误删。")
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(filtered) { record in RecordRow(record: record, store: store) }
                    }
                }
            }.padding(30)
        }
    }
    private func filterPill(_ title: String, count: Int? = nil, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(title)
                if let count {
                    Text("\(count)").monospacedDigit()
                }
            }
            .font(.system(size: AppFontSizes.xs, weight: isSelected ? .medium : .regular))
            .foregroundStyle(isSelected ? AppColors.accent : AppColors.textMuted)
            .padding(.horizontal, 11).frame(minHeight: 30)
            .background(isSelected ? AppColors.accentSoft : AppColors.bgSubtle, in: RoundedRectangle(cornerRadius: AppRadii.control))
            .overlay(RoundedRectangle(cornerRadius: AppRadii.control).stroke(isSelected ? AppColors.accent.opacity(0.35) : AppColors.border))
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
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
                if record.archived {
                    KoeBadge("已归档", tint: AppColors.textSecondary)
                }
                KoeBadge(record.status)
                Image(systemName: "chevron.right").font(.system(size: AppFontSizes.xs)).foregroundStyle(AppColors.textMuted)
            }.padding(.vertical, 16).frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .bottom) { Rectangle().fill(AppColors.border).frame(height: 1) }
                .contentShape(Rectangle())
        }.buttonStyle(.plain)
        .contextMenu {
            Button(record.archived ? "取消归档保护" : "归档保护") {
                store.send("set_record_archived", ["recordId": record.id, "archived": !record.archived])
            }
            Button("移到回收站") {
                store.send("trash_record", ["recordId": record.id])
            }
            .disabled(record.archived || record.status == "转写中" || record.status == "整理中")
        }
    }
}
