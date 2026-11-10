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
