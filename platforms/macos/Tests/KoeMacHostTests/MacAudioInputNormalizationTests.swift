import Foundation
import KoeAppleShared
import Testing
@testable import Koe

extension SerializedMacHostSuites {
@Suite("macOS audio input normalization limits", .serialized)
struct MacAudioInputNormalizationTests {
    @Test("syncAudioInputsIfNeeded caps count at 64 and truncates multi-byte CJK/emoji fields to <= 256 UTF-8 bytes")
    @MainActor
    func syncAudioInputsCapsCountAndMultiByteFields() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("koe-mac-audio-norm-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = HostSessionStore(workspacePath: directory.path)
        defer { store.shutdown() }
        let delegate = KoeAppDelegate()
        delegate.store = store

        let longCJK = String(repeating: "麦", count: 100)
        let longEmoji = String(repeating: "👨‍👩‍👧‍👦", count: 20)
        var inputs: [MicrophoneInput] = [
            MicrophoneInput(id: "   ", name: "Blank ID", transport: "usb", isDefault: true),
            MicrophoneInput(id: longCJK, name: "Overlong ID", transport: "usb", isDefault: true),
            MicrophoneInput(id: "mic-primary", name: longCJK, transport: "usb", isDefault: false),
            MicrophoneInput(id: " mic-primary ", name: "Duplicate", transport: "usb", isDefault: false),
            MicrophoneInput(id: "mic-emoji", name: longEmoji, transport: "external", isDefault: false),
        ] + (2..<65).map { idx in
            MicrophoneInput(id: "mic-\(idx)", name: "Input \(idx)", transport: "external", isDefault: false)
        }
        inputs.append(MicrophoneInput(id: "mic-late-default", name: "Late Default", transport: "built_in", isDefault: true))
        inputs.append(MicrophoneInput(id: "mic-66", name: "Tail", transport: "external", isDefault: false))

        delegate.syncAudioInputsIfNeeded(force: true, inputsProvider: { inputs })
        #expect(store.snapshot.error == nil)
        #expect(store.snapshot.capture.inputs.count == 64)
        let primary = store.snapshot.capture.inputs.first(where: { $0.id == "mic-primary" })
        #expect(primary?.name == String(repeating: "麦", count: 85))
        #expect((primary?.name.utf8.count ?? 0) <= 256)
        let emojiMic = store.snapshot.capture.inputs.first(where: { $0.id == "mic-emoji" })
        #expect(emojiMic?.name == String(repeating: "👨‍👩‍👧‍👦", count: 10))
        let lateDefault = store.snapshot.capture.inputs.first(where: { $0.id == "mic-late-default" })
        #expect(lateDefault?.isDefault == true)

        let generationAfterFirst = store.snapshot.generation
        var mutatedBeyondCap = inputs
        mutatedBeyondCap[mutatedBeyondCap.count - 1] = MicrophoneInput(id: "mic-66-changed", name: "Ignored", transport: "external", isDefault: false)
        delegate.syncAudioInputsIfNeeded(force: false, inputsProvider: { mutatedBeyondCap })
        #expect(store.snapshot.generation == generationAfterFirst)
    }

    @Test("ExportFilenameSanitizer produces identical sanitized names on macOS for unsafe titles")
    func macExportFilenameSanitizerParity() {
        #expect(ExportFilenameSanitizer.markdownFilename(stem: "架构/周会") == "架构-周会.md")
        #expect(ExportFilenameSanitizer.markdownFilename(stem: "a\\b:c/d\0e") == "a-b-c-d-e.md")
        #expect(ExportFilenameSanitizer.markdownFilename(stem: "...") == "Koe 记录.md")
        #expect(ExportFilenameSanitizer.markdownFilename(stem: ".hidden") == "hidden.md")
        #expect(ExportFilenameSanitizer.markdownFilename(stem: "   \n\t ") == "Koe 记录.md")
        #expect(ExportFilenameSanitizer.sanitizeMarkdownFilename("..md") == "Koe 记录.md")
        #expect(ExportFilenameSanitizer.sanitizeMarkdownFilename("...笔\0记.md") == "笔-记.md")
    }
}
}
