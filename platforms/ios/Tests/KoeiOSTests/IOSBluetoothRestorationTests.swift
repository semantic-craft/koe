import CoreBluetooth
@testable import KoeAppleCore
import UIKit
import XCTest
@testable import KoeiOSApp

@MainActor
final class IOSBluetoothRestorationTests: XCTestCase {
    private func withBridge(_ body: (BluetoothBridge, TestCentral, HostSessionStore) throws -> Void) throws {
        let key = BluetoothBridge.savedPeripheralKey
        let previous = UserDefaults.standard.string(forKey: key)
        defer { UserDefaults.standard.set(previous, forKey: key) }
        UserDefaults.standard.removeObject(forKey: key)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = HostSessionStore(workspacePath: root.path, credentials: NativeCredentialsiOS(forceIsolated: true))
        let bridge = BluetoothBridge(store: store)
        let central = TestCentral()
        bridge.makeIOSCentral = { _, options in central.options.append(options); return central }
        store.onSnapshotChanged = { bridge.syncWithRuntimeDevice($0.device) }
        bridge.activateHost()
        defer { store.onSnapshotChanged = nil; bridge.shutdown(); store.shutdown() }
        try body(bridge, central, store)
    }

    func testOnlyMatchingLaunchIdentifierCreatesOneRestorableCentral() throws {
        let key = BluetoothBridge.savedPeripheralKey
        let previous = UserDefaults.standard.string(forKey: key)
        defer { UserDefaults.standard.set(previous, forKey: key) }
        UserDefaults.standard.removeObject(forKey: key)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let delegate = IOSAppDelegate()
        let session = IOSLaunchSession(bridgeActions: HostBridgeActions(), arguments: ["Koe", "-koe-workspace", root.path],
                                       environment: [:], source: TestMicrophone(), allowsCoreBluetooth: false)
        defer { session.shutdown() }
        delegate.session = session
        let bridge = session.coordinator.bluetoothBridge
        let central = TestCentral()
        bridge.makeIOSCentral = { _, options in central.options.append(options); return central }
        func launch(_ identifiers: [String]?) {
            let options = identifiers.map { [UIApplication.LaunchOptionsKey.bluetoothCentrals: $0] }
            XCTAssertTrue(delegate.application(.shared, didFinishLaunchingWithOptions: options))
        }
        let ids = ["other", "com.semanticcraft.koe.ios.central"]
        launch(ids)
        XCTAssertNil(bridge.central, "Radio disabled for this host")
        bridge.activateHost()
        launch(nil)
        launch(["unrelated"])
        XCTAssertNil(bridge.central)
        launch(ids)
        launch(ids)
        XCTAssertTrue(bridge.central === central)
        XCTAssertEqual(central.options.compactMap { $0[CBCentralManagerOptionRestoreIdentifierKey] as? String },
                       ["com.semanticcraft.koe.ios.central"])
    }

    func testLaunchRestorationWithSavedPeripheralRestoresOnceWithoutSpuriousScan() throws {
        let key = BluetoothBridge.savedPeripheralKey
        let previous = UserDefaults.standard.string(forKey: key)
        defer { UserDefaults.standard.set(previous, forKey: key) }
        UserDefaults.standard.set(UUID().uuidString, forKey: key)

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }

        let central = TestCentral()
        let bridge = BluetoothBridge()
        bridge.makeIOSCentral = { _, options in
            central.options.append(options)
            return central
        }

        let delegate = IOSAppDelegate()
        delegate.makeSession = { restoreIdentifiers in
            IOSLaunchSession(
                bridgeActions: HostBridgeActions(),
                arguments: ["Koe", "-koe-workspace", root.path],
                environment: [:],
                source: TestMicrophone(),
                allowsCoreBluetooth: true,
                bluetoothBridge: bridge,
                restoreIdentifiers: restoreIdentifiers
            )
        }
        defer { delegate.session.shutdown() }

