import AppKit
import KoeAppleShared
import UniformTypeIdentifiers

@MainActor
final class NativeFileActions {
    weak var store: HostSessionStore?
    func importFile() {
        guard let store else { return }
        let panel = NSOpenPanel()
        panel.title = "导入记录"
        panel.message = "支持纯文本、Markdown、WAV 和 Koe 资料包。"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.plainText, .wav, UTType(filenameExtension: "md") ?? .text,
                                     UTType(filenameExtension: "koepack") ?? .data]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        store.send(.importFile(path: url.path))
    }
    func exportRecord(_ recordId: String) {
        guard let store else { return }
        let title = store.snapshot.records.first(where: { $0.id == recordId })?.title
        let raw = (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let sanitized = (raw.isEmpty ? "Koe 记录" : raw)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        exportWorkspace(
            WorkspaceExportRequest(
                recordId: recordId,
                date: nil,
                suggestedFilename: "\(sanitized).md",
                includeAnalysis: true,
                includeSources: true
            )
        )
    }

    func exportWorkspace(_ request: WorkspaceExportRequest) {
        guard let store else { return }
        let panel = NSSavePanel()
        panel.title = request.date != nil ? "导出当日记录" : "导出记录 Markdown"
        panel.nameFieldStringValue = request.suggestedFilename
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        store.send(request.command(path: url.path))
    }

    func exportRecords(_ recordIds: [String]) {
        guard let store, !recordIds.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.title = "选择导出目录"
        panel.message = "将选中的 \(recordIds.count) 条记录分别导出为 Markdown 文件。"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        store.send(.exportRecordsMarkdown(recordIds: recordIds, directory: url.path))
    }
}
