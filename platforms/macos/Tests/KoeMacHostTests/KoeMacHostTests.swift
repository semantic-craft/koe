import AppKit
import Foundation
import KoeAppleShared
import Testing
@testable import Koe

@Suite("Native host lifecycle and product workflow")
struct KoeMacHostTests {
    @Test("The isolated C ABI workflow and persisted-state self checks pass")
    @MainActor
    func productWorkflow() {
        #expect(KoeSelfCheckRunner.runVerifySelf() == 0)
        #expect(KoeSelfCheckRunner.runSmokeTest() == 0)
    }

    @Test("The Dock menu contains the product destinations and no simulated recording action")
    @MainActor
    func dockDestinations() {
        let delegate = KoeAppDelegate()
        let menu = delegate.buildStatusMenu()
        let destinations = menu.items.compactMap { $0.representedObject as? String }
        #expect(destinations == ["today", "records", "tasks", "memory", "ask", "settings"])
    }

    @Test("BLE data decoding rejects incomplete and invalid byte strings")
    @MainActor
    func bleFrameDecoding() {
        #expect(BluetoothBridge.decodeHex("09ff0001") == Data([0x09, 0xff, 0x00, 0x01]))
        #expect(BluetoothBridge.decodeHex("0") == nil)
        #expect(BluetoothBridge.decodeHex("gg") == nil)
    }

    @Test("D3200 BLE advertisement matching recognizes service UUID, manufacturer data, and 128-bit characteristics")
    @MainActor
    func bleAdvertisementAndCharacteristicMatching() {
        let serviceMatch = BleAdvertisementCandidate.match(
            peripheralName: nil,
            advertisementData: [
                "kCBAdvDataServiceUUIDs": [BluetoothBridge.d3200ServiceUUID]
            ]
        )
        #expect(serviceMatch != nil)

        let mfgBytes = Data([0x00, 0x7F, 0x1D, 0x04, 0xCC, 0xA3, 0x90, 0x00, 0x73, 0x6F, 0x75, 0x6E, 0x64, 0x63])
        let mfgMatch = BleAdvertisementCandidate.match(
            peripheralName: nil,
            advertisementData: [
                "kCBAdvDataManufacturerData": mfgBytes
            ]
        )
        #expect(mfgMatch?.macAddress == "00:7F:1D:04:CC:A3")
        #expect(mfgMatch?.displayName == "soundcore Work (CC:A3)")

        let prefixedMfgBytes = Data([0xFF, 0xFF, 0x00, 0x7F, 0x1D, 0x04, 0xCC, 0xA3, 0x90, 0x00, 0x73, 0x6F, 0x75, 0x6E, 0x64, 0x63])
        let prefixedMatch = BleAdvertisementCandidate.match(
            peripheralName: nil,
            advertisementData: [
                "kCBAdvDataManufacturerData": prefixedMfgBytes
            ]
        )
        #expect(prefixedMatch?.macAddress == "00:7F:1D:04:CC:A3")
        #expect(prefixedMatch?.displayName == "soundcore Work (CC:A3)")

        #expect(BluetoothBridge.isWriteCharacteristic(BluetoothBridge.writeCharacteristicUUID))
        #expect(BluetoothBridge.isNotifyCharacteristic(BluetoothBridge.notifyCharacteristicUUID))
    }

    @Test("BLE outbound queue paces frames at 300ms intervals and resets on disconnect")
    @MainActor
    func bleOutboundQueuePacing() {
        var queue = BleOutboundQueue(spacingSeconds: 0.30)
        let f1 = Data([0x09, 0xFF, 0x00, 0x01])
        let f2 = Data([0x09, 0xFF, 0x00, 0x02])
        let f3 = Data([0x09, 0xFF, 0x00, 0x03])
        queue.enqueue([f1, f2, f3])

        let t0 = Date(timeIntervalSince1970: 1_000.0)
        #expect(queue.delayUntilNextReady(now: t0) == 0)
        #expect(queue.popReady(now: t0) == f1)
        #expect(queue.lastWriteDate == t0)

        let t100ms = t0.addingTimeInterval(0.10)
        #expect(queue.popReady(now: t100ms) == nil)
        let delayAt100ms = queue.delayUntilNextReady(now: t100ms) ?? -1
        #expect(abs(delayAt100ms - 0.20) < 0.001)

        let t300ms = t0.addingTimeInterval(0.30)
        #expect(queue.popReady(now: t300ms) == f2)
        #expect(queue.popReady(now: t300ms) == nil)

        queue.reset()
        #expect(queue.delayUntilNextReady(now: t300ms) == nil)
        #expect(queue.popReady(now: t300ms) == nil)
        #expect(queue.lastWriteDate == nil)
    }

