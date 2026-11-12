import Foundation
import Testing
@testable import KoeAppleShared

@Suite("Companion snapshot and settings contract")
struct CompanionSnapshotTests {
    @Test("DeviceSnapshot decodes companion and autoConnect fields with backward-compatible defaults")
    @MainActor
    func companionDeviceSnapshotDecoding() throws {
        let legacyJSON = """
        {
          "state": "未连接",
          "connected": false,
          "busy": false,
          "files": [],
          "progress": 0.0
        }
        """
        let legacy = try JSONDecoder().decode(DeviceSnapshot.self, from: Data(legacyJSON.utf8))
        #expect(legacy.autoConnect == true)
        #expect(legacy.companionMode == "disabled")
        #expect(legacy.standbyReady == false)

        let standbyJSON = """
        {
          "state": "领夹待命中",
          "phase": "ready",
          "connected": true,
          "busy": false,
          "recording": true,
          "autoConnect": false,
          "companionMode": "collar_standby",
          "standbyReady": true,
          "files": [],
          "progress": 0.0
        }
        """
        let standby = try JSONDecoder().decode(DeviceSnapshot.self, from: Data(standbyJSON.utf8))
        #expect(standby.autoConnect == false)
        #expect(standby.companionMode == "collar_standby")
        #expect(standby.standbyReady == true)
    }

    @Test("HostSessionStore persists companion mode and BLE auto-connect across reopen")
    @MainActor
    func companionSettingsPersistOverHostSession() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = HostSessionStore(workspacePath: directory.path)
        #expect(store.snapshot.device.autoConnect == true)
        #expect(store.snapshot.device.companionMode == "disabled")
        #expect(store.snapshot.device.standbyReady == false)

        _ = CompanionSettingsCard(store: store)

        store.send("set_companion_mode", ["mode": "collar_standby"])
        #expect(store.snapshot.device.companionMode == "collar_standby")
        #expect(store.snapshot.device.standbyReady == false)

        store.send("device_release")
        #expect(store.snapshot.device.autoConnect == false)
        store.shutdown()

        let reopened = HostSessionStore(workspacePath: directory.path)
        defer { reopened.shutdown() }
        #expect(reopened.snapshot.device.companionMode == "collar_standby")
        #expect(reopened.snapshot.device.autoConnect == false)

        reopened.send("set_ble_auto_connect", ["enabled": true])
        reopened.send("set_companion_mode", ["mode": "meeting_and_collar"])
        #expect(reopened.snapshot.device.autoConnect == true)
        #expect(reopened.snapshot.device.companionMode == "meeting_and_collar")
        #expect(reopened.snapshot.error == nil)
        #expect(reopened.nativeError == nil)
    }
}
