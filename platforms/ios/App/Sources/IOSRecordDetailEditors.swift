import KoeAppleCore
import SwiftUI

enum IOSRecordEdit: Identifiable {
    case title(RecordDetailSnapshot)
    case text(String, SegmentSnapshot)
    case speaker(String, SegmentSnapshot)
    case renameSpeaker(String, String)

    var id: String {
        switch self {
        case .title(let detail): "title-\(detail.id)"
        case .text(_, let segment): "text-\(segment.id)"
        case .speaker(_, let segment): "speaker-\(segment.id)"
        case .renameSpeaker(_, let speaker): "rename-\(speaker)"
        }
    }

    var label: String {
        switch self {
        case .title: "重命名"
        case .text: "编辑原文"
        case .speaker: "修改本段说话人"
        case .renameSpeaker: "改名或合并说话人"
        }
    }

    var initialText: String {
        switch self {
        case .title(let detail): detail.title
        case .text(_, let segment): segment.text
        case .speaker(_, let segment): segment.speaker ?? ""
        case .renameSpeaker(_, let speaker): speaker
        }
    }

    func command(_ value: String) -> HostCommand {
        switch self {
        case .title(let detail): .renameRecord(recordId: detail.id, title: value)
        case .text(let id, let segment): .editSegmentText(recordId: id, segmentId: segment.id, text: value)
        case .speaker(let id, let segment): .setSegmentSpeaker(recordId: id, segmentId: segment.id, speaker: value.isEmpty ? nil : value)
        case .renameSpeaker(let id, let original): .renameSpeaker(recordId: id, fromSpeaker: original, toSpeaker: value)
        }
    }
}

struct IOSRecordEditorSheet: View {
    let store: HostSessionStore
    let edit: IOSRecordEdit
    @Environment(\.dismiss) private var dismiss
    @State private var text: String

    init(store: HostSessionStore, edit: IOSRecordEdit) {
        self.store = store
        self.edit = edit
        _text = State(initialValue: edit.initialText)
    }

    var body: some View {
        IOSEditForm(title: edit.label, text: $text, store: store, allowsEmpty: allowsEmpty) {
            if case .renameSpeaker = edit {
                Text("修改整条记录中该说话人的名称。使用已有名称可合并两位说话人。")
                    .foregroundStyle(.secondary)
            }
        } save: { save($0) }
    }

    func save(_ value: String) {
        if store.sendReturningError(edit.command(value)) == nil { dismiss() }
    }

    private var allowsEmpty: Bool {
        if case .speaker = edit { return true }
        return false
    }
}

struct IOSEditForm<Fields: View>: View {
    let title: String
    @Binding var text: String
    let store: HostSessionStore
    var allowsEmpty = false
    @ViewBuilder let fields: () -> Fields
    let save: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                TextField(title, text: $text, axis: .vertical).lineLimit(1...12)
                    .onSubmit { if allowsEmpty || !trimmed.isEmpty { save(trimmed) } }
                fields()
                IOSHostErrorBar(store: store)
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save(trimmed) }.disabled(!allowsEmpty && trimmed.isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
}
