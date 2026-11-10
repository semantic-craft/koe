import Foundation

public struct SourceSnapshot: Codable, Equatable, Identifiable, Sendable {
    public var id: String { "\(recordId):\(segmentId)" }
    public let recordId: String
    public let segmentId: String
    public let title: String
    public let quote: String
    public let startMs: UInt64
}

public struct SegmentSnapshot: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let text: String
    public let startMs: UInt64
    public let endMs: UInt64
    public var timed: Bool? = nil
    public let speaker: String?
}

public typealias KoeColors = AppColors

public struct RecordSnapshot: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let createdAtEpochSec: UInt64
    public let durationMs: UInt64
    public let source: String
    public let status: String
    public let segmentCount: Int
    public let preview: String
    public var isTranscribing: Bool { status == "转写中" || status == "等待转写" }
    public var audioFile: String? { nil }
}

public struct SummarySnapshot: Codable, Equatable, Sendable {
    public let title: String
    public let text: String
    public let sources: [SourceSnapshot]
}

public struct RecordDetailSnapshot: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let createdAtEpochSec: UInt64
    public let durationMs: UInt64
    public let source: String
    public let status: String
    public let segments: [SegmentSnapshot]
    public let summary: [SummarySnapshot]
    public let highlights: [SourceSnapshot]
    public let audioPath: String?
    public let canRetranscribe: Bool
    public let isProcessing: Bool
}

public struct TaskSnapshot: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let text: String
    public let state: String
    public let completed: Bool
    public let due: String?
    public let sources: [SourceSnapshot]
}

public struct MemorySnapshot: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let text: String
    public let state: String
    public let sources: [SourceSnapshot]
}

public struct AskMessageSnapshot: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let role: String
    public let text: String
    public let mode: String
    public let sources: [SourceSnapshot]
}

public struct AskSnapshot: Codable, Equatable, Sendable {
    public let scope: String
    public let recordId: String?
    public let phase: String
    public let messages: [AskMessageSnapshot]
}

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

    public init(
        mode: String, step: Int, totalSteps: Int, title: String, subtitle: String,
        imageName: String, highlightTarget: String, primaryLabel: String
    ) {
        self.mode = mode
        self.step = step
        self.totalSteps = totalSteps
        self.title = title
        self.subtitle = subtitle
        self.imageName = imageName
        self.highlightTarget = highlightTarget
        self.primaryLabel = primaryLabel
    }
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

    public init(
        phase: String = "disconnected",
        state: String,
        statusDetail: String = "将麦克风放入充电仓，短按下方按钮开启广播",
        connected: Bool,
        busy: Bool,
        recording: Bool = false,
        stopping: Bool = false,
        deviceName: String = "Soundcore Work",
        batteryPercent: Int? = nil,
        charging: Bool = false,
        boxBatteryPercent: Int? = nil,
        boxCharging: Bool = false,
        serialNumber: String = "",
        firmwareVersion: String = "",
        storageLabel: String = "—",
        files: [DeviceFileSnapshot],
        progress: Double,
        guide: DeviceGuideSnapshot? = nil,
        transferPhase: String = "idle",
        liveDurationMs: UInt64 = 0,
        liveBytes: UInt64 = 0,
        liveRecordId: String? = nil
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
        self.files = files
        self.progress = progress
        self.guide = guide
        self.transferPhase = transferPhase
        self.liveDurationMs = liveDurationMs
        self.liveBytes = liveBytes
        self.liveRecordId = liveRecordId
    }

    private enum CodingKeys: String, CodingKey {
        case phase, state, statusDetail, connected, busy, recording, stopping, deviceName
        case batteryPercent, charging, boxBatteryPercent, boxCharging
        case serialNumber, firmwareVersion, storageLabel, files, progress, guide
        case transferPhase, liveDurationMs, liveBytes, liveRecordId
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let connected = try c.decode(Bool.self, forKey: .connected)
        self.phase = try c.decodeIfPresent(String.self, forKey: .phase) ?? (connected ? "connected" : "disconnected")
        self.state = try c.decode(String.self, forKey: .state)
        self.statusDetail = try c.decodeIfPresent(String.self, forKey: .statusDetail)
            ?? (connected ? "已就绪" : "将麦克风放入充电仓，短按下方按钮开启广播")
        self.connected = connected
        self.busy = try c.decode(Bool.self, forKey: .busy)
        self.recording = try c.decodeIfPresent(Bool.self, forKey: .recording) ?? false
        self.stopping = try c.decodeIfPresent(Bool.self, forKey: .stopping) ?? false
        self.deviceName = try c.decodeIfPresent(String.self, forKey: .deviceName) ?? "Soundcore Work"
        self.batteryPercent = try c.decodeIfPresent(Int.self, forKey: .batteryPercent)
        self.charging = try c.decodeIfPresent(Bool.self, forKey: .charging) ?? false
        self.boxBatteryPercent = try c.decodeIfPresent(Int.self, forKey: .boxBatteryPercent)
        self.boxCharging = try c.decodeIfPresent(Bool.self, forKey: .boxCharging) ?? false
        self.serialNumber = try c.decodeIfPresent(String.self, forKey: .serialNumber) ?? ""
        self.firmwareVersion = try c.decodeIfPresent(String.self, forKey: .firmwareVersion) ?? ""
        self.storageLabel = try c.decodeIfPresent(String.self, forKey: .storageLabel) ?? "—"
        self.files = try c.decodeIfPresent([DeviceFileSnapshot].self, forKey: .files) ?? []
        self.progress = try c.decodeIfPresent(Double.self, forKey: .progress) ?? 0.0
        self.guide = try c.decodeIfPresent(DeviceGuideSnapshot.self, forKey: .guide)
        self.transferPhase = try c.decodeIfPresent(String.self, forKey: .transferPhase) ?? "idle"
        self.liveDurationMs = try c.decodeIfPresent(UInt64.self, forKey: .liveDurationMs) ?? 0
        self.liveBytes = try c.decodeIfPresent(UInt64.self, forKey: .liveBytes) ?? 0
        self.liveRecordId = try c.decodeIfPresent(String.self, forKey: .liveRecordId)
    }
}

