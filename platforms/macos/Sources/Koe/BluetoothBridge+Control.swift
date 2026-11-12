import CoreBluetooth
import Foundation
import KoeAppleShared

extension BluetoothBridge {
    public func releaseControl() {
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
        guard !device.autoConnect && !device.connected && device.phase == "disconnected" else {
            return
        }
        UserDefaults.standard.removeObject(forKey: Self.savedPeripheralKey)
        if isScanRequested || peripheral != nil || reconnectingPeripheral != nil || reportedReady {
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
