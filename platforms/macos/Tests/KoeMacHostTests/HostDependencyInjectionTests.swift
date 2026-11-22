import CoreBluetooth
import Foundation
@testable import Koe
@testable import KoeAppleCore
import os
import Testing
import UniformTypeIdentifiers

private final class InMemoryBluetoothDefaultsStore: BluetoothDefaultsStore {
    private let values = OSAllocatedUnfairLock<[String: String]>(initialState: [:])

    init(initial: [String: String] = [:]) {
        values.withLock { $0 = initial }
    }

    func string(forKey defaultName: String) -> String? {
        values.withLock { $0[defaultName] }
    }

    func set(_ value: String, forKey defaultName: String) {
        values.withLock { $0[defaultName] = value }
    }

    func removeObject(forKey defaultName: String) {
        values.withLock { _ = $0.removeValue(forKey: defaultName) }
    }
}

@MainActor
private final class FakeFilePanelPresenter: FilePanelPresenting {
    var importURL: URL?
    var exportFileURL: URL?
    var exportDirectoryURL: URL?
    private(set) var importAllowedTypes: [[UTType]] = []
    private(set) var exportFileRequests: [(title: String, suggestedFilename: String, allowedContentTypes: [UTType])] = []
    private(set) var exportDirectoryRequests: [(title: String, message: String)] = []

    func chooseImportURL(allowedContentTypes: [UTType]) -> URL? {
        importAllowedTypes.append(allowedContentTypes)
        return importURL
    }

    func chooseExportFileURL(title: String, suggestedFilename: String, allowedContentTypes: [UTType]) -> URL? {
        exportFileRequests.append((title, suggestedFilename, allowedContentTypes))
        return exportFileURL
    }

    func chooseExportDirectoryURL(title: String, message: String) -> URL? {
        exportDirectoryRequests.append((title, message))
        return exportDirectoryURL
    }
}

extension SerializedMacHostSuites {
@Suite("macOS protocol DI for BluetoothBridge, NativeFileActions, KoeAppDelegate, and expanded smoke test", .serialized)
@MainActor
struct HostDependencyInjectionTests {
    @Test("BluetoothBridge with in-memory BluetoothDefaultsStore never mutates UserDefaults.standard")
    func bluetoothBridgeUsesInjectedDefaultsStoreWithoutMutatingUserDefaults() {
        let key = BluetoothBridge.savedPeripheralKey
        let sentinel = "sentinel-\(UUID().uuidString)"
        let previous = UserDefaults.standard.string(forKey: key)
        UserDefaults.standard.set(sentinel, forKey: key)
        defer {
            if let previous {
                UserDefaults.standard.set(previous, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("koe-ble-di-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = HostSessionStore(workspacePath: directory.path)
        defer { store.shutdown() }

        let knownUUID = UUID().uuidString
        let defaultsStore = InMemoryBluetoothDefaultsStore()
        let bridge = BluetoothBridge(store: store, defaultsStore: defaultsStore)
        store.send(.setBleAutoConnect(enabled: false))
        bridge.activateHost(allowsCoreBluetooth: false)
        store.send(.setBleAutoConnect(enabled: true))
        defaultsStore.set(knownUUID, forKey: key)
        bridge.reconnectKnownIfAvailable()
        #expect(bridge.scanStartCount == 1)
        #expect(defaultsStore.string(forKey: key) == knownUUID)
        #expect(UserDefaults.standard.string(forKey: key) == sentinel)

        store.send(.setBleAutoConnect(enabled: false))
        bridge.syncWithRuntimeDevice(store.snapshot.device)
        #expect(defaultsStore.string(forKey: key) == nil)
        #expect(UserDefaults.standard.string(forKey: key) == sentinel)
        bridge.shutdown()
    }

    @Test("NativeFileActions delegates import, exportRecord, exportWorkspace, and exportRecords via FilePanelPresenting")
    func nativeFileActionsUsesInjectedPanelPresenterEndToEnd() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("koe-files-di-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = HostSessionStore(workspacePath: directory.path)
        defer { store.shutdown() }

        let presenter = FakeFilePanelPresenter()
        let actions = NativeFileActions(panelPresenter: presenter)
        let delegate = KoeAppDelegate(
            playback: NativePlayback(),
            bluetoothBridge: BluetoothBridge(defaultsStore: InMemoryBluetoothDefaultsStore()),
            files: actions,
            defaultInputsProvider: { [] },
            makeDefaultStore: { store }
        )
        defer { delegate.store = nil }
        _ = delegate.ensureSessionStore()

        let importSource = directory.appendingPathComponent("meeting-notes.md")
        try "Line one.\nLine two.".write(to: importSource, atomically: true, encoding: .utf8)
        presenter.importURL = importSource
        delegate.files.importFile()

        #expect(presenter.importAllowedTypes.count == 1)
        #expect(store.snapshot.records.count == 1)
        #expect(store.snapshot.error == nil)

        store.send(.createNote(title: "架构/周会:总结", text: "保持边界清晰。"))
        let created = try #require(store.snapshot.detail)

        let recordExportURL = directory.appendingPathComponent("single-record.md")
        presenter.exportFileURL = recordExportURL
        delegate.files.exportRecord(created.id)

        let singleRequest = try #require(presenter.exportFileRequests.last)
        #expect(singleRequest.title == "导出记录 Markdown")
        #expect(singleRequest.suggestedFilename == "架构-周会-总结.md")
        #expect(FileManager.default.fileExists(atPath: recordExportURL.path))
        #expect(store.snapshot.error == nil)

        let workspaceExportURL = directory.appendingPathComponent("day-export.md")
        presenter.exportFileURL = workspaceExportURL
        delegate.files.exportWorkspace(
            WorkspaceExportRequest(
                recordId: created.id,
                date: "2026-11-22",
                suggestedFilename: "2026/11:22.MD",
                includeAnalysis: true,
                includeSources: false
            )
        )
        let dayRequest = try #require(presenter.exportFileRequests.last)
        #expect(dayRequest.title == "导出当日记录")
        #expect(dayRequest.suggestedFilename == "2026-11-22.md")
        #expect(FileManager.default.fileExists(atPath: workspaceExportURL.path))

        let batchDir = directory.appendingPathComponent("batch-out")
        try FileManager.default.createDirectory(at: batchDir, withIntermediateDirectories: true)
        presenter.exportDirectoryURL = batchDir
        let allIds = store.snapshot.records.map(\.id)
        delegate.files.exportRecords(allIds)

        let batchRequest = try #require(presenter.exportDirectoryRequests.last)
        #expect(batchRequest.title == "选择导出目录")
        #expect(batchRequest.message.contains("\(allIds.count)"))
        let exportedFiles = try FileManager.default.contentsOfDirectory(atPath: batchDir.path)
        #expect(exportedFiles.count == allIds.count)
        #expect(store.snapshot.error == nil)
    }

    @Test("KoeSelfCheckRunner.runSmokeTest exercises real KoeAppDelegate wiring cleanly without mutating UserDefaults")
    func smokeTestExercisesHostDelegateCleanly() {
        let key = BluetoothBridge.savedPeripheralKey
        let sentinel = "smoke-sentinel-\(UUID().uuidString)"
        let previous = UserDefaults.standard.string(forKey: key)
        UserDefaults.standard.set(sentinel, forKey: key)
        defer {
            if let previous {
                UserDefaults.standard.set(previous, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }

        #expect(KoeSelfCheckRunner.runSmokeTest() == 0)
        #expect(UserDefaults.standard.string(forKey: key) == sentinel)
    }
}
}
