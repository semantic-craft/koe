import SwiftUI

struct TasksView: View {
    let store: HostSessionStore
    @State private var filter = "active"
    private var items: [TaskSnapshot] {
        store.tasks.filter { item in
            switch filter {
            case "completed": return item.completed && item.state == "accepted"
            case "dismissed": return item.state == "dismissed"
            default: return !item.completed && item.state != "dismissed"
            }
        }
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                PageHeading(title: "行动", subtitle: "从讨论中找到行动，由你决定是否开始。")
                Picker("显示待办", selection: $filter) {
                    Text("待处理").tag("active")
                    Text("已完成").tag("completed")
                    Text("已忽略").tag("dismissed")
                }.pickerStyle(.segmented).frame(width: 300)
                if items.isEmpty {
                    EmptyState(icon: "checkmark.circle", title: "这里暂时没有待办", detail: "在记录原文中选择“设为待办”，或整理纪要后确认提取的行动。")
                }
                LazyVStack(spacing: 8) { ForEach(items) { item in TaskRow(item: item, store: store) } }
            }.padding(30)
        }
    }
}

struct TaskRow: View {
    let item: TaskSnapshot
    let store: HostSessionStore
    @State private var editing = false
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if item.state == "accepted" {
                Button { store.send(.completeTask(itemId: item.id, completed: !item.completed)) } label: {
                    Image(systemName: item.completed ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(item.completed ? AppColors.success : AppColors.textMuted)
                        .frame(width: 28, height: 28).contentShape(Rectangle())
                }.buttonStyle(.plain).help(item.completed ? "恢复待办" : "完成待办")
            } else {
                Image(systemName: "checklist").foregroundStyle(AppColors.accent).frame(width: 28, height: 28)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(item.text).font(.system(size: AppFontSizes.sm)).strikethrough(item.completed)
                    .foregroundStyle(item.completed ? AppColors.textMuted : AppColors.textPrimary)
                if let due = item.due { Text(due).font(.system(size: AppFontSizes.xs)).foregroundStyle(AppColors.textMuted) }
                if let source = item.sources.first { SourceLink(source: source, store: store) }
            }.frame(maxWidth: .infinity, alignment: .leading)
            if item.state == "proposed" {
                VStack(spacing: 6) {
                    KoeActionButton("确认待办") { review(.accept) }
                    Button("忽略") { review(.dismiss) }.buttonStyle(.borderless)
                        .font(.system(size: AppFontSizes.xs)).foregroundStyle(AppColors.textMuted)
                }
            } else if item.state == "dismissed" {
                KoeActionButton("恢复") { review(.reset) }
            } else {
                Button("编辑") { editing = true }.buttonStyle(.borderless).font(.system(size: AppFontSizes.xs))
            }
        }.padding(14).background(AppColors.surface1, in: RoundedRectangle(cornerRadius: 7))
            .sheet(isPresented: $editing) {
                ItemEditor(store: store, id: item.id, initialText: item.text, initialDue: item.due, isTask: true)
            }
    }
    private func review(_ decision: ReviewDecision) { store.send(.reviewItem(itemId: item.id, decision: decision)) }
}

struct MemoryView: View {
    let store: HostSessionStore
    @State private var showDismissed = false
    private var items: [MemorySnapshot] {
        store.memories.filter { showDismissed ? $0.state == "dismissed" : $0.state != "dismissed" }
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .top) {
                    PageHeading(title: "记忆", subtitle: "留下有用的决定、偏好与事实，每一条都有来处。")
                    Spacer()
                    Toggle("显示已忽略", isOn: $showDismissed).toggleStyle(.checkbox)
                        .font(.system(size: AppFontSizes.xs))
                }
                if items.isEmpty {
                    EmptyState(icon: "square.stack.3d.up", title: "让值得记住的内容留在这里", detail: "在记录中点击“记住”，或确认整理出的记忆。随时可以修改或移除。")
                }
                LazyVStack(spacing: 12) { ForEach(items) { item in MemoryRow(item: item, store: store) } }
            }.padding(30)
        }
    }
}

struct MemoryRow: View {
    let item: MemorySnapshot
    let store: HostSessionStore
    @State private var editing = false
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "sparkle").foregroundStyle(AppColors.accent).frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 8) {
                Text(item.text).font(.system(size: AppFontSizes.sm)).lineSpacing(5)
                if let source = item.sources.first { SourceLink(source: source, store: store) }
            }.frame(maxWidth: .infinity, alignment: .leading)
            if item.state == "proposed" {
                VStack(spacing: 8) {
                    KoeActionButton("记住这条") { review(.accept) }
                    Button("忽略") { review(.dismiss) }.font(.system(size: AppFontSizes.xs)).buttonStyle(.borderless)
                }
            } else if item.state == "dismissed" {
                KoeActionButton("恢复") { review(.reset) }
            } else {
                Menu {
                    Button("编辑") { editing = true }
                    Button("移除") { review(.dismiss) }
                } label: { Image(systemName: "ellipsis").frame(width: 28, height: 28) }
                .menuStyle(.borderlessButton).frame(width: 30)
            }
        }.padding(18).background(AppColors.surface1, in: RoundedRectangle(cornerRadius: 8))
            .sheet(isPresented: $editing) {
                ItemEditor(store: store, id: item.id, initialText: item.text, initialDue: nil, isTask: false)
            }
    }
    private func review(_ decision: ReviewDecision) { store.send(.reviewItem(itemId: item.id, decision: decision)) }
}

public struct ItemEditor: View {
    let store: HostSessionStore
    let id: String
    let isTask: Bool
    @State private var text: String
    @State private var due: String
    @Environment(\.dismiss) private var dismiss
    public init(store: HostSessionStore, id: String, initialText: String, initialDue: String?, isTask: Bool) {
        self.store = store; self.id = id; self.isTask = isTask
        _text = State(initialValue: initialText)
        _due = State(initialValue: initialDue ?? "")
    }
    public var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(isTask ? "编辑待办" : "编辑记忆").font(.system(size: AppFontSizes.md, weight: .semibold))
            TextEditor(text: $text)
                .font(.system(size: AppFontSizes.sm))
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(height: 120)
                .background(AppColors.bgSubtle, in: RoundedRectangle(cornerRadius: AppRadii.control))
                .overlay(RoundedRectangle(cornerRadius: AppRadii.control).stroke(AppColors.border))
            if isTask {
                TextField("截止日期，例如 2026-11-20（可留空）", text: $due)
                    .textFieldStyle(.roundedBorder).onSubmit { save() }
            }
            if let error = store.navigation.effectiveError {
                Text(error).font(.system(size: AppFontSizes.xs)).foregroundStyle(AppColors.danger)
            }
            HStack {
                Spacer()
                KoeActionButton("取消") { dismiss() }
                KoeActionButton("保存", isPrimary: true) { save() }
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 470)
        .background(AppColors.surface0)
        .foregroundStyle(AppColors.textPrimary)
        .preferredColorScheme(.light)
    }
    private func save() {
        store.send(.editItem(itemId: id, text: text, due: due.isEmpty ? nil : due))
        if store.navigation.effectiveError == nil { dismiss() }
    }
}
