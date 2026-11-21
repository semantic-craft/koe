import KoeAppleCore
import SwiftUI

private enum IOSActionsSegment: String, CaseIterable, Identifiable {
    case tasks = "待办"
    case memories = "记忆"

    var id: String { rawValue }
}

struct IOSActionsView: View {
    let store: HostSessionStore
    let onOpenSource: (SourceSnapshot) -> Void

    @State private var selectedSegment: IOSActionsSegment = .tasks

    var body: some View {
        let activeTasks = store.tasks.filter { $0.state != "dismissed" }
        let activeMemories = store.memories.filter { $0.state != "dismissed" }

        VStack(spacing: 0) {
            Picker("行动分类", selection: $selectedSegment) {
                ForEach(IOSActionsSegment.allCases) { segment in
                    Text(segment.rawValue).tag(segment)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(IOSColors.bgPanel)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    switch selectedSegment {
                    case .tasks:
                        if activeTasks.isEmpty {
                            IOSEmptyState(
                                icon: "checklist",
                                title: "暂无待办事项",
                                detail: "会议纪要或原文中提取的待办会汇总到这里供你确认。"
                            )
                        } else {
                            ForEach(activeTasks) { task in
                                taskCard(task)
                            }
                        }
                    case .memories:
                        if activeMemories.isEmpty {
                            IOSEmptyState(
                                icon: "brain",
                                title: "暂无记忆条目",
                                detail: "需要长期记住的事实与约定会保留来源出处。"
                            )
                        } else {
                            ForEach(activeMemories) { memory in
                                memoryCard(memory)
                            }
                        }
                    }
                }
                .padding(16)
            }
            .background(IOSColors.bgPanel)
        }
        .navigationTitle("行动")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func taskCard(_ task: TaskSnapshot) -> some View {
        IOSCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    if task.state == "accepted" {
                        Button {
                            store.send(.completeTask(itemId: task.id, completed: !task.completed))
                        } label: {
                            Image(systemName: task.completed ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: AppFontSizes.md))
                                .foregroundStyle(task.completed ? IOSColors.success : IOSColors.textMuted)
                                .frame(width: 28, height: 28)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(task.completed ? "标记未完成" : "标记已完成")
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text(task.text)
                            .font(.system(size: AppFontSizes.sm, weight: .medium))
                            .foregroundStyle(IOSColors.textPrimary)
                            .strikethrough(task.completed)
                        HStack(spacing: 8) {
                            IOSBadge(
                                task.state == "proposed" ? "待确认" : "已采纳",
                                tint: task.state == "proposed" ? IOSColors.warning : IOSColors.success
                            )
                            if let due = task.due, !due.isEmpty {
                                Text("截止 \(due)")
                                    .font(.system(size: AppFontSizes.xs))
                                    .foregroundStyle(IOSColors.textMuted)
                            }
                        }
                    }
                    Spacer()
                }

                if task.state == "proposed" {
                    HStack(spacing: 8) {
                        IOSPrimaryButton("采纳", systemImage: "checkmark", isPrimary: true) {
                            store.send(.reviewItem(itemId: task.id, decision: .accept))
                        }
                        IOSPrimaryButton("忽略", systemImage: "xmark", isPrimary: false) {
                            store.send(.reviewItem(itemId: task.id, decision: .dismiss))
                        }
                    }
                }

                if !task.sources.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(task.sources) { source in
                                IOSSourceLink(source: source) {
                                    onOpenSource(source)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func memoryCard(_ memory: MemorySnapshot) -> some View {
        IOSCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 8) {
                    Text(memory.text)
                        .font(.system(size: AppFontSizes.sm))
                        .foregroundStyle(IOSColors.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    IOSBadge(
                        memory.state == "proposed" ? "待确认" : "已记住",
                        tint: memory.state == "proposed" ? IOSColors.warning : IOSColors.success
                    )
                }

                if memory.state == "proposed" {
                    HStack(spacing: 8) {
                        IOSPrimaryButton("记住", systemImage: "checkmark", isPrimary: true) {
                            store.send(.reviewItem(itemId: memory.id, decision: .accept))
                        }
                        IOSPrimaryButton("忽略", systemImage: "xmark", isPrimary: false) {
                            store.send(.reviewItem(itemId: memory.id, decision: .dismiss))
                        }
                    }
                }

                if !memory.sources.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(memory.sources) { source in
                                IOSSourceLink(source: source) {
                                    onOpenSource(source)
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