public struct ProviderSnapshot: Codable, Equatable, Sendable {
    public let meetingAudioPolicy: String
    public let meetingAudioStatus: String?
    public let meetingAudioPolicyError: String?
    public let configured: Bool
    public let model: String
    public let asrEndpoint: String
    public let chatEndpoint: String
    public let credentialState: String
    public let isolated: Bool

    init(configured: Bool, model: String) {
        meetingAudioPolicy = "local_only"
        meetingAudioStatus = nil
        meetingAudioPolicyError = nil
        self.configured = configured
        self.model = model
        asrEndpoint = ""
        chatEndpoint = ""
        credentialState = configured ? "ready" : "missing"
        isolated = true
    }

    private enum CodingKeys: String, CodingKey {
        case configured, model, asrEndpoint, chatEndpoint, credentialState, isolated, meetingAudioPolicy, meetingAudioStatus, meetingAudioPolicyError
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        meetingAudioPolicy = try values.decodeIfPresent(String.self, forKey: .meetingAudioPolicy) ?? "local_only"
        meetingAudioStatus = try values.decodeIfPresent(String.self, forKey: .meetingAudioStatus)
        meetingAudioPolicyError = try values.decodeIfPresent(String.self, forKey: .meetingAudioPolicyError)
        configured = try values.decode(Bool.self, forKey: .configured)
        model = try values.decode(String.self, forKey: .model)
        asrEndpoint = try values.decodeIfPresent(String.self, forKey: .asrEndpoint) ?? ""
        chatEndpoint = try values.decodeIfPresent(String.self, forKey: .chatEndpoint) ?? ""
        credentialState = try values.decodeIfPresent(String.self, forKey: .credentialState) ?? (configured ? "ready" : "missing")
        isolated = try values.decodeIfPresent(Bool.self, forKey: .isolated) ?? true
    }
}

public struct MigrationReportSnapshot: Codable, Equatable, Sendable, Identifiable {
    public var id: String { fingerprint }
    public let fingerprint: String
    public let archivePath: String
    public let recordCount: Int
    public let pending: [String]
}

public struct LifecycleSnapshot: Codable, Equatable, Sendable {
    public let keepAwake: Bool
    public let quitPhase: String
    public let message: String?

    public init(keepAwake: Bool, quitPhase: String, message: String? = nil) {
        self.keepAwake = keepAwake
        self.quitPhase = quitPhase
        self.message = message
    }
}

public struct CaptureLaneSnapshot: Codable, Equatable, Sendable {
    public let nextSequence: UInt64
    public let sampleRate: UInt32?
    public let started: Bool
    public let stopped: Bool
    public let error: String?
    public let interruption: String?
}

public struct MicrophoneSnapshot: Codable, Equatable, Sendable {
    public let recordId: String
    public let sessionId: String
    public let lane: String
    public let inputId: String
    public let phase: String
    public let nextSequence: UInt64
    public let durationMs: UInt64
    public let error: String?
    public let interruption: String?
    public let epoch: UInt64
    public let clockNs: UInt64?
    public let lanes: [String: CaptureLaneSnapshot]


}

public struct HostSnapshot: Codable, Equatable, Sendable {
    public var microphone: MicrophoneSnapshot? = nil
    public var lifecycle: LifecycleSnapshot? = nil
    public let version: UInt32
    public let generation: UInt64
    public let section: String
    public let canGoBack: Bool
    public let selectedRecordId: String?
    public let focusSegmentId: String?
    public let records: [RecordSnapshot]
    public let todayRecordIds: [String]
    public let detail: RecordDetailSnapshot?
    public let tasks: [TaskSnapshot]
    public let memories: [MemorySnapshot]
    public let ask: AskSnapshot
    public let device: DeviceSnapshot
    public let provider: ProviderSnapshot
    public let playback: PlaybackSnapshot
    public let error: String?
    public var migrationReports: [MigrationReportSnapshot]? = nil
    public let notice: String?

    public var activeLiveRecord: RecordSnapshot? {
        if let liveId = device.liveRecordId,
           let matched = records.first(where: { $0.id == liveId }) {
            return matched
        }
        return records.first(where: { $0.isTranscribing && $0.audioFile == nil })
    }

    public static let empty = HostSnapshot(
        version: 2, generation: 0, section: "today", canGoBack: false,
        selectedRecordId: nil, focusSegmentId: nil, records: [], todayRecordIds: [],
        detail: nil, tasks: [], memories: [],
        ask: AskSnapshot(scope: "all", recordId: nil, phase: "idle", messages: []),
        device: DeviceSnapshot(state: "未连接", connected: false, busy: false, files: [], progress: 0),
        provider: ProviderSnapshot(configured: false, model: ""),
        playback: PlaybackSnapshot(recordId: nil, positionMs: 0, isPlaying: false, requestId: 0, lane: nil, lanes: [], asset: nil),
        error: nil, notice: nil
    )
}
