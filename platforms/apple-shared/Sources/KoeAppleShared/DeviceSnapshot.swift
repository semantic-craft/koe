import Foundation

public struct DeviceFileSnapshot: Codable, Equatable, Identifiable, Sendable {
    public let id: UInt32
    public let title: String
    public let durationMs: UInt64
    public var fileId: UInt32 { id }
}

public struct DeviceGuideSnapshot: Codable, Equatable, Sendable {
    public let mode: String
    public let step: Int
    public let totalSteps: Int
    public let title: String
    public let subtitle: String
    public let imageName: String
    public let highlightTarget: String
    public let primaryLabel: String
}

public struct DeviceSnapshot: Codable, Equatable, Sendable {
    public let phase: String
    public let state: String
    public let statusDetail: String
    public let connected: Bool
    public let busy: Bool
    public let recording: Bool
    public let stopping: Bool
    public let deviceName: String
    public let batteryPercent: Int?
    public let charging: Bool
    public let boxBatteryPercent: Int?
    public let boxCharging: Bool
    public let serialNumber: String
    public let firmwareVersion: String
    public let storageLabel: String
    public let files: [DeviceFileSnapshot]
    public let progress: Double
    public let guide: DeviceGuideSnapshot?
    public var transferPhase: String
    public var liveDurationMs: UInt64
    public var liveBytes: UInt64
    public var liveRecordId: String?

    private enum CodingKeys: String, CodingKey {
        case phase, state, statusDetail, connected, busy, recording, stopping, deviceName
        case batteryPercent, charging, boxBatteryPercent, boxCharging
        case serialNumber, firmwareVersion, storageLabel, files, progress, guide
        case transferPhase, liveDurationMs, liveBytes, liveRecordId
    }

    static let empty = DeviceSnapshot(
        phase: "disconnected",
        state: "未连接",
        statusDetail: "将麦克风放入充电仓，短按下方按钮开启广播",
        connected: false,
        busy: false,
        recording: false,
        stopping: false,
        deviceName: "Soundcore Work",
        batteryPercent: nil,
        charging: false,
        boxBatteryPercent: nil,
        boxCharging: false,
        serialNumber: "",
        firmwareVersion: "",
        storageLabel: "—",
        files: [],
        progress: 0,
        guide: nil,
        transferPhase: "idle",
        liveDurationMs: 0,
        liveBytes: 0,
        liveRecordId: nil
    )
}

extension DeviceSnapshot {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let connected = try c.decode(Bool.self, forKey: .connected)
        phase = try c.decodeIfPresent(String.self, forKey: .phase) ?? (connected ? "connected" : "disconnected")
        state = try c.decode(String.self, forKey: .state)
        statusDetail = try c.decodeIfPresent(String.self, forKey: .statusDetail)
            ?? (connected ? "已就绪" : "将麦克风放入充电仓，短按下方按钮开启广播")
        self.connected = connected
        busy = try c.decode(Bool.self, forKey: .busy)
        recording = try c.decodeIfPresent(Bool.self, forKey: .recording) ?? false
        stopping = try c.decodeIfPresent(Bool.self, forKey: .stopping) ?? false
        deviceName = try c.decodeIfPresent(String.self, forKey: .deviceName) ?? "Soundcore Work"
        batteryPercent = try c.decodeIfPresent(Int.self, forKey: .batteryPercent)
        charging = try c.decodeIfPresent(Bool.self, forKey: .charging) ?? false
        boxBatteryPercent = try c.decodeIfPresent(Int.self, forKey: .boxBatteryPercent)
        boxCharging = try c.decodeIfPresent(Bool.self, forKey: .boxCharging) ?? false
        serialNumber = try c.decodeIfPresent(String.self, forKey: .serialNumber) ?? ""
        firmwareVersion = try c.decodeIfPresent(String.self, forKey: .firmwareVersion) ?? ""
        storageLabel = try c.decodeIfPresent(String.self, forKey: .storageLabel) ?? "—"
        files = try c.decodeIfPresent([DeviceFileSnapshot].self, forKey: .files) ?? []
        progress = try c.decodeIfPresent(Double.self, forKey: .progress) ?? 0.0
        guide = try c.decodeIfPresent(DeviceGuideSnapshot.self, forKey: .guide)
        transferPhase = try c.decodeIfPresent(String.self, forKey: .transferPhase) ?? "idle"
        liveDurationMs = try c.decodeIfPresent(UInt64.self, forKey: .liveDurationMs) ?? 0
        liveBytes = try c.decodeIfPresent(UInt64.self, forKey: .liveBytes) ?? 0
        liveRecordId = try c.decodeIfPresent(String.self, forKey: .liveRecordId)
    }
}
