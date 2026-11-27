import CoreBluetooth
import Foundation
@testable import KoeAppleCore
import os
import Testing

private final class ReconnectTestDefaultsStore: BluetoothDefaultsStore {
    private let values = OSAllocatedUnfairLock<[String: String]>(initialState: [:])
    init(initial: [String: String] = [:]) { values.withLock { $0 = initial } }
    func string(forKey defaultName: String) -> String? { values.withLock { $0[defaultName] } }
    func set(_ value: String, forKey defaultName: String) { values.withLock { $0[defaultName] = value } }
    func removeObject(forKey defaultName: String) { values.withLock { _ = $0.removeValue(forKey: defaultName) } }
}

@MainActor
private final class VirtualReconnectClock {
    struct Entry {
        let id: Int
        let fireTime: TimeInterval
        let action: @MainActor @Sendable () -> Void
        var cancelled = false
    }

    private(set) var now: TimeInterval = 0
    private var nextId = 1
    private var entries: [Entry] = []
    var activeCount: Int { entries.filter { !$0.cancelled }.count }

    func schedule(_ delay: TimeInterval, action: @escaping @MainActor @Sendable () -> Void) -> (@MainActor @Sendable () -> Void) {
        let id = nextId
        nextId += 1
        entries.append(Entry(id: id, fireTime: now + delay, action: action))
        return { [weak self] in
            guard let self, let index = self.entries.firstIndex(where: { $0.id == id }) else { return }
            self.entries[index].cancelled = true
        }
    }

    func advance(by seconds: TimeInterval) {
        let target = now + seconds
        while true {
            let nextIndex = entries.indices
                .filter { !entries[$0].cancelled && entries[$0].fireTime <= target + 1e-9 }
                .min { lhs, rhs in
                    entries[lhs].fireTime != entries[rhs].fireTime
                        ? entries[lhs].fireTime < entries[rhs].fireTime
                        : entries[lhs].id < entries[rhs].id
                }
            guard let index = nextIndex else { break }
            let entry = entries[index]
            entries[index].cancelled = true
            now = entry.fireTime
            entry.action()
        }
        now = target
    }
}

@MainActor
private final class ReconnectTestCentral: BleCentral {
    var state: CBManagerState = .poweredOn
    var isScanning = false
    weak var delegate: CBCentralManagerDelegate?
    var connectedPeers: [any BlePeripheral] = []
    var knownPeers: [any BlePeripheral] = []
    var connectCalls: [UUID] = []
    var cancelCalls: [UUID] = []
    var scanCalls: [(services: [CBUUID]?, options: [String: Any]?)] = []
    var stopScanCount = 0

    func connectedPeripherals(withServices services: [CBUUID]) -> [any BlePeripheral] { connectedPeers }
    func knownPeripherals(withIdentifiers ids: [UUID]) -> [any BlePeripheral] { knownPeers.filter { ids.contains($0.identifier) } }
    func connectPeer(_ peer: any BlePeripheral) { connectCalls.append(peer.identifier) }
    func cancelPeer(_ peer: any BlePeripheral) { cancelCalls.append(peer.identifier) }
    func scanForPeripherals(withServices services: [CBUUID]?, options: [String: Any]?) { scanCalls.append((services, options)); isScanning = true }
    func stopScan() { isScanning = false; stopScanCount += 1 }
}

@MainActor
private final class ReconnectTestPeer: BlePeripheral {
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

@Suite("BLE auto-reconnect recovery and suppression")
@MainActor
struct BluetoothReconnectTests {
    private func makeHarness(
        savedPeer: ReconnectTestPeer? = nil,
        useVirtualClock: Bool = true
    ) -> (HostSessionStore, BluetoothBridge, ReconnectTestCentral, VirtualReconnectClock, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = HostSessionStore(workspacePath: directory.path)
        let initial = savedPeer.map { [BluetoothBridge.savedPeripheralKey: $0.identifier.uuidString] } ?? [:]
        let defaults = ReconnectTestDefaultsStore(initial: initial)
        let central = ReconnectTestCentral()
        if let savedPeer { central.knownPeers = [savedPeer] }
        let clock = VirtualReconnectClock()
        let bridge = BluetoothBridge(store: store, defaultsStore: defaults)
        bridge.makeCentral = { delegate, _ in central.delegate = delegate; return central }
        if useVirtualClock {
            bridge.scheduleReconnectTimer = { delay, action in clock.schedule(delay, action: action) }
        }
        store.onSnapshotChanged = { bridge.syncWithRuntimeDevice($0.device) }
        return (store, bridge, central, clock, directory)
    }

