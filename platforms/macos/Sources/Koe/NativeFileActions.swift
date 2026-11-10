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
    func importFlutterLibrary() {
        guard let store else { return }
        let panel = NSOpenPanel()
        panel.title = "迁入旧版 Flutter 资料"
        panel.message = "选择含 recording_library.json 的 AnkerRecorder 目录。原目录保持不变，未支持资料会列在设置页。"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        store.send("import_flutter_library", ["path": url.path])
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
}
