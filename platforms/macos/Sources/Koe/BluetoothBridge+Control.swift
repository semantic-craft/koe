import CoreBluetooth
import Foundation
import KoeAppleShared

extension BluetoothBridge {
    private func writeImmediateFrames(_ frames: [Data], on active: CBPeripheral?, via writeChar: CBCharacteristic?) {
        guard let active, active.state == .connected, let writeChar else { return }
        let mode: CBCharacteristicWriteType = writeChar.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
        let limit = max(active.maximumWriteValueLength(for: mode), 1)
        for data in frames {
            var offset = 0
            while offset < data.count {
                let end = min(offset + limit, data.count)
                active.writeValue(data.subdata(in: offset..<end), for: writeChar, type: mode)
                offset = end
            }
        }
    }

    private func writeProjectedTeardownStopFramesIfReady(for device: DeviceSnapshot) {
        let stopFrames = device.teardownStopFramesHex.compactMap(Self.decodeHex)
        if reportedReady && !stopFrames.isEmpty {
            lastTeardownStopFrames = stopFrames
            writeImmediateFrames(stopFrames, on: peripheral, via: writeCharacteristic)
        }
    }

    private func stopActiveStandbyBeforeTeardown() {
        guard let device = store?.snapshot.device, reportedReady || device.connected else { return }
        let fallback = device.teardownStopFramesHex.compactMap(Self.decodeHex)
        guard !fallback.isEmpty else { return }
        store?.send("device_stop")
        let drained = (store?.drainOutboundBleFramesHex() ?? []).compactMap(Self.decodeHex)
        let frames = drained.isEmpty ? fallback : drained
        lastTeardownStopFrames = frames
        writeImmediateFrames(frames, on: peripheral, via: writeCharacteristic)
    }

    public func releaseControl() {
        stopActiveStandbyBeforeTeardown()
        teardownLocalBleLink()
        UserDefaults.standard.removeObject(forKey: Self.savedPeripheralKey)
        lastObservedAutoConnect = false
        store?.send("device_release")
    }

    public func syncWithRuntimeDevice(_ device: DeviceSnapshot) {
        let wasAutoConnectDisabled = (lastObservedAutoConnect == false)
        lastObservedAutoConnect = device.autoConnect
        if !device.autoConnect {
            UserDefaults.standard.removeObject(forKey: Self.savedPeripheralKey)
            if reportedReady || isScanRequested || peripheral != nil || reconnectingPeripheral != nil {
                writeProjectedTeardownStopFramesIfReady(for: device)
                teardownLocalBleLink()
                if device.phase == "scanning" || device.phase == "connecting" {
                    store?.send("device_disconnect")
                }
            }
            return
        }
        if !device.connected && device.phase == "disconnected" {
            if reportedReady {
                writeProjectedTeardownStopFramesIfReady(for: device)
                teardownLocalBleLink()
                return
            }
            if isHostActivated && wasAutoConnectDisabled && !isScanRequested && peripheral == nil && reconnectingPeripheral == nil {
                Task { @MainActor [weak self] in
                    self?.startAutoConnectScanIfIdle()
                }
            }
        }
    }

    private func startAutoConnectScanIfIdle() {
        guard isHostActivated,
              let current = store?.snapshot.device,
              current.autoConnect,
              !current.connected,
              !reportedReady,
              !isScanRequested,
              peripheral == nil,
              reconnectingPeripheral == nil else { return }
        startScanningIfPoweredOn()
    }
}
