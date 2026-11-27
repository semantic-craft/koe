import AppKit
import CoreBluetooth
import Foundation
@testable import Koe
@testable import KoeAppleCore
import os
import Testing

private final class WakeTestDefaultsStore: BluetoothDefaultsStore {
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
private final class WakeTestCentral: BleCentral {
    var state: CBManagerState = .poweredOn
    var isScanning = false
    weak var delegate: CBCentralManagerDelegate?
    var knownPeers: [any BlePeripheral] = []
    var connectCalls: [UUID] = []
    var cancelCalls: [UUID] = []
    var scanCount = 0

    func connectedPeripherals(withServices services: [CBUUID]) -> [any BlePeripheral] { [] }

    func knownPeripherals(withIdentifiers ids: [UUID]) -> [any BlePeripheral] {
        knownPeers.filter { ids.contains($0.identifier) }
    }

    func connectPeer(_ peer: any BlePeripheral) {
        connectCalls.append(peer.identifier)
    }

    func cancelPeer(_ peer: any BlePeripheral) {
        cancelCalls.append(peer.identifier)
    }

    func scanForPeripherals(withServices services: [CBUUID]?, options: [String: Any]?) {
        scanCount += 1
        isScanning = true
    }

    func stopScan() {
        isScanning = false
    }
}

@MainActor
private final class WakeTestPeer: BlePeripheral {
    let identifier = UUID()
    var name: String? = "soundcore Work"
    var state: CBPeripheralState = .connected
    weak var delegate: CBPeripheralDelegate?
    var services: [CBService]?
    var canSendWriteWithoutResponse = true

    func discoverServices(_ serviceUUIDs: [CBUUID]?) {}
    func isNotifying(_ characteristic: CBCharacteristic) -> Bool { false }
    func setNotifyValue(_ enabled: Bool, for characteristic: CBCharacteristic) {}
    func maximumWriteValueLength(for type: CBCharacteristicWriteType) -> Int { 128 }
    func writeValue(_ data: Data, for characteristic: CBCharacteristic, type: CBCharacteristicWriteType) {}
}

extension SerializedMacHostSuites {
@Suite("macOS system wake BLE reconnect host integration", .serialized)
struct WakeReconnectHostTests {
    @MainActor
    private func markReady(_ peer: WakeTestPeer, on bridge: BluetoothBridge, central: WakeTestCentral) {
        let writeChar = CBMutableCharacteristic(
            type: BluetoothBridge.writeCharacteristicUUID,
            properties: [.write, .writeWithoutResponse],
            value: nil,
            permissions: .writeable
        )
        peer.state = .connected
        bridge.central = central
        bridge.peripheral = peer
        bridge.reconnectingPeripheral = nil
        bridge.writeCharacteristic = writeChar
        bridge.notifyFound = true
        bridge.notifyReady = true
        bridge.announceConnection(peer)
        bridge.checkReady()
    }

    @Test("NSWorkspace sleep pauses pending backoff and didWakeNotification triggers immediate reconnect")
    @MainActor
    func systemWakeTriggersReconnectForSavedPeripheral() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = HostSessionStore(workspacePath: directory.path)
        defer { store.shutdown() }

        let peer = WakeTestPeer()
        let central = WakeTestCentral()
        central.knownPeers = [peer]
        let defaults = WakeTestDefaultsStore(initial: [BluetoothBridge.savedPeripheralKey: peer.identifier.uuidString])
        let workspaceCenter = NotificationCenter()

        let bridge = BluetoothBridge(store: store, defaultsStore: defaults)
        bridge.makeCentral = { delegate, _ in
            central.delegate = delegate
            return central
        }
        var cancelledBackoffCount = 0
        bridge.scheduleReconnectTimer = { _, _ in
            { cancelledBackoffCount += 1 }
        }

        let delegate = KoeAppDelegate(
            playback: NativePlayback(),
            bluetoothBridge: bridge,
            defaultInputsProvider: { [] },
            workspaceNotificationCenter: workspaceCenter
        )
        delegate.store = store
        defer {
            delegate.store = nil
            bridge.shutdown()
        }

        bridge.activateHost(allowsCoreBluetooth: true)
        bridge.centralStateDidChange(.poweredOn)
        markReady(peer, on: bridge, central: central)

        bridge.didDisconnect(peer, on: central, error: nil)
        #expect(bridge.reconnectState == .waitingBackoff(attempt: 0, delaySeconds: 1))
        let scansBeforeWake = bridge.scanStartCount
        let connectsBeforeWake = central.connectCalls.count

        workspaceCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
        #expect(cancelledBackoffCount >= 1)
        #expect(!bridge.isScanRequested)

        workspaceCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        #expect(bridge.isScanRequested)
        #expect(bridge.scanStartCount == scansBeforeWake + 1)
        #expect(central.connectCalls.count == connectsBeforeWake + 1)
        #expect(central.connectCalls.last == peer.identifier)
    }

    @Test("NSWorkspace.didWakeNotification is a no-op when the BLE link is healthy and ready")
    @MainActor
    func systemWakeIsNoOpOnHealthyConnectedLink() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = HostSessionStore(workspacePath: directory.path)
        defer { store.shutdown() }

        let peer = WakeTestPeer()
        let central = WakeTestCentral()
        central.knownPeers = [peer]
        let defaults = WakeTestDefaultsStore(initial: [BluetoothBridge.savedPeripheralKey: peer.identifier.uuidString])
        let workspaceCenter = NotificationCenter()