    private func markPeerReady(_ peer: ReconnectTestPeer, on bridge: BluetoothBridge, central: ReconnectTestCentral) {
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

    @Test("BleReconnectPolicy enforces bounded backoff schedule, user suppression, and wake guards")
    func purePolicyReducerTransitions() {
        #expect(BleReconnectPolicy.backoffSchedule == [1, 2, 5, 15, 30, 60])
        for (attempt, expected) in [(0, 1.0), (1, 2.0), (2, 5.0), (3, 15.0), (4, 30.0), (5, 60.0), (12, 60.0)] {
            #expect(BleReconnectPolicy.delay(forAttempt: attempt) == expected)
        }

        let (s1, e1) = BleReconnectPolicy.reduce(
            state: .idle, trigger: .unexpectedDisconnect, autoConnect: true,
            hasSavedPeer: true, teardownPending: false, isConnectedOrReady: false
        )
        #expect(s1 == .waitingBackoff(attempt: 0, delaySeconds: 1))
        #expect(e1 == .scheduleAfter(1))

        let (s2, e2) = BleReconnectPolicy.onBackoffElapsed(
            state: s1, autoConnect: true, teardownPending: false, isConnectedOrReady: false
        )
        #expect(s2 == .scanning(windowAttempt: 1))
        #expect(e2 == .startImmediate)

        let (s3, e3) = BleReconnectPolicy.reduce(
            state: s2, trigger: .connectFailed, autoConnect: true,
            hasSavedPeer: true, teardownPending: false, isConnectedOrReady: false
        )
        #expect(s3 == .waitingBackoff(attempt: 1, delaySeconds: 2))
        #expect(e3 == .scheduleAfter(2))

        let (suppressed, stopEffect) = BleReconnectPolicy.reduce(
            state: s3, trigger: .userDisconnectOrRelease, autoConnect: true,
            hasSavedPeer: true, teardownPending: false, isConnectedOrReady: false
        )
        #expect(suppressed == .suppressedByUser)
        #expect(stopEffect == .stopAndClear)

        for trigger in [BleReconnectTrigger.unexpectedDisconnect, .connectFailed, .radioPoweredOn, .hostWake] {
            let (next, effect) = BleReconnectPolicy.reduce(
                state: suppressed, trigger: trigger, autoConnect: true,
                hasSavedPeer: true, teardownPending: false, isConnectedOrReady: false
            )
            #expect(next == .suppressedByUser)
            #expect(effect == .none || effect == .stopAndClear)
        }

        let (healthyWake, healthyEffect) = BleReconnectPolicy.reduce(
            state: .idle, trigger: .hostWake, autoConnect: true,
            hasSavedPeer: true, teardownPending: false, isConnectedOrReady: true
        )
        #expect(healthyWake == .idle && healthyEffect == .none)

        let (noPeerWake, noPeerEffect) = BleReconnectPolicy.reduce(
            state: .idle, trigger: .hostWake, autoConnect: true,
            hasSavedPeer: false, teardownPending: false, isConnectedOrReady: false
        )
        #expect(noPeerWake == .idle && noPeerEffect == .none)

        let (resumed, resumeEffect) = BleReconnectPolicy.reduce(
            state: suppressed, trigger: .userScan, autoConnect: true,
            hasSavedPeer: true, teardownPending: false, isConnectedOrReady: false
        )
        #expect(resumed == .scanning(windowAttempt: 0) && resumeEffect == .startImmediate)
    }

    @Test("Unexpected mid-session disconnect schedules backoff reconnect and resets schedule after peerReady")
    func unexpectedDisconnectSchedulesBackoffAndResetsOnReady() {
        let peer = ReconnectTestPeer()
        let (store, bridge, central, clock, directory) = makeHarness(savedPeer: peer)
        defer {
            store.onSnapshotChanged = nil; bridge.shutdown(); store.shutdown()
            try? FileManager.default.removeItem(at: directory)
        }

        bridge.activateHost(allowsCoreBluetooth: true)
        bridge.centralStateDidChange(.poweredOn)
        markPeerReady(peer, on: bridge, central: central)
        #expect(bridge.reconnectState == .idle && bridge.reportedReady)

        let scanCountBeforeDrop = bridge.scanStartCount
        let connectCountBeforeDrop = central.connectCalls.count

        bridge.didDisconnect(peer, on: central, error: NSError(domain: CBErrorDomain, code: CBError.connectionTimeout.rawValue))
        #expect(!bridge.reportedReady && !bridge.isScanRequested)
        #expect(bridge.reconnectState == .waitingBackoff(attempt: 0, delaySeconds: 1))
        #expect(bridge.scanStartCount == scanCountBeforeDrop && clock.activeCount == 1)

        clock.advance(by: 0.9)
        #expect(bridge.scanStartCount == scanCountBeforeDrop)

        clock.advance(by: 0.1)
        #expect(bridge.reconnectState == .scanning(windowAttempt: 1))
        #expect(bridge.isScanRequested && bridge.scanStartCount == scanCountBeforeDrop + 1)
        #expect(central.connectCalls.count == connectCountBeforeDrop + 1 && central.connectCalls.last == peer.identifier)

        markPeerReady(peer, on: bridge, central: central)
        #expect(bridge.reconnectState == .idle && clock.activeCount == 0)

        bridge.didDisconnect(peer, on: central, error: nil)
        #expect(bridge.reconnectState == .waitingBackoff(attempt: 0, delaySeconds: 1))
    }

    @Test("macOS didFailToConnect backs off for both reconnecting and discovered peripherals")
    func macOSDidFailToConnectSchedulesExponentialBackoff() {
        let peer = ReconnectTestPeer()
        let (store, bridge, central, clock, directory) = makeHarness(savedPeer: peer)
        defer {
            store.onSnapshotChanged = nil; bridge.shutdown(); store.shutdown()
            try? FileManager.default.removeItem(at: directory)
        }

        bridge.activateHost(allowsCoreBluetooth: true)
        bridge.centralStateDidChange(.poweredOn)
        #expect(bridge.reconnectingPeripheral === peer)

        let error = NSError(domain: CBErrorDomain, code: CBError.connectionFailed.rawValue)
        bridge.didFailToConnect(peer, on: central, error: error)
        #expect(bridge.reconnectingPeripheral == nil && !central.isScanning)
        #expect(bridge.reconnectState == .waitingBackoff(attempt: 0, delaySeconds: 1))

        clock.advance(by: 1)
        #expect(bridge.reconnectState == .scanning(windowAttempt: 1) && bridge.reconnectingPeripheral === peer)

        bridge.didFailToConnect(peer, on: central, error: error)
        #expect(bridge.reconnectState == .waitingBackoff(attempt: 1, delaySeconds: 2))

        clock.advance(by: 2)
        #expect(bridge.reconnectState == .scanning(windowAttempt: 2))
        bridge.attachAndConnect(peer, on: central, displayName: "soundcore Work")
        bridge.didFailToConnect(peer, on: central, error: error)
        #expect(bridge.peripheral == nil && bridge.reconnectState == .waitingBackoff(attempt: 2, delaySeconds: 5))
    }

    @Test("Radio reset from poweredOff or resetting back to poweredOn automatically resumes scanning")
    func radioResetPoweredOffToPoweredOnResumesScanning() {
        let (store, bridge, central, clock, directory) = makeHarness()
        defer {
            store.onSnapshotChanged = nil; bridge.shutdown(); store.shutdown()
            try? FileManager.default.removeItem(at: directory)
        }

        bridge.central = central
        bridge.activateHost(allowsCoreBluetooth: false)
        #expect(bridge.scanStartCount == 1 && bridge.isScanRequested)

        central.state = .poweredOff
        bridge.centralStateDidChange(.poweredOff)
        #expect(!bridge.isScanRequested && !central.isScanning)
        #expect(store.snapshot.device.phase == "disconnected")

        central.state = .poweredOn
        bridge.centralStateDidChange(.poweredOn)
        #expect(bridge.isScanRequested && bridge.scanStartCount == 2 && central.isScanning)

        central.state = .resetting
        bridge.centralStateDidChange(.resetting)
        #expect(!bridge.isScanRequested && clock.activeCount == 0)

        central.state = .poweredOn
        bridge.centralStateDidChange(.poweredOn)
        #expect(bridge.isScanRequested && bridge.scanStartCount == 3 && central.isScanning)
    }

    @Test("User disconnect, phone release, and autoConnect=false suppress reconnect across timers and radio resets")
    func userSuppressionBlocksAllAutomaticReconnectTriggers() {
        let peer = ReconnectTestPeer()
        let (store, bridge, central, clock, directory) = makeHarness(savedPeer: peer)
        defer {
            store.onSnapshotChanged = nil; bridge.shutdown(); store.shutdown()
            try? FileManager.default.removeItem(at: directory)
        }

        bridge.activateHost(allowsCoreBluetooth: true)
        bridge.centralStateDidChange(.poweredOn)
        markPeerReady(peer, on: bridge, central: central)

        store.send(.deviceDisconnect)
        #expect(bridge.reconnectState == .suppressedByUser && clock.activeCount == 0)
        let scansAfterDisconnect = bridge.scanStartCount

        bridge.handleHostWake()
        central.state = .poweredOff; bridge.centralStateDidChange(.poweredOff)
        central.state = .poweredOn; bridge.centralStateDidChange(.poweredOn)
        clock.advance(by: 300)
        #expect(bridge.scanStartCount == scansAfterDisconnect && !bridge.isScanRequested)

        bridge.requestScan()
        #expect(bridge.isScanRequested && bridge.scanStartCount == scansAfterDisconnect + 1)
        markPeerReady(peer, on: bridge, central: central)

        bridge.didDisconnect(peer, on: central, error: nil)
        #expect(bridge.reconnectState == .waitingBackoff(attempt: 0, delaySeconds: 1) && clock.activeCount == 1)

        store.send(.deviceRelease)
        #expect(bridge.reconnectState == .suppressedByUser && clock.activeCount == 0)
        let scansAfterRelease = bridge.scanStartCount
        clock.advance(by: 300)
        bridge.handleHostWake()
        #expect(bridge.scanStartCount == scansAfterRelease && !bridge.isScanRequested)

        bridge.requestScan()
        markPeerReady(peer, on: bridge, central: central)
        bridge.didDisconnect(peer, on: central, error: nil)
        #expect(clock.activeCount == 1)

        store.send(.setBleAutoConnect(enabled: false))
        #expect(bridge.reconnectState == .suppressedByUser && clock.activeCount == 0)
        let scansAfterAutoConnectOff = bridge.scanStartCount
        clock.advance(by: 300)
        bridge.handleHostWake()
        #expect(bridge.scanStartCount == scansAfterAutoConnectOff && !bridge.isScanRequested)
    }

    @Test("Simulated 120-second disconnected window stays bounded at or below 6 scan starts")
    func boundedScanCountOver120SecondDisconnectedWindow() {
        let peer = ReconnectTestPeer()
        let (store, bridge, central, clock, directory) = makeHarness(savedPeer: peer)
        defer {
            store.onSnapshotChanged = nil; bridge.shutdown(); store.shutdown()
            try? FileManager.default.removeItem(at: directory)
        }

        bridge.activateHost(allowsCoreBluetooth: true)
        bridge.centralStateDidChange(.poweredOn)
        markPeerReady(peer, on: bridge, central: central)

        let baselineScans = bridge.scanStartCount
        let failError = NSError(domain: CBErrorDomain, code: CBError.connectionFailed.rawValue)
        var attemptTimes: [TimeInterval] = []
        bridge.didDisconnect(peer, on: central, error: failError)
        while clock.now < 120 {
            let before = bridge.scanStartCount
            clock.advance(by: 1)
            if bridge.scanStartCount > before {
                attemptTimes.append(clock.now)
                if let pending = bridge.reconnectingPeripheral {
                    bridge.didFailToConnect(pending, on: central, error: failError)
                }
            }
        }
        #expect(bridge.scanStartCount - baselineScans == 6)
        #expect(attemptTimes == [1, 3, 8, 23, 53, 113])

        let (store2, bridge2, central2, clock2, dir2) = makeHarness(savedPeer: peer)
        defer {
            store2.onSnapshotChanged = nil; bridge2.shutdown(); store2.shutdown()
            try? FileManager.default.removeItem(at: dir2)
        }

        bridge2.activateHost(allowsCoreBluetooth: true)
        bridge2.centralStateDidChange(.poweredOn)
        markPeerReady(peer, on: bridge2, central: central2)

        let silentBaseline = bridge2.scanStartCount
        bridge2.didDisconnect(peer, on: central2, error: nil)
        clock2.advance(by: 120)
        let silentReconnectScans = bridge2.scanStartCount - silentBaseline
        #expect(silentReconnectScans <= 6 && silentReconnectScans >= 3 && !central2.isScanning)
    }

    @Test("BluetoothBridge deinit invalidates scheduled reconnect Timer cleanly")
    func deinitInvalidatesRealReconnectTimer() throws {
        let peer = ReconnectTestPeer()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = HostSessionStore(workspacePath: directory.path)
        defer { store.shutdown() }

        let defaults = ReconnectTestDefaultsStore(initial: [BluetoothBridge.savedPeripheralKey: peer.identifier.uuidString])
        let central = ReconnectTestCentral()
        central.knownPeers = [peer]
        var capturedTimer: Timer?
        weak var weakBridge: BluetoothBridge?

        do {
            let bridge = BluetoothBridge(store: store, defaultsStore: defaults)
            weakBridge = bridge
            bridge.makeCentral = { delegate, _ in central.delegate = delegate; return central }
            bridge.activateHost(allowsCoreBluetooth: true)
            bridge.centralStateDidChange(.poweredOn)
            markPeerReady(peer, on: bridge, central: central)
            bridge.didDisconnect(peer, on: central, error: nil)
            capturedTimer = bridge.reconnectTimer
            #expect(capturedTimer?.isValid == true)
        }

        let timer = try #require(capturedTimer)
        #expect(weakBridge == nil && !timer.isValid && central.delegate == nil)
        timer.invalidate()
    }
}
