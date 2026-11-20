import AVFoundation
import KoeAppleCore
import XCTest
@testable import KoeiOSApp

@MainActor
final class IOSFileActionsTests: XCTestCase {
    private let fm = FileManager.default

    private struct Fixture {
        let source: URL
        let staging: URL
        let store: HostSessionStore
        let files: IOSFileActions
    }

    private func fixture(beforeLaunch: (URL) throws -> Void = { _ in }) throws -> Fixture {
        let source = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let staging = source.appendingPathComponent("staging")
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: source) }
        try beforeLaunch(staging)
        let store = HostSessionStore(workspacePath: source.appendingPathComponent("workspace").path,
                                     credentials: NativeCredentialsiOS(forceIsolated: true))
        XCTAssertNotEqual(store.handle, 0)
        return Fixture(source: source, staging: staging, store: store,
                       files: IOSFileActions(store: store, stagingRoot: staging))
    }

    private func assertClean(_ staging: URL, file: StaticString = #filePath, line: UInt = #line) throws {
        if fm.fileExists(atPath: staging.path) {
            XCTAssertEqual(try fm.contentsOfDirectory(atPath: staging.path), [], file: file, line: line)
        }
    }

    private func writeWAV(to url: URL) throws {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000,
                                                 channels: 1, interleaved: true))
        let file = try AVAudioFile(forWriting: url, settings: format.settings,
                                   commonFormat: .pcmFormatInt16, interleaved: true)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000))
        buffer.frameLength = 16_000
        let channel = try XCTUnwrap(buffer.int16ChannelData?.pointee)
        channel.update(repeating: 123, count: Int(buffer.frameLength))
        try file.write(from: buffer)
    }

    func testFourImportFormatsKeepSourceTimestampAndReleaseStaging() async throws {
        let f = try fixture()
        defer { f.store.shutdown() }
        try writeWAV(to: f.source.appendingPathComponent("sample.wav"))
        try Data("text source".utf8).write(to: f.source.appendingPathComponent("notes.txt"))
        try Data("# Markdown source".utf8).write(to: f.source.appendingPathComponent("draft.md"))
        let pack = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "minutes-v2", withExtension: "koepack"))
        try fm.copyItem(at: pack, to: f.source.appendingPathComponent("archive.koepack"))

        let timestamp: UInt64 = 1_600_000_001
        for (name, title) in [("sample.wav", "sample"), ("notes.txt", "notes"),
                              ("draft.md", "draft"), ("archive.koepack", "归档会议")] {
            let input = f.source.appendingPathComponent(name)
            try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: Double(timestamp))],
                                 ofItemAtPath: input.path)
            await f.files.importFile(input)
            let record = f.store.records.first { $0.title == title }
            XCTAssertEqual(record?.createdAtEpochSec, timestamp, "\(name): \(f.store.navigation.effectiveError ?? "")")
            if name == "sample.wav" { XCTAssertEqual(record?.durationMs, 1_000) }
            if name == "archive.koepack" { XCTAssertTrue(record?.preview.contains("资料包原文") == true) }
            XCTAssertTrue(fm.fileExists(atPath: input.path))
            try assertClean(f.staging)
        }
        XCTAssertEqual(f.store.records.count, 4)
    }

    func testOversizeSparseFileIsRejectedBeforeImport() async throws {
        let f = try fixture()
        defer { f.store.shutdown() }
        let input = f.source.appendingPathComponent("large.txt")
        try Data().write(to: input)
        let handle = try FileHandle(forWritingTo: input)
        try handle.truncate(atOffset: 256 * 1024 * 1024 + 1)
        try handle.close()

        await f.files.importFile(input)
        XCTAssertTrue(f.store.nativeError?.contains("256") == true)
        XCTAssertTrue(f.store.records.isEmpty)
        try assertClean(f.staging)
    }

    func testInvalidTypeDirectoryFilenameAndReadFailureReportErrorsAndCleanStaging() async throws {
        let f = try fixture()
        defer { f.store.shutdown() }
        let unsupported = f.source.appendingPathComponent("image.jpg")
        let directory = f.source.appendingPathComponent("folder.txt")
        let unsafeName = f.source.appendingPathComponent("..\\outside.txt")
        let missing = f.source.appendingPathComponent("missing.txt")
        try Data("source".utf8).write(to: unsupported)
        try fm.createDirectory(at: directory, withIntermediateDirectories: false)
        try Data("source".utf8).write(to: unsafeName)
        for input in [unsupported, directory, unsafeName, missing] {
            f.store.clearError()
            await f.files.importFile(input)
            XCTAssertNotNil(f.store.nativeError, input.lastPathComponent)
            XCTAssertTrue(f.store.records.isEmpty)
            try assertClean(f.staging)
        }
    }

    func testRustRejectsInvalidPackAndStagingIsRemoved() async throws {
        let f = try fixture()
        defer { f.store.shutdown() }
        let input = f.source.appendingPathComponent("corrupt.koepack")
        try Data("invalid pack".utf8).write(to: input)
        await f.files.importFile(input)
        XCTAssertNotNil(f.store.navigation.effectiveError)
        XCTAssertTrue(f.store.records.isEmpty)
        try assertClean(f.staging)
    }

    private func readExport(_ url: URL, in staging: URL) throws -> String {
        XCTAssertTrue(url.standardizedFileURL.path.hasPrefix(staging.standardizedFileURL.path + "/"))
        XCTAssertEqual(url.pathExtension, "md")
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testBluetoothErrorDoesNotMaskFileCommandResult() async throws {
        let f = try fixture()
        defer { f.store.shutdown() }
        let bluetoothError = "蓝牙已关闭"
        for title in ["旧提示", "回调提示"] {
            if title == "回调提示" {
                f.store.onSnapshotChanged = { [weak store = f.store] _ in
                    store?.reportNativeError(bluetoothError)
                }
            }
            let source = f.source.appendingPathComponent("\(title).txt")
            try Data(title.utf8).write(to: source)
            f.store.reportNativeError(bluetoothError)
            await f.files.importFile(source)
            let record = try XCTUnwrap(f.store.records.first { $0.title == title })
            XCTAssertFalse(f.store.nativeError?.contains("导入失败") == true)
            f.store.reportNativeError(bluetoothError)
            f.files.exportRecord(record.id)
            let url = try XCTUnwrap(f.files.exportURLs.first, title)
            XCTAssertTrue(try readExport(url, in: f.staging).contains(title))
            f.files.finishExport()
            try assertClean(f.staging)
        }
        f.files.exportRecord("missing-record")
        XCTAssertTrue(f.store.nativeError?.contains("记录不存在") == true)
        try assertClean(f.staging)
    }

    func testWorkspaceExportProducesVisibleNamesForDotAndInvalidTitles() throws {
        let f = try fixture()
        defer { f.store.shutdown() }
        f.store.send(.createNote(title: "导出", text: "原文"))
        let record = try XCTUnwrap(f.store.records.first)
        for (name, expected) in [("..md", "Koe 记录.md"), ("/:\\\0.md", "Koe 记录.md"),
                                 ("...笔\0记.md", "笔-记.md")] {
            f.files.exportWorkspace(.init(recordId: record.id, suggestedFilename: name))
            let url = try XCTUnwrap(f.files.exportURLs.first)
            XCTAssertEqual(url.lastPathComponent, expected)
            XCTAssertTrue(try readExport(url, in: f.staging).contains("原文"))
            f.files.finishExport()
        }
    }

    func testEmptyBatchLeavesPriorFeedbackAndStagingUntouched() throws {
        let f = try fixture()
        defer { f.store.shutdown() }
        f.store.reportNativeError("蓝牙已关闭")
        f.files.exportRecords([])
        XCTAssertEqual(f.store.nativeError, "蓝牙已关闭")
        XCTAssertTrue(f.files.exportURLs.isEmpty)
        try assertClean(f.staging)
    }

    func testRecordExportSanitizesTitlePreservesMarkdownAndReleasesStaging() throws {
        let f = try fixture()
        defer { f.store.shutdown() }
        f.store.send(.createNote(title: "导出/标题:一", text: "单条导出原文"))
        let record = try XCTUnwrap(f.store.records.first)
        f.files.exportRecord(record.id)
        let url = try XCTUnwrap(f.files.exportURLs.first)
        XCTAssertEqual(url.lastPathComponent, "导出-标题-一.md")
        let markdown = try readExport(url, in: f.staging)
        XCTAssertTrue(markdown.contains("# 导出/标题:一"))
        XCTAssertTrue(markdown.contains("单条导出原文"))
        f.files.finishExport()
        XCTAssertTrue(f.files.exportURLs.isEmpty)
        XCTAssertNil(f.store.navigation.effectiveError)
        try assertClean(f.staging)
    }

    func testDayExportUsesRequestedDateAndReleasesStaging() throws {
        let f = try fixture()
        defer { f.store.shutdown() }
        let date = "2025-08-12"
        f.files.exportWorkspace(.forAllDay(date: date))
        let url = try XCTUnwrap(f.files.exportURLs.first)
        let markdown = try readExport(url, in: f.staging)
        XCTAssertTrue(markdown.hasPrefix("# 全天听记 \(date)"))
        XCTAssertTrue(markdown.contains("## 原文时间线"))
        f.files.finishExport()
        XCTAssertNil(f.store.navigation.effectiveError)
        try assertClean(f.staging)
    }

    func testBatchExportIncludesOnlySelectedRecordsWithDistinctFilesAndReleasesStaging() throws {
        let f = try fixture()
        defer { f.store.shutdown() }
        for text in ["第一条原文", "第二条原文", "不导出的原文"] {
            f.store.send(.createNote(title: "同名", text: text))
        }
        let selected = f.store.records.filter { $0.preview != "不导出的原文" }.map(\.id)
        XCTAssertEqual(selected.count, 2)
        f.files.exportRecords(selected)
        let urls = f.files.exportURLs
        XCTAssertEqual(Set(urls.map(\.lastPathComponent)).count, 2)
        let markdown = try urls.map { try readExport($0, in: f.staging) }.joined(separator: "\n")
        XCTAssertTrue(markdown.contains("第一条原文"))
        XCTAssertTrue(markdown.contains("第二条原文"))
        XCTAssertFalse(markdown.contains("不导出的原文"))
        f.files.finishExport()
        XCTAssertTrue(f.files.exportURLs.isEmpty)
        XCTAssertNil(f.store.navigation.effectiveError)
        try assertClean(f.staging)
    }

    func testLaunchRemovesOrphanWithoutDeletingAdjacentFile() throws {
        let f = try fixture { staging in
            let orphan = staging.appendingPathComponent("abandoned")
            try fm.createDirectory(at: orphan, withIntermediateDirectories: true)
            try Data("partial transfer".utf8).write(to: orphan.appendingPathComponent("partial.txt"))
            try Data("original".utf8).write(to: staging.deletingLastPathComponent().appendingPathComponent("keep.txt"))
        }
        defer { f.store.shutdown() }
        try assertClean(f.staging)
        XCTAssertEqual(try String(contentsOf: f.source.appendingPathComponent("keep.txt"), encoding: .utf8), "original")
    }
}
