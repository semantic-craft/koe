import KoeAppleCore
import SwiftUI

struct IOSItemEditorSheet: View {
    let store: HostSessionStore
    let id: String
    let isTask: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var due: String
    @FocusState private var editingDue: Bool

    init(store: HostSessionStore, task: TaskSnapshot) {
        self.store = store
        id = task.id
        isTask = true
        _text = State(initialValue: task.text)
        _due = State(initialValue: task.due ?? "")
    }

    init(store: HostSessionStore, memory: MemorySnapshot) {
        self.store = store
        id = memory.id
        isTask = false
        _text = State(initialValue: memory.text)
        _due = State(initialValue: "")
    }

    var body: some View {
        IOSEditForm(title: isTask ? "编辑待办" : "编辑记忆", text: $text, store: store) {
            if isTask {
                TextField("截止时间（可选）", text: $due)
                    .focused($editingDue)
                    .submitLabel(.done)
                    .onSubmit { editingDue = false }
            }
        } save: { value in
            save(value, deadline: due)
        }
    }

    func save(_ value: String, deadline: String) {
        let trimmed = deadline.trimmingCharacters(in: .whitespacesAndNewlines)
        if store.sendReturningError(.editItem(itemId: id, text: value, due: trimmed.isEmpty ? nil : trimmed)) == nil {
            dismiss()
        }
    }
}
