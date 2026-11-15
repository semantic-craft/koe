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
        store.send("import_file", ["path": url.path])
    }
    func exportRecord(_ recordId: String) {
        guard let store else { return }
        let panel = NSSavePanel()
        panel.title = "导出记录"
        let title = store.snapshot.records.first(where: { $0.id == recordId })?.title ?? "Koe 记录"
        panel.nameFieldStringValue = title.replacingOccurrences(of: "/", with: "-") + ".md"
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        store.send("export_record", ["recordId": recordId, "path": url.path])
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
        store.send("export_workspace_markdown", request.commandPayload(path: url.path))
    }
}
