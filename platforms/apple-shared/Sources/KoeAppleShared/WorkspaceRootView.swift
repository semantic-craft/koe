import SwiftUI

public struct KoeWorkspaceRootView: View {
    public let store: HostSessionStore
    private let importAction: () -> Void
    private let exportAction: (String) -> Void
    @State private var showNewNote = false

    public init(store: HostSessionStore, onImport: @escaping () -> Void = {}, onExport: @escaping (String) -> Void = { _ in }) {
        self.store = store
        importAction = onImport
        exportAction = onExport
    }
    public var body: some View {
        HStack(spacing: 0) {
            SidebarView(store: store)
            Rectangle().fill(AppColors.border).frame(width: 1)
            VStack(spacing: 0) {
                toolbar
                if store.snapshot.section != "live_minutes", let caption = store.snapshot.liveCaption {
                    LiveCaptionBar(caption: caption, store: store)
                }
                if let message = store.nativeError ?? store.snapshot.error {
                    HStack(spacing: 10) {
                        Image(systemName: "exclamationmark.circle")
                        Text(message).textSelection(.enabled)
                        Spacer()
                        Button("关闭") { store.clearError() }.buttonStyle(.borderless)
                    }.font(.system(size: AppFontSizes.xs)).foregroundStyle(AppColors.danger)
                        .padding(12).background(AppColors.danger.opacity(0.08))
                } else if let notice = store.snapshot.notice, !notice.isEmpty {
                    HStack { Text(notice); Spacer() }.font(.system(size: AppFontSizes.xs))
                        .foregroundStyle(AppColors.textSecondary).padding(12).background(AppColors.surface1)
                }
                page.frame(maxWidth: .infinity, maxHeight: .infinity)
                if let capture = store.snapshot.activeCapture {
                    ActiveCaptureBar(capture: capture, store: store)
                }
                if let undo = store.snapshot.undoTrash {
                    UndoTrashBar(undo: undo, store: store)
                }
                if store.snapshot.playback.asset != nil,
                   store.snapshot.playback.recordId == store.snapshot.detail?.id { PlayerBarView(store: store) }
            }.background(AppColors.surface0)
        }
        .foregroundStyle(AppColors.textPrimary).tint(AppColors.accent)
        .preferredColorScheme(.light).frame(minWidth: 1040, minHeight: 680)
        .overlay {
            if store.snapshot.device.guide != nil {
                ZStack {
                    Color.black.opacity(0.58)
                        .ignoresSafeArea()
                        .onTapGesture { store.send("device_close_guide") }
                    ConnectGuideSheet(store: store)
                }
            }
        }
        .sheet(isPresented: $showNewNote) { NewNoteSheet(store: store) }
    }
    private var toolbar: some View {
        HStack(spacing: 12) {
            Button { store.send("back") } label: {
                Image(systemName: "chevron.left").frame(width: 30, height: 34).contentShape(Rectangle())
            }.buttonStyle(.plain).disabled(!store.snapshot.canGoBack).help("返回上一页")
            Text(sectionTitle).font(.system(size: AppFontSizes.xs)).foregroundStyle(AppColors.textSecondary)
            Spacer()
            if let detail = store.snapshot.detail, store.snapshot.section == "detail" {
                KoeActionButton("问这条记录", systemImage: "sparkles") {
                    store.send("set_ask_scope", ["scope": "record", "recordId": detail.id])
                    store.send("navigate", ["section": "ask"])
                }
                KoeActionButton("导出") { exportAction(detail.id) }
            }
            if store.snapshot.section == "records" {
                KoeActionButton("回收站", systemImage: "trash") {
                    store.send("navigate", ["section": "trash"])
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
    private var sectionTitle: String {
        switch store.snapshot.section {
        case "capture": "设置 / 录音管理"
        case "notes": "随心记"
        case "records": "所有记录"
        case "detail": store.snapshot.detail?.title ?? "记录"
        case "tasks": "行动"
        case "memory": "记忆"
        case "live_minutes": "实时纪要"
        case "ask": "问 Koe"
        case "trash": "回收站"
        case "settings": "设置"
        default: "今天"
        }
    }
    @ViewBuilder private var page: some View {
        switch store.snapshot.section {
        case "capture": CaptureView(store: store)
        case "notes": NotesView(store: store)
        case "records": RecordListView(store: store)
        case "detail": RecordDetailView(store: store)
        case "tasks": TasksView(store: store)
        case "memory": MemoryView(store: store)
        case "live_minutes": LiveMinutesView(store: store)
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
                store.send("restore_record", ["recordId": undo.recordId])
            }
            Button {
                store.send("dismiss_undo_trash")
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
        VStack(alignment: .leading, spacing: 18) {
            PageHeading(title: "新建记录", subtitle: "写下真实的想法和讨论，之后可以整理、标记和提问。")
            TextField("标题", text: $title).textFieldStyle(.roundedBorder)
                .focused($focusTitle).onSubmit { save() }
            TextEditor(text: $text).font(.system(size: AppFontSizes.sm)).scrollContentBackground(.hidden)
                .padding(8).frame(height: 220).background(AppColors.bgSubtle, in: RoundedRectangle(cornerRadius: 6))
            if let error = store.nativeError ?? store.snapshot.error {
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
        store.send("create_note", ["title": title, "text": text])
        if store.snapshot.error == nil && store.nativeError == nil { dismiss() }
    }
}
