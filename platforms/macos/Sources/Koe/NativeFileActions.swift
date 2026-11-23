import AppKit
import KoeAppleShared
import UniformTypeIdentifiers

@MainActor
protocol FilePanelPresenting {
    func chooseImportURL(allowedContentTypes: [UTType]) -> URL?
    func chooseExportFileURL(title: String, suggestedFilename: String, allowedContentTypes: [UTType]) -> URL?
    func chooseExportDirectoryURL(title: String, message: String) -> URL?
}

@MainActor
struct SystemFilePanelPresenter: FilePanelPresenting {
    func chooseImportURL(allowedContentTypes: [UTType]) -> URL? {
        let panel = NSOpenPanel()
        panel.title = "导入记录"
        panel.message = "支持纯文本、Markdown、WAV 和 Koe 资料包。"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = allowedContentTypes
        return panel.runModal() == .OK ? panel.url : nil
    }

    func chooseExportFileURL(title: String, suggestedFilename: String, allowedContentTypes: [UTType]) -> URL? {
        let panel = NSSavePanel()
        panel.title = title
        panel.nameFieldStringValue = suggestedFilename
        panel.allowedContentTypes = allowedContentTypes
        return panel.runModal() == .OK ? panel.url : nil
    }

    func chooseExportDirectoryURL(title: String, message: String) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.message = message
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }
}

@MainActor
final class NativeFileActions {
    weak var store: HostSessionStore?
    private let panelPresenter: any FilePanelPresenting

    convenience init() {
        self.init(panelPresenter: SystemFilePanelPresenter())
    }

    init(panelPresenter: any FilePanelPresenting) {
        self.panelPresenter = panelPresenter
    }

    func importFile() {
        guard let store else { return }
        let allowedTypes: [UTType] = [
            .plainText,
            .wav,
            UTType(filenameExtension: "md") ?? .text,
            UTType(filenameExtension: "koepack") ?? .data
        ]
        guard let url = panelPresenter.chooseImportURL(allowedContentTypes: allowedTypes) else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        store.send(.importFile(path: url.path))
    }

    func exportRecord(_ recordId: String) {
        guard let store else { return }
        let title = store.records.first(where: { $0.id == recordId })?.title
        exportWorkspace(
            WorkspaceExportRequest(
                recordId: recordId,
                date: nil,
                suggestedFilename: ExportFilenameSanitizer.markdownFilename(stem: title),
                includeAnalysis: true,
                includeSources: true
            )
        )
    }

    func exportWorkspace(_ request: WorkspaceExportRequest) {
        guard let store else { return }
        let title = request.date != nil ? "导出当日记录" : "导出记录 Markdown"
        let sanitizedFilename = ExportFilenameSanitizer.sanitizeMarkdownFilename(request.suggestedFilename)
        let allowedTypes = [UTType(filenameExtension: "md") ?? .plainText]
        guard let url = panelPresenter.chooseExportFileURL(
            title: title,
            suggestedFilename: sanitizedFilename,
            allowedContentTypes: allowedTypes
        ) else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        store.send(request.command(path: url.path))
    }

    func exportRecords(_ recordIds: [String]) {
        guard let store, !recordIds.isEmpty else { return }
        guard let url = panelPresenter.chooseExportDirectoryURL(
            title: "选择导出目录",
            message: "将选中的 \(recordIds.count) 条记录分别导出为 Markdown 文件。"
        ) else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        store.send(.exportRecordsMarkdown(recordIds: recordIds, directory: url.path))
    }

    func exportDiagnosticsBundle(nowEpochSec: UInt64 = 0) {
        guard let store else { return }
        let filename = HostSessionStore.diagnosticsBundleFilename(nowEpochSec: nowEpochSec)
        guard let url = panelPresenter.chooseExportFileURL(
            title: "导出诊断包",
            suggestedFilename: filename,
            allowedContentTypes: [.json]
        ) else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let payload = store.exportDiagnosticsBundleJSON(nowEpochSec: nowEpochSec)
        do {
            try Data(payload.utf8).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            HostDiagnosticLog.shared.error(
                category: "files",
                event: "export_diagnostics_write_failed",
                error: error
            )
            store.reportNativeError("无法导出诊断包：\(error.localizedDescription)")
        }
    }
}
