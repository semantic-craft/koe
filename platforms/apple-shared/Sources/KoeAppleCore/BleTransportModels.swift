import CoreBluetooth
import Foundation

public struct BleAdvertisementCandidate: Equatable, Sendable {
    public let displayName: String
    public let macAddress: String
    public let matchedByServiceUUID: Bool
    public let matchedByManufacturerData: Bool
    public let matchedByName: Bool

    public static func match(
        peripheralName: String?,
        advertisementData: [String: Any]
    ) -> BleAdvertisementCandidate? {
        var serviceUUIDStrings: [String] = []
        if let uuids = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] {
            serviceUUIDStrings.append(contentsOf: uuids.map { $0.uuidString.lowercased() })
        }
        if let overflow = advertisementData[CBAdvertisementDataOverflowServiceUUIDsKey] as? [CBUUID] {
            serviceUUIDStrings.append(contentsOf: overflow.map { $0.uuidString.lowercased() })
        }
        if let serviceData = advertisementData[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data] {
            serviceUUIDStrings.append(contentsOf: serviceData.keys.map { $0.uuidString.lowercased() })
        }
        let matchedByService = serviceUUIDStrings.contains { uuid in
            uuid.contains("020cf5da") || uuid.contains("daf50c02") || uuid.contains("f5da")
        }

        let advName = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? ""
        let rawName = (peripheralName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
            ? peripheralName!.trimmingCharacters(in: .whitespacesAndNewlines)
            : advName.trimmingCharacters(in: .whitespacesAndNewlines)
        let matchedByName = rawName.localizedCaseInsensitiveContains("soundcore")
            || rawName.localizedCaseInsensitiveContains("d3200")

        var matchedByMfg = false
        var macAddress = ""
        if let mfg = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data {
            let bytes = [UInt8](mfg)
            var macBase = 0
            if bytes.count >= 16 {
                let mark = String(decoding: bytes[10..<16], as: UTF8.self).lowercased()
                if mark.contains("sound") || mark.contains("scor") {
                    matchedByMfg = true
                    macBase = 2
                }
            }
            if !matchedByMfg && bytes.count >= 14 {
                let mark = String(decoding: bytes[8..<14], as: UTF8.self).lowercased()
                if mark.contains("sound") || mark.contains("scor") {
                    matchedByMfg = true
                    macBase = 0
                }
            }
            if !matchedByMfg && bytes.count >= 7 {
                for i in 0..<(bytes.count - 1) {
                    if (bytes[i] == 0xF5 && bytes[i + 1] == 0xDA)
                        || (bytes[i] == 0xDA && bytes[i + 1] == 0xF5)
                    {
                        matchedByMfg = true
                        break
                    }
                }
            }
            if bytes.count >= macBase + 6 && (matchedByMfg || matchedByService || matchedByName) {
                macAddress = formatMac(Array(bytes[macBase..<(macBase + 6)]))
            }
        }

        guard matchedByService || matchedByMfg || matchedByName else { return nil }

        let displayName = !rawName.isEmpty
            ? rawName
            : (macAddress.count >= 5 ? "soundcore Work (\(macAddress.suffix(5)))" : "soundcore Work")
        return BleAdvertisementCandidate(
            displayName: displayName, macAddress: macAddress,
            matchedByServiceUUID: matchedByService,
            matchedByManufacturerData: matchedByMfg, matchedByName: matchedByName
        )
    }

    private static func formatMac(_ bytes: [UInt8]) -> String {
        guard bytes.count >= 6 else { return "" }
        let first = bytes[0]
        if bytes[0..<6].allSatisfy({ $0 == first }) || bytes[0..<6].allSatisfy({ $0 == 0 }) { return "" }
        return bytes[0..<6].map { String(format: "%02X", $0) }.joined(separator: ":")
    }
}

public struct BleOutboundQueue: Sendable {
    public var spacingSeconds: TimeInterval
    public private(set) var pendingFrames: [Data] = []
    public private(set) var lastWriteDate: Date?

    public init(spacingSeconds: TimeInterval = 0.30) { self.spacingSeconds = spacingSeconds }
    public mutating func enqueue(_ frames: [Data]) { pendingFrames.append(contentsOf: frames) }

    public mutating func popReady(now: Date) -> Data? {
        guard !pendingFrames.isEmpty else { return nil }
        if let last = lastWriteDate, now.timeIntervalSince(last) + 1e-6 < spacingSeconds { return nil }
        lastWriteDate = now
        return pendingFrames.removeFirst()
    }

    public func delayUntilNextReady(now: Date) -> TimeInterval? {
        guard !pendingFrames.isEmpty else { return nil }
        guard let last = lastWriteDate else { return 0 }
        return max(0, spacingSeconds - now.timeIntervalSince(last))
    }

    mutating func discardPending() { pendingFrames.removeAll() }

    public mutating func reset() {
        pendingFrames.removeAll()
        lastWriteDate = nil
    }
}
