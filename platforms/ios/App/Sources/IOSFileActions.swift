import Foundation
import KoeAppleCore
import Observation
import OSLog

private struct FileActionError: LocalizedError {
    let message: String
    var errorDescription: String? { message }

    init(_ message: String) { self.message = message }
}

@MainActor @Observable
final class IOSFileActions {
    private static let logger = Logger(subsystem: "com.semanticcraft.koe.ios", category: "files")
    private let store: HostSessionStore
    private let stagingRoot: URL
    private(set) var exportURLs: [URL] = []

    init(store: HostSessionStore, stagingRoot: URL = URL.temporaryDirectory.appendingPathComponent("koe-file-actions")) {
        self.store = store
        self.stagingRoot = stagingRoot
        do {
            try FileManager.default.removeItem(at: stagingRoot)
            Self.logger.info("已清理上次文件操作的暂存目录")
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            // First launch has no staging directory.
        } catch {
            report("无法清理文件暂存目录", error)
        }
    }

    func importFile(_ url: URL) async {
        Self.logger.info("开始导入文件")
        do {
            let directory = try makeDirectory()
            defer { remove(directory) }
            let copy: URL = try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(with: Result { try Self.stageImport(url, in: directory) })
                }
            }
            try dispatch(.importFile(path: copy.path))
            Self.logger.info("导入文件完成")
        } catch {
            report("导入失败", error)
        }
    }

    func pickerFailed(_ error: Error) {
        if (error as NSError).domain == NSCocoaErrorDomain,
           (error as NSError).code == NSUserCancelledError {
            Self.logger.info("已取消文件选择")
        } else {
            report("无法选择文件", error)
        }
    }

    func exportRecord(_ id: String) {
        let title = store.records.first { $0.id == id }?.title
        exportWorkspace(WorkspaceExportRequest(
            recordId: id,
            suggestedFilename: ExportFilenameSanitizer.markdownFilename(stem: title)
        ))
    }

    func exportWorkspace(_ request: WorkspaceExportRequest) {
        prepareExport { directory in
            guard let safeName = ExportFilenameSanitizer.validatedMarkdownFilename(request.suggestedFilename) else {
                throw FileActionError("导出文件名无效。")
            }
            return request.command(path: directory.appendingPathComponent(safeName).path)
        }
    }

    func exportRecords(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        prepareExport { .exportRecordsMarkdown(recordIds: ids, directory: $0.path) }
    }

    func exportDiagnosticsBundle(nowEpochSec: UInt64 = 0) {
        guard exportURLs.isEmpty else { return }
        Self.logger.info("开始准备诊断包导出")
        do {
            let directory = try makeDirectory()
            defer { if exportURLs.isEmpty { remove(directory) } }
            let filename = HostSessionStore.diagnosticsBundleFilename(nowEpochSec: nowEpochSec)
            let fileURL = directory.appendingPathComponent(filename)
            let payload = store.exportDiagnosticsBundleJSON(nowEpochSec: nowEpochSec)
            try Data(payload.utf8).write(to: fileURL, options: .atomic)
            exportURLs = [fileURL]
            Self.logger.info("已准备脱敏诊断包文件")
        } catch {
            report("导出诊断包失败", error)
        }
    }

    private func prepareExport(command: (URL) throws -> HostCommand) {
        guard exportURLs.isEmpty else { return }
        Self.logger.info("开始准备 Markdown 导出")
        do {
            let directory = try makeDirectory()
            defer { if exportURLs.isEmpty { remove(directory) } }
            try dispatch(command(directory))
            let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension.lowercased() == "md" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            guard !files.isEmpty else { throw FileActionError("没有生成可导出的 Markdown 文件。") }
            exportURLs = files
            Self.logger.info("已准备 \(files.count) 个 Markdown 文件")
        } catch {
            report("导出失败", error)
        }
    }

    func finishExport(delivered: Bool = false) {
        guard let directory = exportURLs.first?.deletingLastPathComponent() else { return }
        exportURLs = []
        remove(directory)
        if delivered {
            Self.logger.info("Markdown 已交付到文件应用")
        } else {
            Self.logger.info("已取消 Markdown 导出")
        }
    }

    private func makeDirectory() throws -> URL {
        let directory = stagingRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func remove(_ directory: URL) {
        do {
            try FileManager.default.removeItem(at: directory)
        } catch {
            report("无法清理暂存文件", error)
        }
    }

    private func dispatch(_ command: HostCommand) throws {
        if let message = store.sendReturningError(command) { throw FileActionError(message) }
    }

    private func report(_ operation: String, _ error: Error) {
        Self.logger.error("\(operation, privacy: .public)：\(error.localizedDescription, privacy: .private)")
        store.reportNativeError("\(operation)：\(error.localizedDescription)")
    }

    private nonisolated static func stageImport(_ source: URL, in directory: URL) throws -> URL {
        let name = source.lastPathComponent
        guard source.isFileURL, !source.pathComponents.contains(".."),
              !name.contains("/"), !name.contains("\\"), !name.contains("\0") else {
            throw FileActionError("文件名包含无效的路径字符。")
        }
        guard ["wav", "txt", "md", "koepack"].contains(source.pathExtension.lowercased()) else {
            throw FileActionError("支持 WAV、TXT、Markdown 和 Koe 资料包。")
        }

        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        if !scoped {
            let home = URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath()
            guard source.resolvingSymlinksInPath().path.hasPrefix(home.path + "/") else {
                throw FileActionError("没有读取所选文件的权限。")
            }
        }

        let destination = directory.appendingPathComponent(name)
        var coordinationError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: source, options: [], error: &coordinationError) { readableURL in
            do {
                try copyFile(readableURL, to: destination)
            } catch {
                copyError = error
            }
        }
        if let error = coordinationError ?? copyError { throw error }
        return destination
    }

    private nonisolated static func copyFile(_ source: URL, to destination: URL) throws {
        let values = try source.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey])
        guard values.isRegularFile == true else { throw FileActionError("请选择普通文件。") }
        let limit = 256 * 1024 * 1024
        let tooLarge = FileActionError("文件超过 256 MiB 的导入上限。")
        if let size = values.fileSize, size > limit { throw tooLarge }
        guard let modified = values.contentModificationDate else { throw FileActionError("无法读取源文件修改时间。") }

        let fm = FileManager.default
        guard fm.createFile(atPath: destination.path, contents: nil) else { throw FileActionError("无法创建暂存文件。") }
        try withOpenHandle(FileHandle(forReadingFrom: source)) { input in
            try withOpenHandle(FileHandle(forWritingTo: destination)) { output in
                var total = 0
                while let chunk = try input.read(upToCount: 64 * 1024), !chunk.isEmpty {
                    total += chunk.count
                    guard total <= limit else { throw tooLarge }
                    try output.write(contentsOf: chunk)
                }
            }
        }
        try fm.setAttributes([.modificationDate: modified], ofItemAtPath: destination.path)
    }

    private nonisolated static func withOpenHandle(_ handle: FileHandle, perform: (FileHandle) throws -> Void) throws {
        let operation = Result { try perform(handle) }
        do {
            try handle.close()
        } catch {
            if case .failure(let original) = operation {
                throw FileActionError("\(original.localizedDescription)（关闭文件失败：\(error.localizedDescription)）")
            }
            throw error
        }
        try operation.get()
    }
}
