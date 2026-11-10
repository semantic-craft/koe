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
}
