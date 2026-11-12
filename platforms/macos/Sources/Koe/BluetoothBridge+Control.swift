import CoreBluetooth
import Foundation
import KoeAppleShared

extension BluetoothBridge {
    nonisolated public static let pauseRecordFrame = Data([
        0x08, 0xEE, 0x00, 0x00, 0x00, 0x18, 0x82, 0x0B, 0x00, 0x02, 0x9D
    ])

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

    private func stopActiveStandbyBeforeTeardown() {
        guard let device = store?.snapshot.device,
              device.standbyReady || device.recording || (device.connected && device.companionMode == "collar_standby") else {
            return
        }
        store?.send("device_stop")
        let drained = (store?.drainOutboundBleFramesHex() ?? []).compactMap(Self.decodeHex)
        let frames = drained.isEmpty ? [Self.pauseRecordFrame] : drained
        lastTeardownStopFrames = frames
        writeImmediateFrames(frames, on: peripheral, via: writeCharacteristic)
    }

    public func releaseControl() {
        stopActiveStandbyBeforeTeardown()
        central?.stopScan()
        if let active = peripheral {
            central?.cancelPeripheralConnection(active)
        }
        if let pending = reconnectingPeripheral {
            central?.cancelPeripheralConnection(pending)
            reconnectingPeripheral = nil
        }
        UserDefaults.standard.removeObject(forKey: Self.savedPeripheralKey)
        resetLinkState()
        isScanRequested = false
        store?.send("device_release")
    }

    public func syncWithRuntimeDevice(_ device: DeviceSnapshot) {
        if !device.autoConnect {
            UserDefaults.standard.removeObject(forKey: Self.savedPeripheralKey)
        }
        guard !device.connected && device.phase == "disconnected" else {
            return
        }
        if reportedReady || (!device.autoConnect && (isScanRequested || peripheral != nil || reconnectingPeripheral != nil)) {
            if reportedReady, device.companionMode == "collar_standby" {
                lastTeardownStopFrames = [Self.pauseRecordFrame]
                writeImmediateFrames([Self.pauseRecordFrame], on: peripheral, via: writeCharacteristic)
            }
            central?.stopScan()
            if let active = peripheral {
                central?.cancelPeripheralConnection(active)
            }
            if let pending = reconnectingPeripheral {
                central?.cancelPeripheralConnection(pending)
                reconnectingPeripheral = nil
            }
            resetLinkState()
            isScanRequested = false
        }
    }
}
