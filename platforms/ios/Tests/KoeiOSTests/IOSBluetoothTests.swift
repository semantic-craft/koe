import CoreBluetooth
import CryptoKit
@testable import KoeAppleCore
import XCTest
@testable import KoeiOSApp

@MainActor
final class IOSBluetoothTests: XCTestCase {
    private let pause = Data([0x08, 0xEE, 0, 0, 0, 0x18, 0x82, 0x0B, 0, 2, 0x9D])

    private func withHost(_ body: (HostSessionStore, IOSHostCoordinator) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        let session = IOSLaunchSession(bridgeActions: HostBridgeActions(), arguments: ["Koe", "-koe-workspace", root.path],
                                       environment: [:], source: TestMicrophone(), allowsCoreBluetooth: false)
        defer { session.shutdown() }
        try await body(session.store, session.coordinator)
    }

    func testScanFromReleasedDeviceRestoresAutoConnectWithoutOpeningGuide() async throws {
        try await withHost { store, _ in
            store.send(.deviceRelease)
            XCTAssertFalse(store.snapshot.device.autoConnect)
            store.bridgeActions.requestBleScan()
            XCTAssertTrue(store.snapshot.device.autoConnect)
            XCTAssertEqual(store.snapshot.device.phase, "scanning")
            XCTAssertNil(store.snapshot.device.guide)
        }
    }

    func testUnavailableRadioEndsScanAndReportsErrorOnEveryRetry() async throws {
        let unavailable: [(CBManagerState, String)] = [(.poweredOff, "关闭"), (.unauthorized, "允许"), (.unsupported, "不支持")]
        for (state, message) in unavailable {
            try await withHost { store, host in
                XCTAssertEqual(store.snapshot.device.phase, "scanning")
                host.bluetoothBridge.centralStateDidChange(state)
                XCTAssertEqual(store.snapshot.device.phase, "disconnected")
                XCTAssertTrue(store.nativeError?.contains(message) == true)

                store.clearError()
                store.bridgeActions.requestBleScan()
                XCTAssertEqual(store.snapshot.device.phase, "disconnected", "retry with known state \(state)")
                XCTAssertTrue(store.nativeError?.contains(message) == true)
                host.bluetoothBridge.centralStateDidChange(.poweredOn)
                store.bridgeActions.requestBleScan()
                XCTAssertEqual(store.snapshot.device.phase, "scanning")
            }
        }
    }

    func testDeviceSheetScanEntryAndGuideUseLiveDeviceState() async throws {
        try await withHost { store, _ in
            let sheet = IOSDeviceSheetView(store: store)
            store.send(.deviceDisconnect)
            let scan = try XCTUnwrap(sheet.disconnectedScanButton)
            XCTAssertEqual(scan.title, "扫描录音豆")
            scan.action()
            XCTAssertEqual(store.snapshot.device.phase, "scanning")
            XCTAssertNil(store.snapshot.device.guide)

            store.send(.deviceRelease)
            XCTAssertNil(sheet.disconnectedScanButton)
            store.send(.deviceOpenGuide)
            let guide = try XCTUnwrap(store.snapshot.device.guide)
            XCTAssertEqual(guide.mode, "connect_guide")
            let connect = try XCTUnwrap(sheet.guidePrimaryButton(guide))
            XCTAssertEqual(connect.title, guide.primaryLabel)
            connect.action()
            XCTAssertEqual(store.snapshot.device.phase, "scanning")
            XCTAssertEqual(store.snapshot.device.guide?.mode, "connect_guide")

            try connectBean(to: store)
            XCTAssertNil(sheet.disconnectedScanButton)
            let onboarding = try XCTUnwrap(store.snapshot.device.guide)
            XCTAssertEqual(onboarding.mode, "onboarding")
            try XCTUnwrap(sheet.guidePrimaryButton(onboarding)).action()
            XCTAssertEqual(store.snapshot.device.guide?.step, onboarding.step + 1)
            XCTAssertTrue(store.snapshot.device.connected)
        }
    }

