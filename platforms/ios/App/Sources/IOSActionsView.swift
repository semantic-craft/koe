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

    @State private var taskFilter: IOSTaskFilter = .pending
    @State private var memoryFilter: IOSMemoryFilter = .proposed

    var body: some View {
        let activeTasks = store.tasks.filter(taskFilter.matches)
        let activeMemories = store.memories.filter { $0.state == memoryFilter.rawValue }

        VStack(spacing: 0) {
            Picker("行动分类", selection: $selectedSegment) {
                ForEach(IOSActionsSegment.allCases) { segment in
                    Text(segment.rawValue).tag(segment).accessibilityIdentifier("review-section-\(segment.rawValue)")
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(IOSColors.bgPanel)

            if selectedSegment == .tasks {
                Picker("待办状态", selection: $taskFilter) {
                    ForEach(IOSTaskFilter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).padding(.horizontal, 16)
                .accessibilityIdentifier("review-status-filter")
            } else {
                Picker("记忆状态", selection: $memoryFilter) {
                    ForEach(IOSMemoryFilter.allCases, id: \.self) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented).padding(.horizontal, 16)
                .accessibilityIdentifier("review-status-filter")
            }
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
                                IOSTaskCard(store: store, task: task, onOpenSource: onOpenSource)
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
                                IOSMemoryCard(store: store, memory: memory, onOpenSource: onOpenSource)
                            }
                        }
                    }
                }
                .frame(maxWidth: 760)
                .padding(16)
            }
            .background(IOSColors.bgPanel)
        }
        .navigationTitle("行动")
        .navigationBarTitleDisplayMode(.inline)
    }

}

enum IOSTaskFilter: String, CaseIterable {
    case pending = "待处理", completed = "已完成", dismissed = "已忽略"

    func matches(_ task: TaskSnapshot) -> Bool {
        switch self {
        case .pending: task.state == "proposed" || (task.state == "accepted" && !task.completed)
        case .completed: task.state == "accepted" && task.completed
        case .dismissed: task.state == "dismissed"
        }
    }
}

private enum IOSMemoryFilter: String, CaseIterable {
    case proposed, accepted, dismissed

    var title: String {
        switch self {
        case .proposed: "待确认"
        case .accepted: "已记住"
        case .dismissed: "已忽略"
        }
    }
}