        XCTAssertTrue(delegate.application(.shared, didFinishLaunchingWithOptions: [
            .bluetoothCentrals: [BluetoothBridge.iosRestoreIdentifier]
        ]))
        XCTAssertTrue(bridge.central === central)
        XCTAssertEqual(central.options.count, 1)
        XCTAssertEqual(
            central.options.compactMap { $0[CBCentralManagerOptionRestoreIdentifierKey] as? String },
            [BluetoothBridge.iosRestoreIdentifier]
        )
        XCTAssertEqual(bridge.scanStartCount, 0)
        XCTAssertFalse(bridge.isScanRequested)
        XCTAssertTrue(central.scans.isEmpty)
        XCTAssertEqual(delegate.session.store.snapshot.device.phase, "disconnected")

        let peer = TestPeer(notifying: true)
        bridge.stageRestoration(peripherals: [peer], scanServices: [])
        bridge.centralStateDidChange(.poweredOn)
        XCTAssertTrue(bridge.peripheral === peer)
        XCTAssertTrue(bridge.reportedReady)
        XCTAssertEqual(bridge.scanStartCount, 0)
        XCTAssertTrue(central.scans.isEmpty)
    }

    func testRestorationWithDisconnectedPeerFallsBackToKnownReconnect() throws {
        let key = BluetoothBridge.savedPeripheralKey
        let previous = UserDefaults.standard.string(forKey: key)
        defer { UserDefaults.standard.set(previous, forKey: key) }
        let savedPeer = TestPeer(notifying: false)
        savedPeer.state = .disconnected
        UserDefaults.standard.set(savedPeer.identifier.uuidString, forKey: key)

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }

        let central = TestCentral()
        central.known = [savedPeer]
        let bridge = BluetoothBridge()
        bridge.makeIOSCentral = { _, options in
            central.options.append(options)
            return central
        }

        let delegate = IOSAppDelegate()
        delegate.makeSession = { restoreIdentifiers in
            IOSLaunchSession(
                bridgeActions: HostBridgeActions(),
                arguments: ["Koe", "-koe-workspace", root.path],
                environment: [:],
                source: TestMicrophone(),
                allowsCoreBluetooth: true,
                bluetoothBridge: bridge,
                restoreIdentifiers: restoreIdentifiers
            )
        }
        defer { delegate.session.shutdown() }

        XCTAssertTrue(delegate.application(.shared, didFinishLaunchingWithOptions: [
            .bluetoothCentrals: [BluetoothBridge.iosRestoreIdentifier]
        ]))
        XCTAssertEqual(bridge.scanStartCount, 0)
        XCTAssertTrue(central.scans.isEmpty)

        bridge.stageRestoration(peripherals: [savedPeer], scanServices: [])
        bridge.centralStateDidChange(.poweredOn)
        XCTAssertEqual(bridge.scanStartCount, 1)
        XCTAssertTrue(bridge.isScanRequested)
        XCTAssertEqual(central.connections, [savedPeer.identifier])
        XCTAssertEqual(central.scans.count, 1)
        XCTAssertEqual(delegate.session.store.snapshot.device.phase, "scanning")
    }

    func testPoweredOnAdoptsCachedChannelsAndWritesRustHandshake() throws {
        try withBridge { bridge, central, _ in
            let peer = TestPeer(notifying: true)
            bridge.restoreCentralIfNeeded(restoreIdentifiers: [BluetoothBridge.iosRestoreIdentifier])
            bridge.stageRestoration(peripherals: [peer], scanServices: [BluetoothBridge.d3200ServiceUUID])
            XCTAssertTrue(peer.delegate === bridge)
            XCTAssertFalse(bridge.reportedReady)
            XCTAssertTrue(peer.writes.isEmpty)
            XCTAssertNil(bridge.peripheral)
            bridge.centralStateDidChange(.poweredOn)
            XCTAssertTrue(bridge.peripheral === peer)
            XCTAssertTrue(bridge.reportedReady)
            XCTAssertTrue(peer.writes.contains { $0.count > 6 && $0[5] == 0x2E && $0[6] == 1 })
            XCTAssertFalse(peer.discovered || peer.subscribed)
            XCTAssertTrue(central.scans.isEmpty && central.connections.isEmpty)
        }
    }

    func testIncompleteChannelsDiscoverAndUnsubscribedChannelsSubscribe() throws {
        for missing in ["service", "write", "notify", "subscription"] {
            try withBridge { bridge, _, _ in
                let peer = TestPeer(notifying: false, missing: missing)
                bridge.restoreCentralIfNeeded(restoreIdentifiers: [BluetoothBridge.iosRestoreIdentifier])
                bridge.stageRestoration(peripherals: [peer], scanServices: [])
                XCTAssertFalse(peer.discovered || peer.subscribed)
                bridge.centralStateDidChange(.poweredOn)
                XCTAssertFalse(bridge.reportedReady)
                XCTAssertEqual(peer.discovered, missing != "subscription")
                XCTAssertEqual(peer.subscribed, missing == "subscription")
            }
        }
    }

    func testReleasedDeviceCancelsAllRestoredWorkOnlyAfterPowerOn() throws {
        try withBridge { bridge, central, store in
            store.send(.setBleAutoConnect(enabled: false))
            let peers = [TestPeer(notifying: true), TestPeer(notifying: false)]
            peers[1].state = .connecting
            bridge.restoreCentralIfNeeded(restoreIdentifiers: [BluetoothBridge.iosRestoreIdentifier])
            central.isScanning = true
            bridge.stageRestoration(peripherals: peers, scanServices: [CBUUID(string: "F5DA")])
            XCTAssertTrue(central.cancelled.isEmpty)
            bridge.centralStateDidChange(.poweredOn)
            bridge.centralStateDidChange(.poweredOn)
            XCTAssertEqual(central.cancelled, peers.map(\.identifier))
            XCTAssertFalse(bridge.reportedReady || bridge.isScanRequested || central.isScanning)
            XCTAssertTrue(central.connections.isEmpty && central.scans.isEmpty)
        }
    }

    func testRestoredScanDoesNotDuplicatePendingConnection() throws {
        try withBridge { bridge, central, _ in
            let peer = TestPeer(notifying: false)
            peer.state = .connecting
            central.available = [peer]
            bridge.restoreCentralIfNeeded(restoreIdentifiers: [BluetoothBridge.iosRestoreIdentifier])
            bridge.stageRestoration(peripherals: [peer], scanServices: [CBUUID(string: "F5DA")])
            bridge.centralStateDidChange(.poweredOn)
            bridge.centralStateDidChange(.poweredOn)
            XCTAssertTrue(bridge.reconnectingPeripheral === peer)
            XCTAssertTrue(central.connections.isEmpty && central.scans.isEmpty)
            peer.state = .connected
            bridge.didConnect(peer, on: central)
            XCTAssertTrue(bridge.peripheral === peer && peer.discovered)
            XCTAssertNil(bridge.reconnectingPeripheral)
        }
    }

    func testScanOnlyRestorationLeavesOwnedConnectionAlone() throws {
        try withBridge { bridge, central, store in
            let peer = TestPeer(notifying: true)
            bridge.restoreCentralIfNeeded(restoreIdentifiers: [BluetoothBridge.iosRestoreIdentifier])
            bridge.stageRestoration(peripherals: [peer], scanServices: [])
            bridge.centralStateDidChange(.poweredOn)
            let phase = store.runtimeDevice.phase
            bridge.stageRestoration(peripherals: [], scanServices: [CBUUID(string: "F5DA")])
            bridge.centralStateDidChange(.poweredOn)
            XCTAssertFalse(bridge.isScanRequested)
            XCTAssertEqual(store.runtimeDevice.phase, phase)
            XCTAssertTrue(central.connections.isEmpty && central.scans.isEmpty)
        }
    }

    func testFailedRestoredConnectionReturnsToBackgroundDiscovery() throws {
        try withBridge { bridge, central, _ in
            let peer = TestPeer(notifying: false)
            peer.state = .connecting
            bridge.restoreCentralIfNeeded(restoreIdentifiers: [BluetoothBridge.iosRestoreIdentifier])
            central.isScanning = true
            bridge.stageRestoration(peripherals: [peer], scanServices: [CBUUID(string: "F5DA")])
            bridge.setSceneInBackground(true)
            XCTAssertTrue(central.scans.isEmpty)
            bridge.centralStateDidChange(.poweredOn)
            bridge.didFailToConnect(peer, on: central, error: nil)
            XCTAssertNil(bridge.reconnectingPeripheral)
            XCTAssertTrue(bridge.isScanRequested)
            XCTAssertEqual(central.scans.last?.services, [BluetoothBridge.d3200ServiceUUID, CBUUID(string: "F5DA")])
            XCTAssertTrue(central.connections.isEmpty)
        }
    }

    func testRestoredScanFollowsSceneAndDoesNotReconnectOnRescan() throws {
        try withBridge { bridge, central, _ in
            bridge.restoreCentralIfNeeded(restoreIdentifiers: [BluetoothBridge.iosRestoreIdentifier])
            bridge.stageRestoration(peripherals: [], scanServices: [CBUUID(string: "F5DA")])
            XCTAssertTrue(central.scans.isEmpty)
            bridge.centralStateDidChange(.poweredOn)
            XCTAssertTrue(bridge.isScanRequested)
            XCTAssertNil(try XCTUnwrap(central.scans.first).services)
            XCTAssertEqual(central.scans.first?.options?[CBCentralManagerScanOptionAllowDuplicatesKey] as? Bool, true)
            central.available = [TestPeer(notifying: true)]
            bridge.setSceneInBackground(true)
            bridge.setSceneInBackground(true)
            let background = try XCTUnwrap(central.scans.last)
            XCTAssertEqual(background.services, [BluetoothBridge.d3200ServiceUUID, CBUUID(string: "F5DA")])
            XCTAssertNil(background.options)
            bridge.setSceneInBackground(false)
            XCTAssertEqual(central.scans.count, 3)
            XCTAssertNil(central.scans.last?.services)
            XCTAssertEqual(central.scans.last?.options?[CBCentralManagerScanOptionAllowDuplicatesKey] as? Bool, true)
            XCTAssertTrue(central.connections.isEmpty)
        }
    }
}

