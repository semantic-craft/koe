import Foundation

public enum PcmIngestStatus: UInt32, Equatable, Sendable {
    case accepted = 0
    case staleSession = 1
    case rejected = 2
}

public struct PcmIngestReceipt: Equatable, Sendable {
    public let generation: UInt64
    public let nextSequence: UInt64
    public let status: PcmIngestStatus

    public init(generation: UInt64, nextSequence: UInt64, status: PcmIngestStatus) {
        self.generation = generation
        self.nextSequence = nextSequence
        self.status = status
    }
}

public struct NavigationChromeSlice: Equatable, Sendable {
    public let section: String
    public let canGoBack: Bool
    public let selectedRecordId: String?
    public let detailId: String?
    public let detailTitle: String?
    public let detailDurationMs: UInt64
    public let hasPlayableDetailAsset: Bool
    public let hasConnectGuide: Bool
    public let undoTrash: UndoTrashSnapshot?
    public let effectiveError: String?
    public let notice: String?

    public static let empty = NavigationChromeSlice(snapshot: .empty, nativeError: nil)

    public init(snapshot: HostSnapshot, nativeError: String?) {
        section = snapshot.section
        canGoBack = snapshot.canGoBack
        selectedRecordId = snapshot.selectedRecordId
        detailId = snapshot.detail?.id
        detailTitle = snapshot.detail?.title
        detailDurationMs = snapshot.detail?.durationMs ?? 0
        hasPlayableDetailAsset = snapshot.playback.asset != nil && snapshot.playback.recordId == snapshot.detail?.id
        hasConnectGuide = snapshot.device.guide != nil
        undoTrash = snapshot.undoTrash
        effectiveError = nativeError ?? snapshot.error
        notice = snapshot.notice
    }
}

public struct SidebarSlice: Equatable, Sendable {
    public let section: String
    public let recordCount: Int
    public let proposedActionCount: Int
    public let memoryCount: Int
    public let activeModeIds: Set<String>
    public let appVersion: String
    public let appBuild: String
    public let hasAvailableUpdate: Bool
    public let beanControlOwner: String
    public let deviceName: String
    public let deviceConnected: Bool
    public let devicePhase: String
    public let deviceState: String
    public let batteryPercent: Int?
    public let boxBatteryPercent: Int?

    public static let empty = SidebarSlice(snapshot: .empty)

    public init(snapshot: HostSnapshot) {
        section = snapshot.section
        recordCount = snapshot.records.count
        proposedActionCount = snapshot.tasks.reduce(0) { $0 + ($1.state == "proposed" ? 1 : 0) }
        memoryCount = snapshot.memories.reduce(0) { $0 + ($1.state != "dismissed" ? 1 : 0) }
        activeModeIds = Set(
            (snapshot.workspaces?.picker.cards ?? [])
                .filter(\.isSessionActive)
                .map(\.id)
        )
        appVersion = snapshot.appUpdate.currentVersion
        appBuild = snapshot.appUpdate.currentBuild
        hasAvailableUpdate = snapshot.appUpdate.isUpdateAvailable
        beanControlOwner = snapshot.workspaces?.picker.beanControlOwner ?? "mac"
        deviceName = snapshot.device.deviceName
        deviceConnected = snapshot.device.connected
        devicePhase = snapshot.device.phase
        deviceState = snapshot.device.state
        batteryPercent = snapshot.device.batteryPercent
        boxBatteryPercent = snapshot.device.boxBatteryPercent
    }
}

public struct TodaySlice: Equatable, Sendable {
    public let picker: ModePickerSnapshot?
    public let recordCount: Int
    public let proposedActionCount: Int
    public let deviceConnected: Bool
    public let deviceState: String
    public let captureSelectedBadge: String
    public let captureSelectedLabel: String

    public static let empty = TodaySlice(snapshot: .empty)

    public init(snapshot: HostSnapshot) {
        picker = snapshot.workspaces?.picker
        recordCount = snapshot.records.count
        proposedActionCount = snapshot.tasks.reduce(0) { $0 + ($1.state == "proposed" ? 1 : 0) }
            + snapshot.memories.reduce(0) { $0 + ($1.state == "proposed" ? 1 : 0) }
        deviceConnected = snapshot.device.connected
        deviceState = snapshot.device.state
        captureSelectedBadge = snapshot.capture.selectedBadge
        captureSelectedLabel = snapshot.capture.selectedLabel
    }
}

public struct RecordDetailSlice: Equatable, Sendable {
    public let detail: RecordDetailSnapshot?
    public let focusSegmentId: String?
    public let recordTasks: [TaskSnapshot]
    public let recordMemories: [MemorySnapshot]

    public static let empty = RecordDetailSlice(snapshot: .empty)

    public init(snapshot: HostSnapshot) {
        detail = snapshot.detail
        focusSegmentId = snapshot.focusSegmentId
        if let detailId = snapshot.detail?.id {
            recordTasks = snapshot.tasks.filter {
                $0.state != "dismissed" && $0.sources.contains { $0.recordId == detailId }
            }
            recordMemories = snapshot.memories.filter {
                $0.state != "dismissed" && $0.sources.contains { $0.recordId == detailId }
            }
        } else {
            recordTasks = []
            recordMemories = []
        }
    }
}

public struct CaptureStudioSlice: Equatable, Sendable {
    public let studio: CaptureStudioSnapshot
    public let isRecordingLocked: Bool

    public static let empty = CaptureStudioSlice(snapshot: .empty)

    public init(snapshot: HostSnapshot) {
        studio = snapshot.capture
        isRecordingLocked = snapshot.activeCapture != nil
    }
}

public struct SettingsSlice: Equatable, Sendable {
    public let speech: SpeechSnapshot
    public let provider: ProviderSnapshot
    public let appUpdate: AppUpdateSnapshot

    public static let empty = SettingsSlice(snapshot: .empty)

    public init(snapshot: HostSnapshot) {
        speech = snapshot.speech
        provider = snapshot.provider
        appUpdate = snapshot.appUpdate
    }
}

extension LiveMinutesWorkspaceSnapshot {
    public func withoutCoverage() -> LiveMinutesWorkspaceSnapshot {
        guard coverage != nil else { return self }
        return LiveMinutesWorkspaceSnapshot(
            isActive: isActive,
            canStart: canStart,
            phase: phase,
            configured: configured,
            sourceLabel: sourceLabel,
            activeRecordId: activeRecordId,
            selectedRecordId: selectedRecordId,
            selectedTitle: selectedTitle,
            minutesStale: minutesStale,
            canSummarize: canSummarize,
            error: error,
            coverage: nil,
            segments: segments,
            drafts: drafts,
            liveSections: liveSections,
            finalSections: finalSections,
            actionItems: actionItems,
            pastMeetings: pastMeetings
        )
    }
}