        let bridge = BluetoothBridge(store: store, defaultsStore: defaults)
        bridge.makeCentral = { delegate, _ in
            central.delegate = delegate
            return central
        }
        let delegate = KoeAppDelegate(
            playback: NativePlayback(),
            bluetoothBridge: bridge,
            defaultInputsProvider: { [] },
            workspaceNotificationCenter: workspaceCenter
        )
        delegate.store = store
        defer {
            delegate.store = nil
            bridge.shutdown()
        }

        bridge.activateHost(allowsCoreBluetooth: true)
        bridge.centralStateDidChange(.poweredOn)
        markReady(peer, on: bridge, central: central)

        let scansBeforeWake = bridge.scanStartCount
        let scanCallsBeforeWake = central.scanCount
        let connectsBeforeWake = central.connectCalls.count

        workspaceCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
        workspaceCenter.post(name: NSWorkspace.didWakeNotification, object: nil)

        #expect(bridge.reportedReady)
        #expect(bridge.peripheral === peer)
        #expect(bridge.scanStartCount == scansBeforeWake)
        #expect(central.scanCount == scanCallsBeforeWake)
        #expect(central.connectCalls.count == connectsBeforeWake)
        #expect(central.cancelCalls.isEmpty)
    }

    @Test("NSWorkspace.didWakeNotification respects autoConnect=false, deviceRelease, and explicit disconnect")
    @MainActor
    func systemWakeRespectsUserSuppression() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = HostSessionStore(workspacePath: directory.path)
        defer { store.shutdown() }

        let peer = WakeTestPeer()
        let central = WakeTestCentral()
        central.knownPeers = [peer]
        let defaults = WakeTestDefaultsStore(initial: [BluetoothBridge.savedPeripheralKey: peer.identifier.uuidString])
        let workspaceCenter = NotificationCenter()

        let bridge = BluetoothBridge(store: store, defaultsStore: defaults)
        bridge.makeCentral = { delegate, _ in
            central.delegate = delegate
            return central
        }
        let delegate = KoeAppDelegate(
            playback: NativePlayback(),
            bluetoothBridge: bridge,
            defaultInputsProvider: { [] },
            workspaceNotificationCenter: workspaceCenter
        )
        delegate.store = store
        defer {
            delegate.store = nil
            bridge.shutdown()
        }

        bridge.activateHost(allowsCoreBluetooth: true)
        bridge.centralStateDidChange(.poweredOn)
        markReady(peer, on: bridge, central: central)

        store.send(.deviceDisconnect)
        let scansAfterDisconnect = bridge.scanStartCount
        workspaceCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        #expect(!bridge.isScanRequested)
        #expect(bridge.scanStartCount == scansAfterDisconnect)

        delegate.handleBleScanRequest()
        markReady(peer, on: bridge, central: central)
        store.send(.deviceRelease)
        let scansAfterRelease = bridge.scanStartCount
        workspaceCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        #expect(!bridge.isScanRequested)
        #expect(bridge.scanStartCount == scansAfterRelease)

        delegate.handleBleScanRequest()
        markReady(peer, on: bridge, central: central)
        store.send(.setBleAutoConnect(enabled: false))
        let scansAfterAutoConnectOff = bridge.scanStartCount
        workspaceCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        #expect(!bridge.isScanRequested)
        #expect(bridge.scanStartCount == scansAfterAutoConnectOff)
    }

    @Test("Workspace power observers are removed on applicationWillTerminate and KoeAppDelegate deinit")
    @MainActor
    func workspacePowerObserversRemovedOnTerminateAndDeinit() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = HostSessionStore(workspacePath: directory.path)
        defer { store.shutdown() }

        let peer = WakeTestPeer()
        let central = WakeTestCentral()
        central.knownPeers = [peer]
        let defaults = WakeTestDefaultsStore(initial: [BluetoothBridge.savedPeripheralKey: peer.identifier.uuidString])
        let workspaceCenter = NotificationCenter()

        let bridgeA = BluetoothBridge(store: store, defaultsStore: defaults)
        bridgeA.makeCentral = { delegate, _ in
            central.delegate = delegate
            return central
        }
        let delegateA = KoeAppDelegate(
            playback: NativePlayback(),
            bluetoothBridge: bridgeA,
            defaultInputsProvider: { [] },
            workspaceNotificationCenter: workspaceCenter
        )
        delegateA.store = store
        bridgeA.activateHost(allowsCoreBluetooth: true)
        bridgeA.centralStateDidChange(.poweredOn)
        let scansBeforeTerminate = bridgeA.scanStartCount
        delegateA.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        workspaceCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        #expect(!bridgeA.isScanRequested)
        #expect(bridgeA.scanStartCount == scansBeforeTerminate)

        let store2 = HostSessionStore(workspacePath: directory.path)
        defer { store2.shutdown() }
        let bridgeB = BluetoothBridge(store: store2, defaultsStore: defaults)
        bridgeB.makeCentral = { delegate, _ in
            central.delegate = delegate
            return central
        }
        weak var weakDelegateB: KoeAppDelegate?
        do {
            let delegateB = KoeAppDelegate(
                playback: NativePlayback(),
                bluetoothBridge: bridgeB,
                defaultInputsProvider: { [] },
                workspaceNotificationCenter: workspaceCenter
            )
            weakDelegateB = delegateB
            delegateB.store = store2
            bridgeB.activateHost(allowsCoreBluetooth: true)
            bridgeB.centralStateDidChange(.poweredOn)
            markReady(peer, on: bridgeB, central: central)
            bridgeB.didDisconnect(peer, on: central, error: nil)
            delegateB.store = nil
        }

        let scansAfterDeinit = bridgeB.scanStartCount
        #expect(weakDelegateB == nil)
        workspaceCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        #expect(bridgeB.scanStartCount == scansAfterDeinit)
        bridgeB.shutdown()
    }
}
}
