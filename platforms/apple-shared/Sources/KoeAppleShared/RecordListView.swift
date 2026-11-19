import SwiftUI

struct RecordListView: View {
    let store: HostSessionStore
    private let onExportRecord: (String) -> Void
    private let onExportRecords: ([String]) -> Void

    @State private var selectedFilter: RecordFilterCategory = .all
    @State private var selectedProjectFilter: RecordProjectFilter = .all
    @State private var sortOrder: RecordSortOrder = .newest
    @State private var searchQuery = ""
    @State private var isManaging = false
    @State private var selectedIds: Set<String> = []
    @State private var renamingRecordId: String?
    @State private var renameDraft = ""
    @FocusState private var isSearchFocused: Bool

    init(
        store: HostSessionStore,
        onExportRecord: @escaping (String) -> Void = { _ in },
        onExportRecords: @escaping ([String]) -> Void = { _ in }
    ) {
        self.store = store
        self.onExportRecord = onExportRecord
        self.onExportRecords = onExportRecords
    }

    private var distinctProjects: [String] {
        RecordListFormatting.distinctProjects(from: store.records)
    }

    private var filtered: [RecordSnapshot] {
        let matched = store.records.filter {
            $0.matches(
                filter: selectedFilter,
                projectFilter: selectedProjectFilter,
                query: searchQuery
            )
        }
        return sortOrder.sort(matched)
    }

    private var selectedVisibleRecords: [RecordSnapshot] {
        filtered.filter { selectedIds.contains($0.id) }
    }

    private var allVisibleSelected: Bool {
        !filtered.isEmpty && filtered.allSatisfy { selectedIds.contains($0.id) }
    }

    private var summaryMetaText: String {
        let countText = "共 \(filtered.count) 条"
        let totalMs = filtered.reduce(UInt64(0)) { $0 + $1.durationMs }
        if let durationText = RecordListFormatting.totalDurationLabel(ms: totalMs) {
            return "\(countText)  总时长 \(durationText)"
        }
        return countText
    }