    func testD3200AdvertisementsAndPrimaryServiceChannels() throws {
        let fullService = CBUUID(string: "020CF5DA-0000-1000-8000-00805F9B34FB")
        let shortService = CBUUID(string: "F5DA")
        let otherService = CBUUID(string: "180F")
        let write = CBUUID(string: "7777"), notify = CBUUID(string: "8888")
        for service in [fullService, shortService] {
            let match = BleAdvertisementCandidate.match(peripheralName: nil, advertisementData: [CBAdvertisementDataServiceUUIDsKey: [service]])
            XCTAssertTrue(try XCTUnwrap(match).matchedByServiceUUID)
            XCTAssertTrue(BluetoothBridge.isD3200WriteCharacteristic(write, serviceUUID: service))
            XCTAssertTrue(BluetoothBridge.isD3200NotifyCharacteristic(notify, serviceUUID: service))
            XCTAssertFalse(BluetoothBridge.isD3200NotifyCharacteristic(write, serviceUUID: service))
            XCTAssertFalse(BluetoothBridge.isD3200WriteCharacteristic(notify, serviceUUID: service))
        }
        XCTAssertFalse(BluetoothBridge.isD3200NotifyCharacteristic(notify, serviceUUID: otherService))
        XCTAssertFalse(BluetoothBridge.isD3200WriteCharacteristic(write, serviceUUID: otherService))
        XCTAssertNil(BleAdvertisementCandidate.match(peripheralName: "speaker", advertisementData: [CBAdvertisementDataServiceUUIDsKey: [otherService]]))
        let manufacturer = Data([0x32, 0, 1, 2, 3, 4, 5, 6, 0, 0]) + Data("soundc".utf8)
        let match = try XCTUnwrap(BleAdvertisementCandidate.match(peripheralName: nil, advertisementData: [CBAdvertisementDataManufacturerDataKey: manufacturer]))
        XCTAssertTrue(match.matchedByManufacturerData)
        XCTAssertEqual(match.macAddress, "01:02:03:04:05:06")
    }

    func testReleaseAndDisablingAutoConnectSendLastProjectedStopBeforeCancel() async throws {
        for command in [HostCommand.deviceRelease, .setBleAutoConnect(enabled: false)] {
            try await withHost { store, host in
                let link = try recordingLink(store, host)
                store.send(command)
                XCTAssertTrue(store.snapshot.device.recording)
                XCTAssertTrue(store.snapshot.device.autoConnect)
                XCTAssertNotNil(store.snapshot.error)
                XCTAssertEqual(link.events, [])

                // Rust can handle multiple device events before the host reads its next generation.
                let publish = store.onSnapshotChanged
                store.onSnapshotChanged = nil
                store.ingestBleChunk(rx(0x18, 0x82, [2]))
                store.pollTimers(elapsedMs: 2_100)
                store.onSnapshotChanged = publish
                XCTAssertFalse(store.snapshot.device.recording)
                store.send(command)
                XCTAssertFalse(store.snapshot.device.autoConnect)
                XCTAssertEqual(link.events, [.write(pause, .withResponse)])
                host.bluetoothBridge.writeDidComplete(error: nil)
                XCTAssertEqual(link.events, [.write(pause, .withResponse), .cancel])
                XCTAssertEqual(host.bluetoothBridge.lastTeardownStopFrames, [pause])
                XCTAssertEqual(store.snapshot.device.phase, "disconnected")
            }
        }
    }

    func testAcknowledgedDeviceStopClearsProjectionBeforeRelease() async throws {
        try await withHost { store, host in
            let link = try recordingLink(store, host)
            store.ingestBleChunk(rx(0x18, 0x82, [2]))
            store.pollTimers(elapsedMs: 2_100)
            store.send(.deviceRelease)
            XCTAssertFalse(store.snapshot.device.autoConnect)
            XCTAssertFalse(link.events.contains(.write(pause, .withResponse)))
            XCTAssertEqual(link.events.last, .cancel)
        }
    }

    func testShutdownWaitsForOutstandingWriteAndThenStopAcknowledgement() async throws {
        try await withHost { store, host in
            let link = try recordingLink(store, host)
            store.send(.deviceRefresh)
            store.bridgeActions.flushBleOutbound()
            let first = try XCTUnwrap(link.events.first)
            XCTAssertNotEqual(first, .write(pause, .withResponse))
            host.shutdown()
            XCTAssertEqual(link.events, [first], "An outstanding regular write still owns the next ACK")
            host.bluetoothBridge.writeDidComplete(error: nil)
            try await waitForLinkEvent { link.events.contains(.write(self.pause, .withResponse)) }
            XCTAssertEqual(link.events, [first, .write(pause, .withResponse)])
            host.bluetoothBridge.writeDidComplete(error: nil)
            XCTAssertEqual(link.events, [first, .write(pause, .withResponse), .cancel])
            XCTAssertEqual(host.bluetoothBridge.lastTeardownStopFrames, [pause])
        }
    }

