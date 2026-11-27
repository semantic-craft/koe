import CoreBluetooth
import Foundation
@testable import KoeAppleCore
import Testing

@MainActor
private final class RecordingReconnectWriteLink: BleWriteLink {
    var supportsWriteResponse = true
    var supportsWriteWithoutResponse = false
    var canSendWriteWithoutResponse = true
    var writeCount = 0
    var cancelCount = 0

    func maximumWriteValueLength(for type: CBCharacteristicWriteType) -> Int { 128 }
    func write(_ data: Data, type: CBCharacteristicWriteType) { writeCount += 1 }
    func cancel() { cancelCount += 1 }
}

@Suite("BLE auto-reconnect review regressions")
@MainActor
struct BluetoothReconnectEdgeCaseTests {
    private func makeHarness(
        savedPeer: ReconnectTestPeer? = nil
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
        bridge.scheduleReconnectTimer = { delay, action in clock.schedule(delay, action: action) }
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

    private func rxRecordingStartedFrame() -> Data {
        var bytes: [UInt8] = [0x09, 0xFF, 0x00, 0x00, 0x01, 0x18, 0x81, 0x0E, 0x00, 0x93, 0x03, 0x00, 0x00]
        bytes.append(UInt8(bytes.reduce(0) { $0 + Int($1) } & 0xFF))
        return Data(bytes)
    }

    @Test("GATT and non-teardown write failures trigger bounded backoff reconnect while teardown write failure stays suppressed")
    func gattAndWriteFailuresTriggerBoundedBackoffReconnect() {
        let peer = ReconnectTestPeer()
        let (store, bridge, central, clock, directory) = makeHarness(savedPeer: peer)
        defer {
            store.onSnapshotChanged = nil; bridge.shutdown(); store.shutdown()
            try? FileManager.default.removeItem(at: directory)
        }

        bridge.activateHost(allowsCoreBluetooth: true)
        bridge.centralStateDidChange(.poweredOn)
        markPeerReady(peer, on: bridge, central: central)

        let scansBeforeWriteFail = bridge.scanStartCount
        let gattError = NSError(domain: CBATTErrorDomain, code: CBATTError.unlikelyError.rawValue)
        bridge.awaitingWriteResponse = true
        bridge.writeDidComplete(error: gattError)

        #expect(!bridge.reportedReady && bridge.peripheral == nil)
        #expect(store.snapshot.device.phase == "disconnected")
        #expect(bridge.reconnectState == .waitingBackoff(attempt: 0, delaySeconds: 1))
        #expect(clock.activeCount == 1)

        clock.advance(by: 1)
        #expect(bridge.reconnectState == .scanning(windowAttempt: 1))
        #expect(bridge.isScanRequested && bridge.scanStartCount == scansBeforeWriteFail + 1)
        #expect(central.connectCalls.last == peer.identifier)

        bridge.attachAndConnect(peer, on: central, displayName: "soundcore Work")
        bridge.didDiscoverServices(for: peer, error: gattError)
        #expect(bridge.peripheral == nil)
        #expect(bridge.reconnectState == .waitingBackoff(attempt: 1, delaySeconds: 2))
        #expect(clock.activeCount == 1)

        clock.advance(by: 2)
        #expect(bridge.reconnectState == .scanning(windowAttempt: 2))
        #expect(bridge.isScanRequested && bridge.scanStartCount == scansBeforeWriteFail + 2)

        let service = CBMutableService(type: BluetoothBridge.d3200ServiceUUID, primary: true)
        bridge.attachAndConnect(peer, on: central, displayName: "soundcore Work")
        bridge.didDiscoverCharacteristics(for: peer, service: service, error: gattError)
        #expect(bridge.peripheral == nil)
        #expect(bridge.reconnectState == .waitingBackoff(attempt: 2, delaySeconds: 5))
        #expect(clock.activeCount == 1)

        clock.advance(by: 5)
        #expect(bridge.reconnectState == .scanning(windowAttempt: 3))
        #expect(bridge.isScanRequested && bridge.scanStartCount == scansBeforeWriteFail + 3)

        markPeerReady(peer, on: bridge, central: central)
        store.ingestBleChunk(rxRecordingStartedFrame(), nowEpochSec: 1_800_000_000)
        #expect(store.snapshot.device.recording)
        let recordingLink = RecordingReconnectWriteLink()
        bridge.outboundQueue.reset()
        bridge.writeLink = recordingLink
        store.send(.deviceDisconnect)
        #expect(bridge.teardownPending && recordingLink.writeCount == 1)

        let scansBeforeTeardownFail = bridge.scanStartCount
        bridge.writeDidComplete(error: gattError)
        #expect(!bridge.teardownPending && recordingLink.cancelCount == 1)
        #expect(bridge.reconnectState == .suppressedByUser && clock.activeCount == 0)
        clock.advance(by: 60)
        #expect(bridge.scanStartCount == scansBeforeTeardownFail && !bridge.isScanRequested)
    }

    @Test("Explicit deviceDisconnect and disconnect() during waitingBackoff cancel retry timer and stay suppressed")
    func explicitDisconnectDuringWaitingBackoffSuppressesReconnect() {
        let peer = ReconnectTestPeer()
        let (store, bridge, central, clock, directory) = makeHarness(savedPeer: peer)
        defer {
            store.onSnapshotChanged = nil; bridge.shutdown(); store.shutdown()
            try? FileManager.default.removeItem(at: directory)
        }

        bridge.activateHost(allowsCoreBluetooth: true)
        bridge.centralStateDidChange(.poweredOn)
        markPeerReady(peer, on: bridge, central: central)

        bridge.didDisconnect(peer, on: central, error: nil)
        #expect(!bridge.isScanRequested && bridge.peripheral == nil)
        #expect(bridge.reconnectState == .waitingBackoff(attempt: 0, delaySeconds: 1))
        #expect(clock.activeCount == 1)

        store.send(.navigate(section: "records"))
        #expect(bridge.reconnectState == .waitingBackoff(attempt: 0, delaySeconds: 1))
        #expect(clock.activeCount == 1)

        let scansBeforeDisconnect = bridge.scanStartCount
        store.send(.deviceDisconnect)
        #expect(bridge.reconnectState == .suppressedByUser)
        #expect(clock.activeCount == 0)

        clock.advance(by: 120)
        bridge.handleHostWake()
        #expect(bridge.scanStartCount == scansBeforeDisconnect && !bridge.isScanRequested)

        bridge.requestScan()
        markPeerReady(peer, on: bridge, central: central)
        bridge.didDisconnect(peer, on: central, error: nil)
        #expect(bridge.reconnectState == .waitingBackoff(attempt: 0, delaySeconds: 1) && clock.activeCount == 1)

        let scansBeforeDirectDisconnect = bridge.scanStartCount
        bridge.disconnect()
        #expect(bridge.reconnectState == .suppressedByUser && clock.activeCount == 0)
        clock.advance(by: 120)
        #expect(bridge.scanStartCount == scansBeforeDirectDisconnect && !bridge.isScanRequested)
    }

    @Test("Non-user startScanningIfPoweredOn and reconnectKnownIfAvailable respect suppressedByUser")
    func nonUserScanAndReconnectKnownRespectSuppressedByUser() {
        let peer = ReconnectTestPeer()
        let (store, bridge, central, clock, directory) = makeHarness(savedPeer: peer)
        defer {
            store.onSnapshotChanged = nil; bridge.shutdown(); store.shutdown()
            try? FileManager.default.removeItem(at: directory)
        }

        bridge.activateHost(allowsCoreBluetooth: true)
        bridge.centralStateDidChange(.poweredOn)
        markPeerReady(peer, on: bridge, central: central)

        bridge.disconnect()
        #expect(bridge.reconnectState == .suppressedByUser)
        #expect(store.snapshot.device.autoConnect)
        let scansAfterDisconnect = bridge.scanStartCount

        bridge.reconnectKnownIfAvailable()
        #expect(bridge.reconnectState == .suppressedByUser)
        #expect(!bridge.isScanRequested && !central.isScanning)
        #expect(bridge.scanStartCount == scansAfterDisconnect)

        bridge.startScanningIfPoweredOn()
        #expect(bridge.reconnectState == .suppressedByUser)
        #expect(!bridge.isScanRequested && !central.isScanning)
        #expect(bridge.scanStartCount == scansAfterDisconnect)
        #expect(clock.activeCount == 0)

        bridge.requestScan()
        #expect(bridge.isScanRequested && bridge.scanStartCount == scansAfterDisconnect + 1)
    }

    @Test("Radio poweredOff to poweredOn during waitingBackoff resumes bounded scan with single timer arming")
    func radioPowerCycleDuringWaitingBackoffResumesBoundedScanWithoutDuplicateTimers() {
        let peer = ReconnectTestPeer()
        let (store, bridge, central, clock, directory) = makeHarness(savedPeer: peer)
        defer {
            store.onSnapshotChanged = nil; bridge.shutdown(); store.shutdown()
            try? FileManager.default.removeItem(at: directory)
        }

        bridge.activateHost(allowsCoreBluetooth: true)
        bridge.centralStateDidChange(.poweredOn)
        markPeerReady(peer, on: bridge, central: central)

        bridge.didDisconnect(peer, on: central, error: nil)
        #expect(!bridge.isScanRequested && bridge.reconnectState == .waitingBackoff(attempt: 0, delaySeconds: 1))
        #expect(clock.activeCount == 1)

        let scansBeforePowerOff = bridge.scanStartCount
        central.state = .poweredOff
        bridge.centralStateDidChange(.poweredOff)
        #expect(clock.activeCount == 0 && !bridge.isScanRequested && bridge.reconnectState == .idle)
        clock.advance(by: 30)
        #expect(bridge.scanStartCount == scansBeforePowerOff)

        let scheduledBeforePowerOn = clock.scheduleCount
        central.state = .poweredOn
        bridge.centralStateDidChange(.poweredOn)
        #expect(bridge.isScanRequested && central.isScanning)
        #expect(bridge.scanStartCount == scansBeforePowerOff + 1)
        #expect(clock.scheduleCount == scheduledBeforePowerOn + 1)
        #expect(clock.activeCount == 1)

        clock.advance(by: bridge.reconnectScanWindowSeconds)
        #expect(!bridge.isScanRequested && !central.isScanning)
        #expect(bridge.reconnectState == .waitingBackoff(attempt: 0, delaySeconds: 1))
        #expect(clock.activeCount == 1)

        let scheduledBeforeRetry = clock.scheduleCount
        clock.advance(by: 1)
        #expect(bridge.reconnectState == .scanning(windowAttempt: 1))
        #expect(clock.scheduleCount == scheduledBeforeRetry + 1)

        let scheduledBeforeWake = clock.scheduleCount
        bridge.handleHostWake()
        #expect(bridge.reconnectState == .scanning(windowAttempt: 0) && bridge.isScanRequested)
        #expect(clock.scheduleCount == scheduledBeforeWake + 1 && clock.activeCount == 1)
        clock.advance(by: bridge.reconnectScanWindowSeconds)
        #expect(!bridge.isScanRequested && bridge.reconnectState == .waitingBackoff(attempt: 0, delaySeconds: 1))
    }
}
