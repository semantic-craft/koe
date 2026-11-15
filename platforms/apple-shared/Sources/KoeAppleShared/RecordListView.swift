import SwiftUI

struct RecordListView: View {
    let store: HostSessionStore
    @State private var selectedFilter: RecordFilterCategory = .all
    @State private var searchQuery = ""
    @FocusState private var isSearchFocused: Bool

    private var filtered: [RecordSnapshot] {
        store.snapshot.records.filter { $0.matches(filter: selectedFilter, query: searchQuery) }
    }

    private func categoryCount(_ category: RecordFilterCategory) -> Int? {
        let count = store.snapshot.records.filter { $0.matches(filter: category, query: "") }.count
        if category == .all { return count }
        return count > 0 ? count : nil
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PageHeading(title: "所有记录", subtitle: "按工作模式、收件箱或归档状态检索每一条原始记录。")

                searchAndFilters

                if store.snapshot.records.isEmpty {
                    EmptyState(
                        icon: "tray.full",
                        title: "还没有记录",
                        detail: "通过右上角导入文字、Markdown、WAV 或资料包，也可以新建文字记录。"
                    )
                } else if filtered.isEmpty {
                    EmptyState(
                        icon: "magnifyingglass",
                        title: "没有匹配的记录",
                        detail: "尝试切换上方筛选分类或清空搜索关键词。"
                    )
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(filtered) { record in
                            RecordRow(record: record, store: store)
                        }
                    }
                }
            }
            .padding(30)
        }
    }

    private var searchAndFilters: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: AppFontSizes.xs))
                    .foregroundStyle(AppColors.textMuted)
                TextField("搜索标题、原文预览或项目名称", text: $searchQuery)
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
}

struct RecordRow: View {
    let record: RecordSnapshot
    let store: HostSessionStore

    private var metadataLine: String {
        var parts = [TimeLabel.date(record.createdAtEpochSec), record.source]
        if record.durationMs > 0 {
            parts.append(TimeLabel.duration(record.durationMs))
        }
        return parts.joined(separator: "  ")
    }

    var body: some View {
        Button {
            store.send("select_record", ["recordId": record.id])
        } label: {
            HStack(spacing: 14) {
                Image(systemName: record.durationMs > 0 ? "waveform" : "doc.text")
                    .foregroundStyle(AppColors.accent)
                    .frame(width: 38, height: 38)
                    .background(AppColors.bgSubtle, in: RoundedRectangle(cornerRadius: 7))
                VStack(alignment: .leading, spacing: 6) {
                    Text(record.title)
                        .font(.system(size: AppFontSizes.sm, weight: .medium))
                        .lineLimit(1)
                    Text(record.preview.isEmpty ? record.source : record.preview)
                        .font(.system(size: AppFontSizes.xs))
                        .foregroundStyle(AppColors.textMuted)
                        .lineLimit(1)
                    Text(metadataLine)
                        .font(.system(size: AppFontSizes.xs))
                        .foregroundStyle(AppColors.textMuted)
                }
                Spacer(minLength: 10)
                KoeBadge(record.modeLabel, tint: AppColors.accent)
                if let project = record.project, !project.isEmpty {
                    KoeBadge(project, tint: AppColors.textSecondary)
                } else if record.isQuickNoteInbox {
                    KoeBadge("收件箱", tint: AppColors.warning)
                }
                if record.archived {
                    KoeBadge("已归档", tint: AppColors.textSecondary)
                }
                KoeBadge(record.status)
                Image(systemName: "chevron.right")
                    .font(.system(size: AppFontSizes.xs))
                    .foregroundStyle(AppColors.textMuted)
            }
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .bottom) { Rectangle().fill(AppColors.border).frame(height: 1) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