    func testRuntimeDisconnectWaitsForWithoutResponseCapacity() async throws {
        try await withHost { store, host in
            let link = try recordingLink(store, host)
            link.supportsWriteResponse = false
            link.supportsWriteWithoutResponse = true
            link.canSendWriteWithoutResponse = false
            store.send(.deviceDisconnect)
            XCTAssertEqual(link.events, [])
            store.bridgeActions.requestBleScan()
            XCTAssertEqual(store.snapshot.device.phase, "disconnected")
            link.canSendWriteWithoutResponse = true
            host.bluetoothBridge.pumpOutboundQueue()
            XCTAssertEqual(link.events, [.write(pause, .withoutResponse)])
            link.canSendWriteWithoutResponse = false
            try await waitForLinkEvent { link.events.last == .cancel && store.snapshot.device.phase == "scanning" }
            XCTAssertEqual(link.events, [.write(pause, .withoutResponse), .cancel])
            XCTAssertEqual(store.snapshot.device.phase, "scanning")
            XCTAssertEqual(host.bluetoothBridge.lastTeardownStopFrames, [pause])
        }
    }

    func testFailedStopAcknowledgementReleasesLinkAndReportsWriteError() async throws {
        try await withHost { store, host in
            let link = try recordingLink(store, host)
            store.send(.deviceDisconnect)
            XCTAssertEqual(link.events, [.write(pause, .withResponse)])
            host.bluetoothBridge.writeDidComplete(error: NSError(domain: "GATT", code: 1))
            XCTAssertEqual(link.events, [.write(pause, .withResponse), .cancel])
            XCTAssertTrue(store.nativeError?.contains("发送失败") == true)
            XCTAssertEqual(store.snapshot.device.phase, "disconnected")
        }
    }

    private func waitForLinkEvent(_ observed: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while !observed(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(observed(), file: file, line: line)
    }

    private func recordingLink(_ store: HostSessionStore, _ host: IOSHostCoordinator) throws -> RecordingLink {
        try connectBean(to: store)
        host.bluetoothBridge.reportedReady = true
        store.ingestBleChunk(rx(0x18, 0x81, [0x93, 3, 0, 0]))
        XCTAssertTrue(store.snapshot.device.recording)
        XCTAssertEqual(store.snapshot.device.teardownStopFramesHex, ["08EE00000018820B00029D"])
        _ = store.drainOutboundBleFrames()
        let link = RecordingLink()
        host.bluetoothBridge.writeLink = link
        return link
    }

    private func connectBean(to store: HostSessionStore) throws {
        store.send(.deviceEvent(event: "connecting", connectionId: "bean", deviceName: "soundcore Work"))
        store.send(.deviceEvent(event: "ready", connectionId: "bean"))
        let exchange = try XCTUnwrap(store.drainOutboundBleFrames().first { $0.count >= 75 && $0[5] == 0x2E && $0[6] == 1 })
        let hostKey = try P256.KeyAgreement.PublicKey(x963Representation: exchange[9..<74])
        let bean = P256.KeyAgreement.PrivateKey()
        let secret = try bean.sharedSecretFromKeyAgreement(with: hostKey)
        let reply = bean.publicKey.x963Representation + secret.withUnsafeBytes { Data($0) }
        var telemetry = [UInt8](repeating: 0, count: 40)
        telemetry[1] = 8
        store.ingestBleChunk(rx(0x01, 0x01, telemetry))
        store.ingestBleChunk(rx(0x2E, 0x01, Array(reply)))
        XCTAssertTrue(store.snapshot.device.connected)
        _ = store.drainOutboundBleFrames()
    }

    private func rx(_ group: UInt8, _ command: UInt8, _ payload: [UInt8]) -> Data {
        var bytes: [UInt8] = [9, 0xFF, 0, 0, 1, group, command, UInt8(payload.count + 10), 0]
        bytes.append(contentsOf: payload)
        bytes.append(bytes.reduce(0, &+))
        return Data(bytes)
    }
}

@MainActor
private final class RecordingLink: BleWriteLink {
    enum Event: Equatable {
        case write(Data, CBCharacteristicWriteType)
        case cancel
    }
    var supportsWriteResponse = true
    var supportsWriteWithoutResponse = false
    var canSendWriteWithoutResponse = true
    var events: [Event] = []

    func maximumWriteValueLength(for type: CBCharacteristicWriteType) -> Int { 128 }
    func write(_ data: Data, type: CBCharacteristicWriteType) { events.append(.write(data, type)) }
    func cancel() { events.append(.cancel) }
}
