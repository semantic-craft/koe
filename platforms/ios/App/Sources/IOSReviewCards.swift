import KoeAppleCore
import SwiftUI

struct IOSTaskCard: View {
    let store: HostSessionStore
    let task: TaskSnapshot
    let onOpenSource: (SourceSnapshot) -> Void
    @State private var editing = false

    var body: some View {
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
                                task.state == "dismissed" ? "已忽略" : (task.state == "proposed" ? "待确认" : "已采纳"),
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

                if task.state == "accepted" {
                    Button("编辑待办") { editing = true }
                } else if task.state == "dismissed" {
                    Button("恢复") { store.send(.reviewItem(itemId: task.id, decision: .reset)) }
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
        .sheet(isPresented: $editing) {
            IOSItemEditorSheet(store: store, task: task)
        }
    }
}

struct IOSMemoryCard: View {
    let store: HostSessionStore
    let memory: MemorySnapshot
    let onOpenSource: (SourceSnapshot) -> Void
    @State private var editing = false

    var body: some View {
        IOSCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 8) {
                    Text(memory.text)
                        .font(.system(size: AppFontSizes.sm))
                        .foregroundStyle(IOSColors.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    IOSBadge(
                        memory.state == "dismissed" ? "已忽略" : (memory.state == "proposed" ? "待确认" : "已记住"),
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

                if memory.state == "accepted" {
                    HStack {
                        Button("编辑记忆") { editing = true }
                        Button("移除", role: .destructive) { store.send(.reviewItem(itemId: memory.id, decision: .dismiss)) }
                    }
                } else if memory.state == "dismissed" {
                    Button("恢复") { store.send(.reviewItem(itemId: memory.id, decision: .reset)) }
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
        .sheet(isPresented: $editing) {
            IOSItemEditorSheet(store: store, memory: memory)
        }
    }

}
