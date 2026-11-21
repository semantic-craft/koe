import KoeAppleCore
import SwiftUI

struct IOSQuickNoteWorkspaceView: View {
    let store: HostSessionStore
    let onSelectRecord: (String) -> Void
    let onOpenSource: (SourceSnapshot) -> Void
    @State private var filter: QuickNoteFilterSelection = .all
    @State private var selection: Set<String>?
    private var workspace: QuickNoteWorkspaceSnapshot { store.quickNoteWorkspace }
    private var visibleCards: [QuickNoteCardSnapshot] { workspace.filteredCards(for: filter) }

    var body: some View {
        IOSWorkspaceCaptureHeader(store: store, mode: .quickNote, title: "收件箱 \(workspace.inboxCount)  |  共 \(workspace.totalCount) 条",
                                  source: workspace.sourceLabel, status: workspace.isActive ? "记录中" : "就绪",
                                  isActive: workspace.isActive, canStart: workspace.canStart)
        IOSQuickNoteComposer(store: store)
        ScrollView(.horizontal, showsIndicators: false) {
            HStack {
                filterButton("全部", .all)
                filterButton("收件箱", .inbox)
                ForEach(workspace.projects) { project in filterButton(project.name, .project(project.name)) }
            }
        }
        IOSQuickNoteCardList(store: store, cards: visibleCards, projects: workspace.projects,
                             inspectedID: workspace.resolvedSelectedCard(for: filter)?.id, selection: $selection)
        .onChange(of: workspace.projects) {
            if case .project(let name) = filter, !workspace.projects.contains(where: { $0.name == name }) {
                filter = .all
            }
        }
        .onChange(of: visibleCards.map(\.id)) { _, ids in selection?.formIntersection(ids) }
        if selection == nil, let card = workspace.resolvedSelectedCard(for: filter) {
            inspector(card)
        }
    }

    private func filterButton(_ title: String, _ value: QuickNoteFilterSelection) -> some View {
        Button(title) {
            filter = value
            selection = nil
        }
        .buttonStyle(.bordered)
        .tint(filter == value ? IOSColors.accent : IOSColors.textSecondary)
        .accessibilityAddTraits(filter == value ? .isSelected : [])
    }

    @ViewBuilder
    private func inspector(_ card: QuickNoteCardSnapshot) -> some View {
        Text(card.title).font(.headline)
        IOSCard {
            VStack(alignment: .leading, spacing: 8) {
                Text("闪记原文").font(.headline)
                IOSWorkspaceTranscript(segments: card.segments, recordID: card.id, title: card.title, onOpenSource: onOpenSource)
                if card.segments.isEmpty { Text("暂无原文。").foregroundStyle(.secondary) }
            }
        }
        IOSCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("AI 分析").font(.headline)
                if let gist = card.gist { Text(gist) }
                ForEach(card.topics) { topic in
                    Text(topic.title).font(.subheadline.bold())
                    Text(topic.summary)
                    IOSWorkspaceSources(sources: topic.sources, onOpenSource: onOpenSource)
                }
                if card.gist == nil && card.topics.isEmpty {
                    Text("尚未生成 AI 分析。").foregroundStyle(.secondary)
                }
            }
        }
        if !card.nextSteps.isEmpty {
            IOSCard {
                VStack(alignment: .leading, spacing: 8) {
                    Text("下一步确认").font(.headline)
                    ForEach(card.nextSteps) { item in
                        IOSWorkspaceReviewRow(item: item, store: store, onOpenSource: onOpenSource)
                    }
                }
            }
        }
        IOSPrimaryButton("打开完整详情", isPrimary: false) { onSelectRecord(card.id) }
        IOSWorkspaceExport(title: "导出闪记 Markdown") { analysis, sources in
            .forQuickNote(card, includeAnalysis: analysis, includeSources: sources)
        }
    }
}

struct IOSQuickNoteCardList: View {
    let store: HostSessionStore
    let cards: [QuickNoteCardSnapshot]
    let projects: [QuickNoteProjectCountSnapshot]
    let inspectedID: String?
    @Binding var selection: Set<String>?

    var body: some View {
        HStack {
            Button(selection != nil ? "取消多选" : "多选") {
                selection = selection == nil ? [] : nil
            }
            if let selectedIDs = selection {
                Spacer()
                IOSProjectMenu(title: "批量归类（\(selectedIDs.count)）", projects: projects) { project in
                    let ids = cards.map(\.id).filter(selectedIDs.contains)
                    guard !ids.isEmpty else { return }
                    if store.sendReturningError(.batchSetRecordProject(recordIds: ids, project: project)) == nil {
                        selection = nil
                    }
                }.disabled(selectedIDs.isEmpty)
            }
        }
        if cards.isEmpty {
            Text("此分类暂无闪记。").foregroundStyle(.secondary)
        }
        ForEach(cards) { card in
            cardRow(card)
        }
    }

    private func cardRow(_ card: QuickNoteCardSnapshot) -> some View {
        IOSCard {
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    if let selectedIDs = selection {
                        if selectedIDs.contains(card.id) {
                            selection?.remove(card.id)
                        } else {
                            selection?.insert(card.id)
                        }
                    } else {
                        store.send(.selectQuickNoteRecord(recordId: card.id))
                    }
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(card.title).font(.headline)
                            Text("\(TimeLabel.date(card.createdAtEpochSec))  |  \(card.project ?? "收件箱")  |  \(card.status)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let selectedIDs = selection {
                            Image(systemName: selectedIDs.contains(card.id) ? "checkmark.circle.fill" : "circle")
                        } else if inspectedID == card.id {
                            Image(systemName: "checkmark").foregroundStyle(IOSColors.accent)
                        }
                    }
                    .contentShape(Rectangle())
                }.buttonStyle(.plain)
                if selection == nil {
                    IOSProjectMenu(title: "项目归类", projects: projects) { project in
                        store.send(.setRecordProject(recordId: card.id, project: project))
                    }
                }
            }
        }
    }
}

struct IOSProjectMenu: View {
    let title: String
    let projects: [QuickNoteProjectCountSnapshot]
    let assign: (String?) -> Void
    @State private var creating = false
    @State private var name = ""

    var body: some View {
        Menu {
            ForEach(projects) { project in Button(project.name) { assign(project.name) } }
            Button("新建项目…") {
                name = ""
                creating = true
            }
            Button("移回收件箱") { assign(nil) }
        } label: {
            Label(title, systemImage: "folder")
        }
        .alert("新建项目", isPresented: $creating) {
            TextField("项目名称", text: $name)
                .onSubmit { submitName() }
            Button("取消", role: .cancel) {}
            Button("归入项目") { submitName() }.disabled(trimmedName.isEmpty)
        }
    }

    private func submitName() {
        guard !trimmedName.isEmpty else { return }
        assign(trimmedName)
        creating = false
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
}
