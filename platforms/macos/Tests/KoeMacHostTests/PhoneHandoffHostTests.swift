import Foundation
import KoeAppleShared
import Testing
@testable import Koe

extension SerializedMacHostSuites {
@Suite("Phone handoff status menu and BLE release guard", .serialized)
struct PhoneHandoffHostTests {
    private func rxFrame(group: UInt8, command: UInt8, payload: [UInt8]) -> Data {
        var bytes: [UInt8] = [0x09, 0xFF, 0x00, 0x00, 0x01, group, command]
        let total = UInt16(bytes.count + 2 + payload.count + 1)
        bytes += [UInt8(total & 0xFF), UInt8(total >> 8)]
        bytes += payload
        bytes.append(UInt8(bytes.reduce(0) { $0 + Int($1) } & 0xFF))
        return Data(bytes)
    }

    @Test("Status menu reflects Mac vs phone BLE ownership toggle, guide reclaim, and recording guard")
    @MainActor
    func statusMenuReflectsPhoneHandoffToggle() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = HostSessionStore(workspacePath: directory.path)
        defer { store.shutdown() }

        let delegate = KoeAppDelegate()
        delegate.store = store
        defer { delegate.store = nil }

        let macMenu = delegate.buildStatusMenu()
        #expect(macMenu.items.first?.title == store.device.state)
        let macScanIndex = try #require(macMenu.items.firstIndex(where: { $0.title == "查找录音豆" }))
        let releaseItem = macMenu.items[macScanIndex + 1]
        #expect(releaseItem.title == "切回手机（释放控制权）")
        #expect(releaseItem.isEnabled == true)
        #expect(!macMenu.items.contains(where: { $0.title == "连回 Mac 录音豆" }))

        store.send(.deviceRelease)
        delegate.menuNeedsUpdate(macMenu)
        #expect(macMenu.items.first?.title == "录音豆：已让出给手机")
        let reconnectItem = try #require(macMenu.items.first(where: { $0.title == "连回 Mac 录音豆" }))
        #expect(reconnectItem.isEnabled == true)
        #expect(!macMenu.items.contains(where: { $0.title == "查找录音豆" }))
        #expect(!macMenu.items.contains(where: { $0.title == "切回手机（释放控制权）" }))

        delegate.prepareManualScan()
        delegate.menuNeedsUpdate(macMenu)
        #expect(store.device.autoConnect == true)
        #expect(store.device.guide?.mode == "connect_guide")
        #expect(macMenu.items.first?.title == store.device.state)
        let restoredScanIndex = try #require(macMenu.items.firstIndex(where: { $0.title == "查找录音豆" }))
        #expect(macMenu.items[restoredScanIndex + 1].title == "切回手机（释放控制权）")
        #expect(!macMenu.items.contains(where: { $0.title == "连回 Mac 录音豆" }))

        store.send("device_event", ["event": "scanning", "connectionId": "c-handoff"])
        store.ingestBleChunk(rxFrame(group: 0x18, command: 0x81, payload: [0x93, 0x03, 0, 0]), nowEpochSec: 1_800_000_000)
        delegate.menuNeedsUpdate(macMenu)
        #expect(store.today.picker?.canReleaseToPhone == false)
        let blockedScanIndex = try #require(macMenu.items.firstIndex(where: { $0.title == "查找录音豆" }))
        let blockedReleaseItem = macMenu.items[blockedScanIndex + 1]
        #expect(blockedReleaseItem.title == "切回手机（释放控制权）")
        #expect(blockedReleaseItem.isEnabled == false)

        delegate.bluetoothBridge.isScanRequested = true
        store.send(.deviceRelease)
        #expect(store.device.autoConnect == true)
        #expect(delegate.bluetoothBridge.isScanRequested == true)
        #expect(store.navigation.effectiveError != nil)
    }

    @Test("Rejected deviceRelease when autoConnect is false and bean recording is active preserves error and keeps BLE bridge active")
    @MainActor
    func rejectedReleaseWithAutoConnectFalsePreservesErrorAndBleBridge() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = HostSessionStore(workspacePath: directory.path)
        defer { store.shutdown() }

        let delegate = KoeAppDelegate()
        delegate.store = store
        defer { delegate.store = nil }
        delegate.bluetoothBridge.activateHost(allowsCoreBluetooth: false)

        store.send(.setBleAutoConnect(enabled: false))
        #expect(store.device.autoConnect == false)

        delegate.bluetoothBridge.startScanningIfPoweredOn()
        store.ingestBleChunk(rxFrame(group: 0x18, command: 0x81, payload: [0x93, 0x03, 0, 0]), nowEpochSec: 1_800_000_000)
        #expect(store.device.recording == true)
        #expect(delegate.bluetoothBridge.isScanRequested == true)

        store.send(.deviceRelease)
        #expect(store.navigation.effectiveError != nil)
        #expect(store.device.autoConnect == false)
        #expect(store.device.recording == true)
        #expect(delegate.bluetoothBridge.isScanRequested == true)
    }

    @Test("BLE scan request enables autoConnect and starts scanning without opening connect guide")
    @MainActor
    func bleScanRequestDoesNotOpenConnectGuide() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = HostSessionStore(workspacePath: directory.path)
        defer { store.shutdown() }

        let delegate = KoeAppDelegate()
        delegate.store = store
        defer { delegate.store = nil }
        delegate.bluetoothBridge.activateHost(allowsCoreBluetooth: false)

        store.send(.deviceRelease)
        #expect(store.device.autoConnect == false)
        #expect(store.device.guide == nil)

        delegate.handleBleScanRequest()
        #expect(store.device.autoConnect == true)
        #expect(store.device.guide == nil)
        #expect(delegate.bluetoothBridge.isScanRequested == true)
    }

    @Test("BLE scan request while offscreen reconciles deferred device slice before checking autoConnect")
    @MainActor
    func handleBleScanRequestWhileOffscreen() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = HostSessionStore(workspacePath: directory.path)
        defer { store.shutdown() }

        let delegate = KoeAppDelegate()
        delegate.store = store
        defer { delegate.store = nil }
        delegate.bluetoothBridge.activateHost(allowsCoreBluetooth: false)

        store.setUISlicesActive(false)
        store.send(.deviceRelease)
        #expect(store.snapshot.device.autoConnect == false)

        delegate.handleBleScanRequest()
        #expect(store.snapshot.device.autoConnect == true)
        #expect(delegate.bluetoothBridge.isScanRequested == true)
        store.setUISlicesActive(true)
        #expect(store.device.autoConnect == true)
    }
}
}
