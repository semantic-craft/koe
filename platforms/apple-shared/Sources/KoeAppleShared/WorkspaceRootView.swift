import SwiftUI

public struct KoeWorkspaceRootView: View {
    public let store: HostSessionStore
    private let importAction: () -> Void
    private let exportAction: (String) -> Void
    let exportWorkspaceAction: (WorkspaceExportRequest) -> Void
    @State private var showNewNote = false

    public init(
        store: HostSessionStore,
        onImport: @escaping () -> Void = {},
        onExport: @escaping (String) -> Void = { _ in },
        onExportWorkspace: @escaping (WorkspaceExportRequest) -> Void = { _ in }
    ) {
        self.store = store
        importAction = onImport
        exportAction = onExport
        exportWorkspaceAction = onExportWorkspace
    }

    public var body: some View {
        let nav = store.navigation
        HStack(spacing: 0) {
            SidebarView(store: store)
            Rectangle().fill(AppColors.border).frame(width: 1)
            VStack(spacing: 0) {
                toolbar(nav)
                if nav.section != "live_minutes" {
                    LiveCaptionBar(store: store)
                }
                if let message = nav.effectiveError {
                    HStack(spacing: 10) {
                        Image(systemName: "exclamationmark.circle")
                        Text(message).textSelection(.enabled)
                        Spacer()
                        Button("关闭") { store.clearError() }.buttonStyle(.borderless)
                    }.font(.system(size: AppFontSizes.xs)).foregroundStyle(AppColors.danger)
                        .padding(12).background(AppColors.danger.opacity(0.08))
                } else if let notice = nav.notice, !notice.isEmpty {
                    HStack { Text(notice); Spacer() }.font(.system(size: AppFontSizes.xs))
                        .foregroundStyle(AppColors.textSecondary).padding(12).background(AppColors.surface1)
                }
                page(nav.section).frame(maxWidth: .infinity, maxHeight: .infinity)
                ActiveCaptureBar(store: store, isLiveMinutesSection: nav.section == "live_minutes")
                if let undo = nav.undoTrash {
                    UndoTrashBar(undo: undo, store: store)
                }
                if nav.hasPlayableDetailAsset {
                    PlayerBarView(store: store)
                }
            }.background(AppColors.surface0)
        }
        .foregroundStyle(AppColors.textPrimary).tint(AppColors.accent)
        .preferredColorScheme(.light).frame(minWidth: 1040, minHeight: 680)
        .overlay {
            if nav.hasConnectGuide {
                ZStack {
                    Color.black.opacity(0.58)
                        .ignoresSafeArea()
                        .onTapGesture { store.send(.deviceCloseGuide) }
                    ConnectGuideSheet(store: store)
                }
            }
        }
        .sheet(isPresented: $showNewNote) { NewNoteSheet(store: store) }
    }

    private func toolbar(_ nav: NavigationChromeSlice) -> some View {
        HStack(spacing: 12) {
            Button { store.send(.back) } label: {
                Image(systemName: "chevron.left").frame(width: 30, height: 34).contentShape(Rectangle())
            }.buttonStyle(.plain).disabled(!nav.canGoBack).help("返回上一页")
            Text(sectionTitle(nav)).font(.system(size: AppFontSizes.xs)).foregroundStyle(AppColors.textSecondary)
            Spacer()
            if let detailId = nav.detailId, nav.section == "detail" {
                KoeActionButton("问这条记录", systemImage: "sparkles") {
                    store.send(.setAskScope(scope: "record", recordId: detailId))
                    store.send(.navigate(section: "ask"))
                }
                KoeActionButton("导出") { exportAction(detailId) }
            }
            if nav.section == "records" {
                KoeActionButton("回收站", systemImage: "trash") {
                    store.send(.navigate(section: "trash"))
                }
            }
            KoeActionButton("新建记录", systemImage: "plus") { showNewNote = true }
                .keyboardShortcut("n", modifiers: .command)
            KoeActionButton("导入", systemImage: "square.and.arrow.down", isPrimary: true, action: importAction)
                .keyboardShortcut("o", modifiers: .command)
        }
        .padding(.horizontal, 22).frame(height: 62)
        .overlay(alignment: .bottom) { Rectangle().fill(AppColors.border).frame(height: 1) }
    }

    private func sectionTitle(_ nav: NavigationChromeSlice) -> String {
        HostSection.title(for: nav.section, detailTitle: nav.detailTitle)
    }

    @ViewBuilder private func page(_ section: String) -> some View {
        switch section {
        case "capture": CaptureView(store: store)
        case "notes": QuickNoteWorkspaceView(store: store, onExportWorkspace: exportWorkspaceAction)
        case "all_day": AllDayWorkspaceView(store: store, onExportWorkspace: exportWorkspaceAction)
        case "records": RecordListView(store: store)
        case "detail": RecordDetailView(store: store)
        case "tasks": TasksView(store: store)
        case "memory": MemoryView(store: store)
        case "live_minutes": LiveMinutesView(store: store, onExportWorkspace: exportWorkspaceAction)
        case "ask": AskView(store: store)
        case "trash": TrashView(store: store)
        case "settings": SettingsDoctorView(store: store)
        default: TodayView(store: store)
        }
    }
}

private struct UndoTrashBar: View {
    let undo: UndoTrashSnapshot
    let store: HostSessionStore

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "trash")
                .font(.system(size: AppFontSizes.xs))
                .foregroundStyle(AppColors.textMuted)
            Text("已将《\(undo.title)》移入回收站")
                .font(.system(size: AppFontSizes.xs))
                .foregroundStyle(AppColors.textSecondary)
                .lineLimit(1)
            Spacer()
            KoeActionButton("撤销", systemImage: "arrow.uturn.backward") {
                store.send(.restoreRecord(recordId: undo.recordId))
            }
            Button {
                store.send(.dismissUndoTrash)
            } label: {
                Text("关闭")
                    .font(.system(size: AppFontSizes.xs))
                    .foregroundStyle(AppColors.textMuted)
                    .padding(.horizontal, 8)
                    .frame(minHeight: 34)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 10)
        .background(AppColors.surface1)
        .overlay(alignment: .top) { Rectangle().fill(AppColors.border).frame(height: 1) }
    }
}

private struct NewNoteSheet: View {
    let store: HostSessionStore
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var text = ""
    @FocusState private var focusTitle: Bool
    var body: some View {
        let error = store.navigation.effectiveError
        VStack(alignment: .leading, spacing: 18) {
            PageHeading(title: "新建记录", subtitle: "写下真实的想法和讨论，之后可以整理、标记和提问。")
            TextField("标题", text: $title).textFieldStyle(.roundedBorder)
                .focused($focusTitle).onSubmit { save() }
            TextEditor(text: $text).font(.system(size: AppFontSizes.sm)).scrollContentBackground(.hidden)
                .padding(8).frame(height: 220).background(AppColors.bgSubtle, in: RoundedRectangle(cornerRadius: 6))
            if let error {
                Text(error).font(.system(size: AppFontSizes.xs)).foregroundStyle(AppColors.danger)
            }
            HStack {
                Spacer()
                KoeActionButton("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                KoeActionButton("保存记录", isPrimary: true) { save() }
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .keyboardShortcut(.return, modifiers: .command)
            }
        }.padding(28).frame(width: 570).background(AppColors.surface0)
            .foregroundStyle(AppColors.textPrimary).preferredColorScheme(.light)
            .onAppear { focusTitle = true }
    }
    private func save() {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        store.send(.createNote(title: title, text: text))
        if store.navigation.effectiveError == nil { dismiss() }
    }
}
