import KoeAppleCore
import SwiftUI
import UniformTypeIdentifiers

struct IOSRecordsView: View {
    let store: HostSessionStore
    let onSelectRecord: (String) -> Void
    @Environment(IOSFileActions.self) private var files

    @State private var searchQuery = ""
    @State private var filterCategory: RecordFilterCategory = .all
    @State private var showingTrashSheet = false
    @State private var importing = false
    @State private var selecting = false
    @State private var selectedIDs: Set<String> = []

    var body: some View {
        let filteredRecords = store.records.filter {
            $0.matches(filter: filterCategory, query: searchQuery)
        }
        let trashCount = store.navigation.trashCount
        let selectedRecords = store.records.map(\.id).filter(selectedIDs.contains)

        VStack(spacing: 0) {
            VStack(spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: AppFontSizes.xs))
                        .foregroundStyle(IOSColors.textMuted)
                    TextField("搜索记录标题或内容…", text: $searchQuery)
                        .font(.system(size: AppFontSizes.sm))
                        .foregroundStyle(IOSColors.textPrimary)
                        .submitLabel(.search)
                        .accessibilityIdentifier("records-search-input")
                        .onSubmit {}
                    if !searchQuery.isEmpty {
                        Button {
                            searchQuery = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: AppFontSizes.sm))
                                .foregroundStyle(IOSColors.textMuted)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("清空搜索")
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(IOSColors.surface1, in: RoundedRectangle(cornerRadius: IOSRadii.control))
                .overlay(
                    RoundedRectangle(cornerRadius: IOSRadii.control)
                        .stroke(IOSColors.border, lineWidth: 1)
                )

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(RecordFilterCategory.allCases) { category in
                            let selected = filterCategory == category
                            Button {
                                filterCategory = category
                            } label: {
                                Text(category.title)
                                    .font(.system(size: AppFontSizes.xs, weight: selected ? .semibold : .medium))
                                    .foregroundStyle(selected ? IOSColors.onAccent : IOSColors.textSecondary)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 7)
                                    .background(selected ? IOSColors.accent : IOSColors.surface1, in: Capsule())
                                    .overlay(
                                        Capsule()
                                            .stroke(selected ? IOSColors.accent : IOSColors.border, lineWidth: 1)
                                    )
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(IOSColors.bgPanel)

            if filteredRecords.isEmpty {
                ScrollView {
                    IOSEmptyState(
                        icon: "tray",
                        title: "暂无匹配记录",
                        detail: "切换筛选条件，或在今天页保存文字闪记与录音。"
                    )
                }
                .background(IOSColors.bgPanel)
            } else {
                List(selection: selecting ? $selectedIDs : nil) {
                    ForEach(filteredRecords) { record in
                        Group {
                            if selecting {
                                recordRow(record)
                                    .contentShape(Rectangle())
                                    .tag(record.id)
                            } else {
                                Button {
                                    onSelectRecord(record.id)
                                } label: {
                                    recordRow(record)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    if record.canTrash && store.navigation.savingRecordId != record.id {
                                        Button(role: .destructive) {
                                            store.send(.trashRecord(recordId: record.id))
                                        } label: {
                                            Label("移入回收站", systemImage: "trash")
                                        }
                                    }
                                }
                            }
                        }
                        .accessibilityIdentifier("records-row-\(record.id)")
                        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                    }
                }
                .environment(\.editMode, .constant(selecting ? .active : .inactive))
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .background(IOSColors.bgPanel)
            }
        }
        .navigationTitle(selecting ? "已选 \(selectedRecords.count)" : "记录")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarLeading) {
                if selecting {
                    Button("取消") {
                        selectedIDs.removeAll()
                        selecting = false
                    }
                    .accessibilityIdentifier("records-cancel-selection")
                    Button("导出所选记录", systemImage: "square.and.arrow.up") {
                        files.exportRecords(selectedRecords)
                    }
                    .labelStyle(.iconOnly)
                    .disabled(selectedRecords.isEmpty)
                    .accessibilityIdentifier("records-export-button")
                } else {
                    Button("导入", systemImage: "square.and.arrow.down") {
                        importing = true
                    }
                    .labelStyle(.iconOnly)
                    .accessibilityIdentifier("records-import-button")
                    Menu {
                        Button("选择记录", systemImage: "checkmark.circle") { selecting = true }
                            .disabled(store.records.isEmpty)
                            .accessibilityIdentifier("records-select-button")
                        Button(trashCount > 0 ? "回收站 (\(trashCount))" : "回收站", systemImage: "trash") {
                            showingTrashSheet = true
                        }
                        .accessibilityIdentifier("records-trash-button")
                    } label: {
                        Label("更多记录操作", systemImage: "ellipsis.circle")
                    }
                    .accessibilityIdentifier("records-menu")
                }
            }
        }
        .fileImporter(
            isPresented: $importing,
            allowedContentTypes: [.wav, .plainText, UTType(filenameExtension: "md") ?? .text,
                                  UTType(filenameExtension: "koepack") ?? .data]
        ) { result in
            switch result {
            case .success(let url): Task { await files.importFile(url) }
            case .failure(let error): files.pickerFailed(error)
            }
        }
        .sheet(isPresented: $showingTrashSheet) {
            IOSTrashView(store: store)
        }
    }

    private func recordRow(_ record: RecordSnapshot) -> some View {
        IOSCard {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .center, spacing: 8) {
                    Text(record.title)
                        .font(.system(size: AppFontSizes.md, weight: .semibold))
                        .foregroundStyle(IOSColors.textPrimary)
                        .lineLimit(1)
                    Spacer()
                    IOSBadge(record.modeLabel, tint: IOSColors.textSecondary)
                }

                if !record.preview.isEmpty {
                    Text(record.preview)
                        .font(.system(size: AppFontSizes.xs))
                        .foregroundStyle(IOSColors.textSecondary)
                        .lineLimit(2)
                }

                HStack(spacing: 8) {
                    Text(TimeLabel.date(record.createdAtEpochSec))
                    Text("|")
                    Text(record.durationMs > 0 ? TimeLabel.duration(record.durationMs) : "\(record.segmentCount) 段")
                        .monospacedDigit()
                    Text("|")
                    Text(record.status)
                    Spacer()
                    if record.archived {
                        IOSBadge("已归档", tint: IOSColors.textMuted)
                    }
                }
                .font(.system(size: AppFontSizes.xs))
                .foregroundStyle(IOSColors.textMuted)
            }
        }
    }
}