    @Test("D3200 primary service write characteristic is not overwritten by secondary service")
    @MainActor
    func writeCharacteristicServicePriority() {
        let primary = BluetoothBridge.d3200ServiceUUID
        let secondary = BluetoothBridge.secondaryServiceUUIDForTest("00007000-0000-1000-8000-00805F9B34FB")

        #expect(BluetoothBridge.shouldPreferWriteCharacteristic(existingServiceUUID: nil, candidateServiceUUID: secondary))
        #expect(BluetoothBridge.shouldPreferWriteCharacteristic(existingServiceUUID: secondary, candidateServiceUUID: primary))
        #expect(!BluetoothBridge.shouldPreferWriteCharacteristic(existingServiceUUID: primary, candidateServiceUUID: secondary))
        #expect(BluetoothBridge.shouldPreferWriteCharacteristic(existingServiceUUID: primary, candidateServiceUUID: primary))
    }

    @Test("Closing and reopening restores the workspace instead of a panel")
    @MainActor
    func windowCloseAndReopen() {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 100, height: 24),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1040, height: 680),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        defer { panel.orderOut(nil); window.orderOut(nil) }
        #expect(!KoeWindowPresenter.isWorkspaceWindow(panel))
        #expect(KoeWindowPresenter.isWorkspaceWindow(window))
        KoeWindowPresenter.presentWindow(window)
        #expect(!window.isReleasedWhenClosed)
        window.close()
        #expect(!window.isVisible)
        let delegate = KoeAppDelegate()
        #expect(!delegate.applicationShouldTerminateAfterLastWindowClosed(NSApplication.shared))
        #expect(delegate.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: false))
        #expect(window.isVisible)
    }

    @Test("Companion auto-connect guard, BLE release, and manual scan recovery keep UserDefaults and runtime in sync")
    @MainActor
    func companionBleReleaseAndManualScanRecovery() {
        let key = BluetoothBridge.savedPeripheralKey
        let previousSaved = UserDefaults.standard.string(forKey: key)
        defer {
            if let previousSaved {
                UserDefaults.standard.set(previousSaved, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = HostSessionStore(workspacePath: directory.path)
        defer { store.shutdown() }

        let savedUUID = "11111111-2222-3333-4444-555555555555"
        store.send("set_ble_auto_connect", ["enabled": false])
        UserDefaults.standard.set(savedUUID, forKey: key)

        let bridge = BluetoothBridge(store: store)
        bridge.reconnectKnownIfAvailable()
        #expect(!bridge.isScanRequested)
        #expect(UserDefaults.standard.string(forKey: key) == savedUUID)

        let delegate = KoeAppDelegate()
        delegate.store = store
        #expect(!delegate.bluetoothBridge.isScanRequested)
        #expect(UserDefaults.standard.string(forKey: key) == nil)

        delegate.prepareManualScan()
        #expect(store.snapshot.device.autoConnect == true)
        #expect(store.snapshot.device.guide?.mode == "connect_guide")

        UserDefaults.standard.set(savedUUID, forKey: key)
        delegate.bluetoothBridge.releaseControl()
        #expect(store.snapshot.device.autoConnect == false)
        #expect(!delegate.bluetoothBridge.isScanRequested)
        #expect(UserDefaults.standard.string(forKey: key) == nil)

        store.send("set_ble_auto_connect", ["enabled": true])
        UserDefaults.standard.set(savedUUID, forKey: key)
        #expect(UserDefaults.standard.string(forKey: key) == savedUUID)

        store.send("device_release")
        #expect(store.snapshot.device.autoConnect == false)
        #expect(UserDefaults.standard.string(forKey: key) == nil)
    }
}
