import AppKit
import CoreAudio
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
        #expect(destinations == ["today", "voice_input", "notes", "tasks", "live_minutes", "ask", "records", "settings"])
    }

    @Test("CoreAudio transport classification and idempotent audio input sync avoid generation churn")
    @MainActor
    func transportClassificationAndIdempotentInputSync() {
        #expect(NativeAudioSource.classifyTransport(kAudioDeviceTransportTypeBluetooth) == "bluetooth")
        #expect(NativeAudioSource.classifyTransport(kAudioDeviceTransportTypeBluetoothLE) == "bluetooth")
        #expect(NativeAudioSource.classifyTransport(kAudioDeviceTransportTypeUSB) == "usb")
        #expect(NativeAudioSource.classifyTransport(kAudioDeviceTransportTypeBuiltIn) == "built_in")
        #expect(NativeAudioSource.classifyTransport(kAudioDeviceTransportTypeVirtual) == "external")

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = HostSessionStore(workspacePath: directory.path)
        defer { store.shutdown() }
        let delegate = KoeAppDelegate()
        delegate.store = store

        let fixture = [
            MicrophoneInput(id: "built-in", name: "MacBook Pro 麦克风", transport: "built_in", isDefault: true),
            MicrophoneInput(id: "airpods", name: "AirPods Pro", transport: "bluetooth", isDefault: false)
        ]
        delegate.syncAudioInputsIfNeeded(force: true, inputsProvider: { fixture })
        #expect(store.snapshot.capture.selectedSource == "input:airpods")
        #expect(store.snapshot.capture.selectedBadge == "Mac 蓝牙")
        let generationAfterFirstSync = store.snapshot.generation

        delegate.syncAudioInputsIfNeeded(force: false, inputsProvider: { fixture })
        #expect(store.snapshot.generation == generationAfterFirstSync)

        let unplugged = [
            MicrophoneInput(id: "built-in", name: "MacBook Pro 麦克风", transport: "built_in", isDefault: true)
        ]
        delegate.syncAudioInputsIfNeeded(force: false, inputsProvider: { unplugged })
        #expect(store.snapshot.generation > generationAfterFirstSync)
        #expect(store.snapshot.capture.selectedSource == "input:built-in")
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

    @Test("Runtime disconnect with autoConnect enabled resets bridge link state and collar standby teardown emits pause frame")
    @MainActor
    func syncDisconnectWithAutoConnectAndStandbyTeardownPauseFrame() {
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

        let savedUUID = "22222222-3333-4444-5555-666666666666"
        UserDefaults.standard.set(savedUUID, forKey: key)
        store.send("set_ble_auto_connect", ["enabled": true])
        store.send("set_companion_mode", ["mode": "collar_standby"])

        let bridge = BluetoothBridge(store: store)
        bridge.reportedReady = true
        bridge.isScanRequested = true
        bridge.syncWithRuntimeDevice(store.snapshot.device)

        #expect(!bridge.reportedReady)
        #expect(!bridge.isScanRequested)
        #expect(UserDefaults.standard.string(forKey: key) == savedUUID)
        #expect(bridge.lastTeardownStopFrames == [BluetoothBridge.pauseRecordFrame])

        bridge.lastTeardownStopFrames = []
        bridge.releaseControl()
        #expect(store.snapshot.device.autoConnect == false)
        #expect(store.snapshot.device.companionMode == "collar_standby")
        #expect(UserDefaults.standard.string(forKey: key) == nil)
    }

    @Test("Re-enabling autoConnect after releaseControl syncs bridge without headless CBCentralManager instantiation")
    @MainActor
    func reenableAutoConnectAfterReleaseControl() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = HostSessionStore(workspacePath: directory.path)
        defer { store.shutdown() }

        let bridge = BluetoothBridge(store: store)
        bridge.releaseControl()
        #expect(bridge.lastObservedAutoConnect == false)

        store.send("set_ble_auto_connect", ["enabled": true])
        #expect(store.snapshot.device.autoConnect == true)
        bridge.syncWithRuntimeDevice(store.snapshot.device)
        #expect(bridge.lastObservedAutoConnect == true)
        #expect(bridge.central == nil)
    }

    @Test("activateHost with allowsCoreBluetooth false requests scan without touching CBCentralManager")
    @MainActor
    func activateHostHeadlessRequestsScan() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = HostSessionStore(workspacePath: directory.path)
        defer { store.shutdown() }

        #expect(store.snapshot.device.autoConnect == true)
        let bridge = BluetoothBridge(store: store)
        #expect(!bridge.isHostActivated)
        #expect(!bridge.isScanRequested)
        #expect(bridge.scanStartCount == 0)
        #expect(bridge.central == nil)

        bridge.activateHost(allowsCoreBluetooth: false)
        #expect(bridge.isHostActivated)
        #expect(!bridge.allowsCoreBluetooth)
        #expect(bridge.isScanRequested)
        #expect(bridge.scanStartCount == 1)
        #expect(bridge.central == nil)
    }

    @Test("Toggling autoConnect false while phase is scanning tears down scan immediately")
    @MainActor
    func toggleAutoConnectFalseTearsDownScanning() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = HostSessionStore(workspacePath: directory.path)
        defer { store.shutdown() }

        let bridge = BluetoothBridge(store: store)
        bridge.activateHost(allowsCoreBluetooth: false)
        #expect(bridge.isScanRequested)
        #expect(store.snapshot.device.phase == "scanning")

        store.send("set_ble_auto_connect", ["enabled": false])
        #expect(store.snapshot.device.autoConnect == false)
        bridge.syncWithRuntimeDevice(store.snapshot.device)

        #expect(!bridge.isScanRequested)
        #expect(bridge.lastObservedAutoConnect == false)
        #expect(store.snapshot.device.phase == "disconnected")
    }

    @Test("Manual scan with allowsCoreBluetooth false runs startScanning exactly once without double-cancelling")
    @MainActor
    func manualScanHeadlessRunsOnceWithoutDoubleCancelling() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = HostSessionStore(workspacePath: directory.path)
        defer { store.shutdown() }

        let delegate = KoeAppDelegate(makeDefaultStore: { store })
        _ = delegate.ensureSessionStore()
        delegate.bluetoothBridge.activateHost(allowsCoreBluetooth: false)
        #expect(delegate.bluetoothBridge.scanStartCount == 1)

        delegate.bluetoothBridge.releaseControl()
        #expect(delegate.bluetoothBridge.scanStartCount == 1)
        #expect(!delegate.bluetoothBridge.isScanRequested)
        #expect(store.snapshot.device.autoConnect == false)

        delegate.prepareManualScan()
        #expect(store.snapshot.device.autoConnect == true)
        delegate.bluetoothBridge.startScanningIfPoweredOn()
        #expect(delegate.bluetoothBridge.scanStartCount == 2)
        #expect(delegate.bluetoothBridge.isScanRequested)
        #expect(delegate.bluetoothBridge.central == nil)

        await Task.yield()
        #expect(delegate.bluetoothBridge.scanStartCount == 2)
        #expect(store.snapshot.device.guide?.mode == "connect_guide")
    }

    @Test("KoeAppDelegate lazily initializes, caches, and wires HostSessionStore on demand")
    @MainActor
    func lazySessionStoreInitialization() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("koe-s-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        var makeCount = 0
        let delegate = KoeAppDelegate(
            makeDefaultStore: {
                makeCount += 1
                return HostSessionStore(workspacePath: tempDir.path)
            }
        )
        defer { delegate.store?.shutdown() }

        #expect(makeCount == 0)
        #expect(delegate.store == nil)

        let store1 = delegate.ensureSessionStore()
        #expect(makeCount == 1)
        #expect(delegate.store === store1)
        #expect(delegate.bluetoothBridge.store === store1)

        let socketCandidates = [
            tempDir.appendingPathComponent(".koe/koe.sock").path,
            tempDir.appendingPathComponent("koe.sock").path
        ]
        #expect(socketCandidates.contains(where: { FileManager.default.fileExists(atPath: $0) }))

        let store2 = delegate.ensureSessionStore()
        #expect(makeCount == 1)
        #expect(store2 === store1)

        let preassignedDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: preassignedDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: preassignedDir) }
        let preassignedStore = HostSessionStore(workspacePath: preassignedDir.path)
        defer { preassignedStore.shutdown() }

        var preassignedMakeCount = 0
        let preassignedDelegate = KoeAppDelegate(
            makeDefaultStore: {
                preassignedMakeCount += 1
                return HostSessionStore(workspacePath: tempDir.path)
            }
        )
        preassignedDelegate.store = preassignedStore
        let retrievedStore = preassignedDelegate.ensureSessionStore()
        #expect(preassignedMakeCount == 0)
        #expect(retrievedStore === preassignedStore)
    }
}