enum IOSTrashRemoval {
    case record(String)
    case all

    var title: String {
        switch self {
        case .record: "彻底删除这条记录？"
        case .all: "清空回收站？"
        }
    }

    @MainActor
    func confirm(in store: HostSessionStore) {
        switch self {
        case .record(let id): store.send(.purgeRecord(recordId: id))
        case .all: store.send(.emptyTrash)
        }
    }
}

struct IOSTrashView: View {
    let store: HostSessionStore
    @Environment(\.dismiss) private var dismiss
    @State private var pendingRemoval: IOSTrashRemoval?

    var body: some View {
        let trashRecords = store.trashRecords
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if trashRecords.isEmpty {
                        IOSEmptyState(
                            icon: "trash",
                            title: "回收站为空",
                            detail: "左滑记录可随时移入回收站，并在 30 天内恢复。"
                        )
                    } else {
                        ForEach(trashRecords) { item in
                            IOSCard {
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack {
                                        Text(item.title)
                                            .font(.system(size: AppFontSizes.sm, weight: .semibold))
                                            .foregroundStyle(IOSColors.textPrimary)
                                            .lineLimit(1)
                                        Spacer()
                                        IOSBadge("剩余 \(item.remainingDays) 天", tint: IOSColors.textMuted)
                                    }
                                    if !item.preview.isEmpty {
                                        Text(item.preview)
                                            .font(.system(size: AppFontSizes.xs))
                                            .foregroundStyle(IOSColors.textSecondary)
                                            .lineLimit(2)
                                    }
                                    HStack(spacing: 8) {
                                        IOSPrimaryButton("恢复", systemImage: "arrow.uturn.backward", isPrimary: true) {
                                            store.send(.restoreRecord(recordId: item.id))
                                        }
                                        IOSPrimaryButton("彻底删除", systemImage: "trash", isPrimary: false) {
                                            pendingRemoval = .record(item.id)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(16)
            }
            .background(IOSColors.bgPanel)
            .confirmationDialog(
                pendingRemoval?.title ?? "", isPresented: Binding(
                    get: { pendingRemoval != nil },
                    set: { if !$0 { pendingRemoval = nil } }
                ), titleVisibility: .visible, presenting: pendingRemoval
            ) { removal in
                Button("确认永久删除", role: .destructive) { removal.confirm(in: store) }
                Button("取消", role: .cancel) {}
            } message: { _ in
                Text("记录及其音频文件将被永久删除，无法恢复。")
            }
            .navigationTitle("回收站")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if !trashRecords.isEmpty {
                        IOSPrimaryButton("清空", isPrimary: false) {
                            pendingRemoval = .all
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    IOSPrimaryButton("完成", isPrimary: false) {
                        dismiss()
                    }
                }
            }
        }
    }
}
