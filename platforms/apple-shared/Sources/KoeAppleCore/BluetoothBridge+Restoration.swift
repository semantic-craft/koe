@preconcurrency import CoreBluetooth
import Foundation

// Only the radio operations used by the bridge cross this boundary.
@MainActor
protocol BleCentral: AnyObject {
    var state: CBManagerState { get }
    var isScanning: Bool { get }
    var delegate: CBCentralManagerDelegate? { get set }
    func connectedPeripherals(withServices services: [CBUUID]) -> [any BlePeripheral]
    func knownPeripherals(withIdentifiers ids: [UUID]) -> [any BlePeripheral]
    func connectPeer(_ peer: any BlePeripheral)
    func cancelPeer(_ peer: any BlePeripheral)
    func scanForPeripherals(withServices services: [CBUUID]?, options: [String: Any]?)
    func stopScan()
}

@MainActor
protocol BlePeripheral: AnyObject {
    var identifier: UUID { get }
    var name: String? { get }
    var state: CBPeripheralState { get }
    var delegate: CBPeripheralDelegate? { get set }
    var services: [CBService]? { get }
    func discoverServices(_ serviceUUIDs: [CBUUID]?)
    func isNotifying(_ characteristic: CBCharacteristic) -> Bool
    func setNotifyValue(_ enabled: Bool, for characteristic: CBCharacteristic)
    var canSendWriteWithoutResponse: Bool { get }
    func maximumWriteValueLength(for type: CBCharacteristicWriteType) -> Int
    func writeValue(_ data: Data, for characteristic: CBCharacteristic, type: CBCharacteristicWriteType)
}

extension CBPeripheral: BlePeripheral {
    func isNotifying(_ characteristic: CBCharacteristic) -> Bool { characteristic.isNotifying }
}

extension CBCentralManager: BleCentral {
    func connectedPeripherals(withServices services: [CBUUID]) -> [any BlePeripheral] {
        retrieveConnectedPeripherals(withServices: services)
    }

    func knownPeripherals(withIdentifiers ids: [UUID]) -> [any BlePeripheral] {
        retrievePeripherals(withIdentifiers: ids)
    }

    func connectPeer(_ peer: any BlePeripheral) {
        guard let native = peer as? CBPeripheral else { preconditionFailure("Expected a CoreBluetooth peripheral") }
        connect(native, options: nil)
    }

    func cancelPeer(_ peer: any BlePeripheral) {
        guard let native = peer as? CBPeripheral else { preconditionFailure("Expected a CoreBluetooth peripheral") }
        cancelPeripheralConnection(native)
    }
}

extension BluetoothBridge {
    static let backgroundScanServiceUUIDs = [d3200ServiceUUID, CBUUID(string: "F5DA")]

    func beginDiscoveryAndReconnect(_ central: any BleCentral) {
        guard peripheral == nil, reconnectingPeripheral == nil, !central.isScanning else { return }
        let connectedPeripherals = central.connectedPeripherals(withServices: Self.backgroundScanServiceUUIDs)
        if let existing = connectedPeripherals.first {
            attachAndConnect(existing, on: central, displayName: existing.name ?? "soundcore Work")
            return
        }
        if let savedString = UserDefaults.standard.string(forKey: Self.savedPeripheralKey),
           let savedUUID = UUID(uuidString: savedString),
           let known = central.knownPeripherals(withIdentifiers: [savedUUID]).first
        {
            Self.logger.info("Reconnecting to saved D3200")
            reconnectingPeripheral = known
            known.delegate = self
            central.connectPeer(known)
        }
        Self.logger.info("Starting CoreBluetooth discovery")
        scan(central)
    }

    func scan(_ central: any BleCentral) {
        #if os(iOS)
        if sceneInBackground {
            central.scanForPeripherals(withServices: Self.backgroundScanServiceUUIDs, options: nil)
            return
        }
        #endif
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
    }
}

#if os(iOS)
extension BluetoothBridge {
    public static let iosRestoreIdentifier = "com.semanticcraft.koe.ios.central"

    func createIOSCentral() -> any BleCentral {
        makeIOSCentral(self, [CBCentralManagerOptionRestoreIdentifierKey: Self.iosRestoreIdentifier])
    }

    public func restoreCentralIfNeeded(restoreIdentifiers: [String]) {
        guard allowsCoreBluetooth, central == nil, restoreIdentifiers.contains(Self.iosRestoreIdentifier) else { return }
        central = createIOSCentral()
    }

    public func setSceneInBackground(_ isBackground: Bool) {
        guard sceneInBackground != isBackground else { return }
        sceneInBackground = isBackground
        guard pendingRestoration == nil, let central, central.state == .poweredOn, central.isScanning, peripheral == nil else { return }
        central.stopScan()
        scan(central)
    }

    nonisolated public func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        let peers = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] ?? []
        let services = dict[CBCentralManagerRestoredStateScanServicesKey] as? [CBUUID] ?? []
        onMainActorIsolated {
            guard self.central === central else { return }
            self.stageRestoration(peripherals: peers, scanServices: services)
        }
    }

    func stageRestoration(peripherals: [any BlePeripheral], scanServices: [CBUUID]) {
        peripherals.forEach { $0.delegate = self }
        pendingRestoration = (peripherals, scanServices)
    }

    func resumeRestoration(on central: any BleCentral) {
        guard let pending = pendingRestoration else { return }
        pendingRestoration = nil
        guard store?.runtimeDevice.autoConnect != false else {
            stopScanning()
            pending.peripherals.forEach(central.cancelPeer)
            isScanRequested = false
            return
        }

        // Koe owns a single transport. Prefer an established connection over an in-flight one.
        let peer = pending.peripherals.first { $0.state == .connected }
            ?? pending.peripherals.first { $0.state == .connecting }
        for other in pending.peripherals where other !== peer && other.state != .disconnected {
            central.cancelPeer(other)
        }
        if let peer {
            stopScanning()
            isScanRequested = false
            if peer.state == .connecting {
                reconnectingPeripheral = peer
                announceConnection(peer)
                return
            }
            peripheral = peer
            announceConnection(peer)
            restoreChannels(for: peer)
        } else if !pending.scanServices.isEmpty, peripheral == nil, reconnectingPeripheral == nil, !reportedReady {
            // An inherited scan may have been started with foreground parameters.
            stopScanning()
            isScanRequested = true
            connectionID = UUID().uuidString
            emit("scanning")
        }
    }

    private func restoreChannels(for peer: any BlePeripheral) {
        for service in peer.services ?? [] where Self.isPrimaryD3200Service(service.uuid) {
            let characteristics = service.characteristics ?? []
            guard let write = characteristics.first(where: Self.isWritableD3200Characteristic),
                  let notify = characteristics.first(where: { Self.isNotifyCharacteristic($0.uuid) }) else { continue }
            writeCharacteristic = write
            notifyFound = true
            notifyReady = peer.isNotifying(notify)
            if notifyReady { checkReady() }
            else { peer.setNotifyValue(true, for: notify) }
            return
        }
        peer.discoverServices(nil)
    }
}
#endif