@MainActor
private final class TestCentral: BleCentral {
    var options: [[String: Any]] = []
    var state = CBManagerState.poweredOn
    var isScanning = false
    weak var delegate: CBCentralManagerDelegate?
    var available: [any BlePeripheral] = []
    var known: [any BlePeripheral] = []
    var connections: [UUID] = []
    var cancelled: [UUID] = []
    var scans: [(services: [CBUUID]?, options: [String: Any]?)] = []
    func connectedPeripherals(withServices services: [CBUUID]) -> [any BlePeripheral] { available }
    func knownPeripherals(withIdentifiers ids: [UUID]) -> [any BlePeripheral] {
        known.filter { ids.contains($0.identifier) }
    }
    func connectPeer(_ peer: any BlePeripheral) { connections.append(peer.identifier) }
    func cancelPeer(_ peer: any BlePeripheral) { cancelled.append(peer.identifier) }
    func stopScan() { isScanning = false }
    func scanForPeripherals(withServices services: [CBUUID]?, options: [String: Any]?) {
        scans.append((services, options))
        isScanning = true
    }
}

@MainActor
private final class TestPeer: BlePeripheral {
    let identifier = UUID()
    var state = CBPeripheralState.connected
    let name: String? = "soundcore Work"
    weak var delegate: CBPeripheralDelegate?
    var services: [CBService]?
    let notifying: Bool
    var discovered = false
    var subscribed = false
    var writes: [Data] = []
    var canSendWriteWithoutResponse = true

    init(notifying: Bool, missing: String? = nil) {
        self.notifying = notifying
        let write = CBMutableCharacteristic(type: CBUUID(string: "7777"), properties: .write, value: nil, permissions: .writeable)
        let notify = CBMutableCharacteristic(type: CBUUID(string: "8888"), properties: .notify, value: nil, permissions: .readable)
        let service = CBMutableService(type: BluetoothBridge.d3200ServiceUUID, primary: true)
        service.characteristics = [missing == "write" ? nil : write, missing == "notify" ? nil : notify].compactMap { $0 }
        services = missing == "service" ? nil : [service]
    }

    func isNotifying(_ characteristic: CBCharacteristic) -> Bool { notifying }
    func discoverServices(_ uuids: [CBUUID]?) { discovered = true }
    func setNotifyValue(_ enabled: Bool, for characteristic: CBCharacteristic) { subscribed = enabled }
    func maximumWriteValueLength(for type: CBCharacteristicWriteType) -> Int { 512 }
    func writeValue(_ data: Data, for characteristic: CBCharacteristic, type: CBCharacteristicWriteType) { writes.append(data) }
}
