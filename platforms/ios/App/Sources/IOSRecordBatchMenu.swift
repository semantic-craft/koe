import KoeAppleCore
import SwiftUI

struct IOSRecordBatchMenu: View {
    let store: HostSessionStore
    let selected: [RecordSnapshot]
    let projects: [String]
    let onSuccess: () -> Void

    var body: some View {
        let ids = selected.map(\.id)
        let trashable = selected.filter { $0.canTrash && $0.id != store.navigation.savingRecordId }.map(\.id)
        IOSProjectMenu(title: "批量归类", projects: projects) { project in
            perform(.batchSetRecordProject(recordIds: ids, project: project))
        }.labelStyle(.iconOnly).disabled(ids.isEmpty)
        Menu {
            Button("批量归档") { perform(.batchSetRecordArchived(recordIds: ids, archived: true)) }
            Button("移入回收站（\(trashable.count)）", role: .destructive) {
                perform(.batchTrashRecords(recordIds: trashable))
            }.disabled(trashable.isEmpty)
        } label: {
            Label("批量操作", systemImage: "ellipsis.circle").labelStyle(.iconOnly)
        }.disabled(ids.isEmpty)
    }

    private func perform(_ command: HostCommand) {
        if store.sendReturningError(command) == nil { onSuccess() }
    }
}
