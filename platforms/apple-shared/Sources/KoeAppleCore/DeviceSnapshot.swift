import Foundation

public struct DeviceFileSnapshot: Codable, Equatable, Identifiable, Sendable {
    public let id: UInt32
    public let title: String
    public let durationMs: UInt64
    public var synced: Bool = false
    public var downloading: Bool = false
    public var recordId: String?
    public var fileId: UInt32 { id }

    private enum CodingKeys: String, CodingKey {
        case id, title, durationMs, synced, downloading, recordId
    }

    public init(
        id: UInt32,
        title: String,
        durationMs: UInt64,
        synced: Bool = false,
        downloading: Bool = false,
        recordId: String? = nil
    ) {
        self.id = id
        self.title = title
        self.durationMs = durationMs
        self.synced = synced
        self.downloading = downloading
        self.recordId = recordId
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UInt32.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        durationMs = try c.decode(UInt64.self, forKey: .durationMs)
        synced = try c.decodeIfPresent(Bool.self, forKey: .synced) ?? false
        downloading = try c.decodeIfPresent(Bool.self, forKey: .downloading) ?? false
        recordId = try c.decodeIfPresent(String.self, forKey: .recordId)
    }
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
    public let storageUsedRatio: Double?
    public let files: [DeviceFileSnapshot]
    public let progress: Double
    public let guide: DeviceGuideSnapshot?
    public var transferPhase: String
    public let transferErrorCode: UInt8?
    public let audioDecryptReady: Bool
    public var liveDurationMs: UInt64
    public var liveBytes: UInt64
    public var liveRecordId: String?
    public let autoConnect: Bool
    public let teardownStopFramesHex: [String]

    private enum CodingKeys: String, CodingKey {
        case phase, state, statusDetail, connected, busy, recording, stopping, deviceName
        case batteryPercent, charging, boxBatteryPercent, boxCharging
        case serialNumber, firmwareVersion, storageLabel, storageUsedRatio, files, progress, guide
        case transferPhase, transferErrorCode, audioDecryptReady, liveDurationMs, liveBytes, liveRecordId
        case autoConnect, teardownStopFramesHex
    }

    public init(
        phase: String,
        state: String,
        statusDetail: String,
        connected: Bool,
        busy: Bool,
        recording: Bool,
        stopping: Bool,
        deviceName: String,
        batteryPercent: Int?,
        charging: Bool,
        boxBatteryPercent: Int?,
        boxCharging: Bool,
        serialNumber: String,
        firmwareVersion: String,
        storageLabel: String,
        storageUsedRatio: Double?,
        files: [DeviceFileSnapshot],
        progress: Double,
        guide: DeviceGuideSnapshot?,
        transferPhase: String,
        transferErrorCode: UInt8? = nil,
        audioDecryptReady: Bool = false,
        liveDurationMs: UInt64,
        liveBytes: UInt64,
        liveRecordId: String?,
        autoConnect: Bool,
        teardownStopFramesHex: [String]
    ) {
        self.phase = phase
        self.state = state
        self.statusDetail = statusDetail
        self.connected = connected
        self.busy = busy
        self.recording = recording
        self.stopping = stopping
        self.deviceName = deviceName
        self.batteryPercent = batteryPercent
        self.charging = charging
        self.boxBatteryPercent = boxBatteryPercent
        self.boxCharging = boxCharging
        self.serialNumber = serialNumber
        self.firmwareVersion = firmwareVersion
        self.storageLabel = storageLabel
        self.storageUsedRatio = storageUsedRatio
        self.files = files
        self.progress = progress
        self.guide = guide
        self.transferPhase = transferPhase
        self.transferErrorCode = transferErrorCode
        self.audioDecryptReady = audioDecryptReady
        self.liveDurationMs = liveDurationMs
        self.liveBytes = liveBytes
        self.liveRecordId = liveRecordId
        self.autoConnect = autoConnect
        self.teardownStopFramesHex = teardownStopFramesHex
    }

    public static let empty = DeviceSnapshot(
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
        storageUsedRatio: nil,
        files: [],
        progress: 0,
        guide: nil,
        transferPhase: "idle",
        transferErrorCode: nil,
        audioDecryptReady: false,
        liveDurationMs: 0,
        liveBytes: 0,
        liveRecordId: nil,
        autoConnect: true,
        teardownStopFramesHex: []
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
        storageUsedRatio = try c.decodeIfPresent(Double.self, forKey: .storageUsedRatio)
        files = try c.decodeIfPresent([DeviceFileSnapshot].self, forKey: .files) ?? []
        progress = try c.decodeIfPresent(Double.self, forKey: .progress) ?? 0.0
        guide = try c.decodeIfPresent(DeviceGuideSnapshot.self, forKey: .guide)
        transferPhase = try c.decodeIfPresent(String.self, forKey: .transferPhase) ?? "idle"
        transferErrorCode = try c.decodeIfPresent(UInt8.self, forKey: .transferErrorCode)
        audioDecryptReady = try c.decodeIfPresent(Bool.self, forKey: .audioDecryptReady) ?? false
        liveDurationMs = try c.decodeIfPresent(UInt64.self, forKey: .liveDurationMs) ?? 0
        liveBytes = try c.decodeIfPresent(UInt64.self, forKey: .liveBytes) ?? 0
        liveRecordId = try c.decodeIfPresent(String.self, forKey: .liveRecordId)
        autoConnect = try c.decodeIfPresent(Bool.self, forKey: .autoConnect) ?? true
        teardownStopFramesHex = try c.decodeIfPresent([String].self, forKey: .teardownStopFramesHex) ?? []
    }
}