    private func categoryCount(_ category: RecordFilterCategory) -> Int? {
        let count = store.records.filter {
            $0.matches(filter: category, projectFilter: selectedProjectFilter, query: "")
        }.count
        if category == .all { return count }
        return count > 0 ? count : nil
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    headerBar
                    searchAndFilters

                    if isManaging && !filtered.isEmpty {
                        selectionControlStrip
                    }

                    if store.records.isEmpty {
                        EmptyState(
                            icon: "tray.full",
                            title: "还没有记录",
                            detail: "开始录音或通过右上角导入音频、文字、Markdown 与资料包。"
                        )
                    } else if filtered.isEmpty {
                        EmptyState(
                            icon: "magnifyingglass",
                            title: "没有匹配的记录",
                            detail: "尝试切换上方筛选分类、项目条件或清空搜索关键词。"
                        )
                    } else {
                        LazyVStack(spacing: 0) {
                            ForEach(filtered) { record in
                                RecordRow(
                                    record: record,
                                    store: store,
                                    projects: distinctProjects,
                                    isManaging: isManaging,
                                    isSelected: selectedIds.contains(record.id),
                                    isRenaming: renamingRecordId == record.id,
                                    renameDraft: $renameDraft,
                                    onToggleSelect: { toggleSelection(record.id) },
                                    onBeginRename: { beginRename(record) },
                                    onCommitRename: { commitRename(record.id) },
                                    onCancelRename: { cancelRename() },
                                    onExportRecord: onExportRecord
                                )
                            }
                        }
                    }
                }
                .padding(30)
            }

            if isManaging {
                BatchRecordActionBar(
                    selectedRecords: selectedVisibleRecords,
                    existingProjects: distinctProjects,
                    onAssignProject: { project in
                        let ids = selectedVisibleRecords.map(\.id)
                        guard !ids.isEmpty else { return }
                        store.send(.batchSetRecordProject(recordIds: ids, project: project))
                    },
                    onSetArchived: { archived in
                        let ids = selectedVisibleRecords.map(\.id)
                        guard !ids.isEmpty else { return }
                        store.send(.batchSetRecordArchived(recordIds: ids, archived: archived))
                    },
                    onExportMarkdown: {
                        let ids = selectedVisibleRecords.map(\.id)
                        guard !ids.isEmpty else { return }
                        onExportRecords(ids)
                    },
                    onTrash: {
                        let ids = selectedVisibleRecords.map(\.id)
                        guard !ids.isEmpty else { return }
                        store.send(.batchTrashRecords(recordIds: ids))
                    }
                )
            }
        }
        .onChange(of: store.records) { _, updated in
            let validIds = Set(updated.map(\.id))
            selectedIds = selectedIds.intersection(validIds)
            if let renaming = renamingRecordId, !validIds.contains(renaming) {
                cancelRename()
            }
            if case let .project(name) = selectedProjectFilter,
               !RecordListFormatting.distinctProjects(from: updated).contains(name) {
                selectedProjectFilter = .all
            }
            if updated.isEmpty && isManaging {
                isManaging = false
            }
        }
    }

    private var headerBar: some View {
        HStack(alignment: .top, spacing: 16) {
            PageHeading(
                title: "所有记录",
                subtitle: "检索、排序、归类并清理每一条录音与资料。"
            )
            Spacer(minLength: 12)
            HStack(spacing: 12) {
                if !store.records.isEmpty {
                    Text(summaryMetaText)
                        .font(.system(size: AppFontSizes.xs))
                        .foregroundStyle(AppColors.textMuted)
                        .monospacedDigit()
                    KoeActionButton(
                        isManaging ? "完成管理" : "批量管理",
                        systemImage: isManaging ? "checkmark" : "checklist",
                        isPrimary: isManaging
                    ) {
                        toggleManageMode()
                    }
                }
            }
            .padding(.top, 2)
        }
    }

    private var searchAndFilters: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: AppFontSizes.xs))
                        .foregroundStyle(AppColors.textMuted)
                    TextField("搜索标题、原文预览、来源或项目名称", text: $searchQuery)
                        .textFieldStyle(.roundedBorder)
                        .focused($isSearchFocused)
                        .onSubmit { isSearchFocused = false }
                    if !searchQuery.isEmpty {
                        Button {
                            searchQuery = ""
                        } label: {
                            Text("清除")
                                .font(.system(size: AppFontSizes.xs))
                                .foregroundStyle(AppColors.textSecondary)
                                .padding(.horizontal, 8)
                                .frame(minHeight: 30)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }

                if !distinctProjects.isEmpty || selectedProjectFilter != .all {
                    projectFilterMenu
                }

                sortOrderMenu
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(RecordFilterCategory.allCases) { category in
                        filterPill(
                            category.title,
                            count: categoryCount(category),
                            isSelected: selectedFilter == category
                        ) {
                            selectedFilter = category
                        }
                    }
                }
            }
        }
    }

    private var projectFilterMenu: some View {
        Menu {
            Button("全部项目") { selectedProjectFilter = .all }
            Button("未归类") { selectedProjectFilter = .unassigned }
            if !distinctProjects.isEmpty {
                Divider()
                ForEach(distinctProjects, id: \.self) { name in
                    Button(name) { selectedProjectFilter = .project(name) }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "folder")
                Text(selectedProjectFilter.title)
                    .lineLimit(1)
            }
            .font(.system(size: AppFontSizes.xs, weight: .medium))
            .foregroundStyle(AppColors.textPrimary)
            .padding(.horizontal, 11)
            .frame(minHeight: 32)
            .background(AppColors.bgSubtle, in: RoundedRectangle(cornerRadius: AppRadii.control))
            .overlay(RoundedRectangle(cornerRadius: AppRadii.control).stroke(AppColors.border))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var sortOrderMenu: some View {
        Menu {
            ForEach(RecordSortOrder.allCases) { order in
                Button {
                    sortOrder = order
                } label: {
                    if sortOrder == order {
                        Label(order.title, systemImage: "checkmark")
                    } else {
                        Text(order.title)
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.up.arrow.down")
                Text(sortOrder.title)
            }
            .font(.system(size: AppFontSizes.xs, weight: .medium))
            .foregroundStyle(AppColors.textPrimary)
            .padding(.horizontal, 11)
            .frame(minHeight: 32)
            .background(AppColors.bgSubtle, in: RoundedRectangle(cornerRadius: AppRadii.control))
            .overlay(RoundedRectangle(cornerRadius: AppRadii.control).stroke(AppColors.border))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var selectionControlStrip: some View {
        HStack(spacing: 12) {
            KoeActionButton(
                allVisibleSelected ? "取消全选" : "全选当前列表 (\(filtered.count))",
                systemImage: allVisibleSelected ? "checkmark.square.fill" : "square"
            ) {
                if allVisibleSelected {
                    selectedIds.subtract(filtered.map(\.id))
                } else {
                    selectedIds.formUnion(filtered.map(\.id))
                }
            }
            Text("已选 \(selectedVisibleRecords.count) 条")
                .font(.system(size: AppFontSizes.xs))
                .foregroundStyle(AppColors.textSecondary)
                .monospacedDigit()
            Spacer()
            if !selectedVisibleRecords.isEmpty {
                Button {
                    selectedIds.removeAll()
                } label: {
                    Text("清空选择")
                        .font(.system(size: AppFontSizes.xs))
                        .foregroundStyle(AppColors.textSecondary)
                        .padding(.horizontal, 8)
                        .frame(minHeight: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(AppColors.bgPanel, in: RoundedRectangle(cornerRadius: AppRadii.control))
        .overlay(RoundedRectangle(cornerRadius: AppRadii.control).stroke(AppColors.border))
    }

    private func filterPill(
        _ title: String,
        count: Int? = nil,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(title)
                if let count {
                    Text("\(count)").monospacedDigit()
                }
            }
            .font(.system(size: AppFontSizes.xs, weight: isSelected ? .medium : .regular))
            .foregroundStyle(isSelected ? AppColors.accent : AppColors.textMuted)
            .padding(.horizontal, 11)
            .frame(minHeight: 30)
            .background(
                isSelected ? AppColors.accentSoft : AppColors.bgSubtle,
                in: RoundedRectangle(cornerRadius: AppRadii.control)
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppRadii.control)
                    .stroke(isSelected ? AppColors.accent.opacity(0.35) : AppColors.border)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func toggleManageMode() {
        isManaging.toggle()
        if isManaging {
            cancelRename()
        } else {
            selectedIds.removeAll()
        }
    }

    private func toggleSelection(_ id: String) {
        if selectedIds.contains(id) {
            selectedIds.remove(id)
        } else {
            selectedIds.insert(id)
        }
    }

    private func beginRename(_ record: RecordSnapshot) {
        renamingRecordId = record.id
        renameDraft = record.title
    }

    private func commitRename(_ id: String) {
        let trimmed = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        store.send(.renameRecord(recordId: id, title: trimmed))
        if store.navigation.effectiveError == nil {
            cancelRename()
        }
    }

    private func cancelRename() {
        renamingRecordId = nil
        renameDraft = ""
    }
}
