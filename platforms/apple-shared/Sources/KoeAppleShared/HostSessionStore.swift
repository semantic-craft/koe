import CKoeHostApi
import Foundation
import Observation

@MainActor
public struct ViewRequestGeneration {
    public private(set) var latestRustGeneration: UInt64 = 0
    public init() {}
    public mutating func acceptRustGeneration(_ generation: UInt64) -> Bool {
        guard generation >= latestRustGeneration else { return false }
        latestRustGeneration = generation
        return true
    }
}

@MainActor
@Observable
public final class HostSessionStore {
    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()

    @ObservationIgnored public private(set) var snapshot: HostSnapshot = .empty
    @ObservationIgnored public var lifecycle: LifecycleSnapshot? { snapshot.lifecycle }
    @ObservationIgnored public private(set) var nativeError: String? {
        didSet {
            guard nativeError != oldValue else { return }
            syncNavigationErrorSlice()
        }
    }
    @ObservationIgnored public private(set) var isUISlicesActive: Bool = true
    @ObservationIgnored private var hasDeferredSliceReconcile: Bool = false
    @ObservationIgnored internal private(set) var lastProjectedNowSec: UInt64 = 0
    @ObservationIgnored public private(set) var handle: UInt64 = 0
    @ObservationIgnored public let workspacePath: String
    @ObservationIgnored public var onSnapshotChanged: ((HostSnapshot) -> Void)?
    @ObservationIgnored public var bridgeActions = HostBridgeActions()
    @ObservationIgnored private var requestGate = ViewRequestGeneration()
    @ObservationIgnored private let credentials: HostCredentials?

    public private(set) var navigation: NavigationChromeSlice = .empty
    public private(set) var sidebar: SidebarSlice = .empty
    public private(set) var today: TodaySlice = .empty
    public private(set) var quickNoteWorkspace: QuickNoteWorkspaceSnapshot = .empty
    public private(set) var allDayWorkspace: AllDayWorkspaceSnapshot = .empty
    public private(set) var liveMinutesWorkspace: LiveMinutesWorkspaceSnapshot = .empty
    public private(set) var liveMinutesCoverage: MeetingCoverageSnapshot?
    public private(set) var recordDetail: RecordDetailSlice = .empty
    public private(set) var records: [RecordSnapshot] = []
    public private(set) var tasks: [TaskSnapshot] = []
    public private(set) var memories: [MemorySnapshot] = []
    public private(set) var trashRecords: [TrashRecordSnapshot] = []
    public private(set) var ask: AskSnapshot = HostSnapshot.empty.ask
    public private(set) var captureStudio: CaptureStudioSlice = .empty
    public private(set) var device: DeviceSnapshot = .empty
    public private(set) var settings: SettingsSlice = .empty
    public private(set) var playback: PlaybackSnapshot = HostSnapshot.empty.playback
    public private(set) var activeCapture: ActiveCaptureSnapshot?
    public private(set) var activeCaptureActions: [CaptureAction] = []
    public private(set) var liveCaption: LiveCaptionSnapshot?
    public private(set) var updatePopoverRequestCount: UInt64 = 0

    public init(workspacePath: String? = nil, credentials: HostCredentials? = nil) {
        self.credentials = credentials
        let directory = workspacePath ?? Self.defaultWorkspacePath(isolated: credentials?.isolated == true)
        self.workspacePath = directory
        guard Self.apiVersion() == 2 else {
            nativeError = "应用与数据引擎版本不一致，请重新构建应用。"
            return
        }
        if let credentials {
            let context = Unmanaged.passUnretained(credentials as AnyObject).toOpaque()
            handle = directory.withCString {
                koe_host_session_create_with_credentials($0, hostCredentialCallback, context, credentials.isolated)
            }
        } else {
            handle = directory.withCString { koe_host_session_create($0) }
        }
        guard handle != 0 else {
            nativeError = "无法打开工作区，请检查文件夹的访问权限。"
            return
        }
        refreshSnapshot()
    }

    deinit { if handle != 0 { _ = koe_host_session_destroy(handle) } }

    public static func apiVersion() -> UInt32 { koe_host_api_version() }

    public static func defaultWorkspacePath(isolated: Bool = false) -> String {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent(isolated ? "KoeWorkspaceDevelopment" : "KoeWorkspace", isDirectory: true).path
    }

    public func shutdown() {
        guard handle != 0 else { return }
        _ = koe_host_session_destroy(handle)
        handle = 0
    }

    public func setUISlicesActive(_ active: Bool) {
        guard isUISlicesActive != active else { return }
        isUISlicesActive = active
        if active, hasDeferredSliceReconcile {
            hasDeferredSliceReconcile = false
            reconcileSlices()
        }
    }

    public func reportNativeError(_ message: String) {
        if nativeError != message { nativeError = message }
    }

    public func clearError() {
        if nativeError != nil { nativeError = nil }
        send(.clearError)
    }

    public func requestUpdatePopoverPresentation() {
        updatePopoverRequestCount &+= 1
    }

    public func send(_ command: HostCommand, nowEpochSec: UInt64 = 0) {
        guard handle != 0 else { return }
        do {
            let data = try Self.encoder.encode(command)
            dispatchEncodedJSON(data, commandType: command.commandType, nowEpochSec: nowEpochSec)
        } catch {
            nativeError = "无法发送这次操作，请重试。"
        }
    }

    public func send(_ event: HostAdapterEvent, nowEpochSec: UInt64 = 0) {
        guard handle != 0 else { return }
        do {
            let data = try Self.encoder.encode(event)
            dispatchEncodedJSON(data, commandType: event.eventType, nowEpochSec: nowEpochSec)
        } catch {
            nativeError = "无法发送这次操作，请重试。"
        }
    }

    private func dispatchEncodedJSON(_ data: Data, commandType: String?, nowEpochSec: UInt64) {
        let preservesNativeError = commandType == "sync_audio_inputs"
            || commandType == "sync_app_metadata"
            || commandType?.hasPrefix("local_asr_") == true
        if !preservesNativeError, nativeError != nil {
            nativeError = nil
        }
        guard let command = String(data: data, encoding: .utf8) else { return }
        let effectiveNow = nowEpochSec > 0 ? nowEpochSec : UInt64(Date().timeIntervalSince1970)
        let result: String? = command.withCString { ptr in
            guard let response = koe_host_session_dispatch_json(handle, ptr, effectiveNow) else { return nil }
            defer { koe_host_string_free(response) }
            return String(cString: response)
        }
        guard let result else {
            nativeError = "操作未能完成，请重试。工作区数据仍然保留。"
            return
        }
        applySnapshotJSON(result, projectedNowSec: effectiveNow)
    }

    public func refreshSnapshot(nowEpochSec: UInt64 = 0) {
        guard handle != 0 else { return }
        let effectiveNow = nowEpochSec > 0 ? nowEpochSec : UInt64(Date().timeIntervalSince1970)
        guard let pointer = koe_host_session_snapshot_json(handle, effectiveNow) else {
            nativeError = "无法读取工作区状态。"
            return
        }
        defer { koe_host_string_free(pointer) }
        applySnapshotJSON(String(cString: pointer), projectedNowSec: effectiveNow)
    }

    public func refreshSnapshotIfNeeded(minGeneration: UInt64, nowEpochSec: UInt64 = 0) {
        if minGeneration > snapshot.generation {
            refreshSnapshot(nowEpochSec: nowEpochSec)
        }
    }

    public func ingestMicrophonePCM(
        recordId: String,
        sessionId: String,
        lane: String,
        sequence: UInt64,
        epoch: UInt64,
        capturedStartNs: UInt64?,
        samples: [Int16],
        nowEpochSec: UInt64 = 0
    ) -> PcmIngestReceipt {
        guard handle != 0 else {
            return PcmIngestReceipt(generation: 0, nextSequence: 0, status: .rejected)
        }
        if nativeError != nil { nativeError = nil }
        let raw = recordId.withCString { recordPtr in
            sessionId.withCString { sessionPtr in
                lane.withCString { lanePtr in
                    samples.withUnsafeBufferPointer { buffer in
                        koe_host_session_ingest_pcm(
                            handle,
                            recordPtr,
                            sessionPtr,
                            lanePtr,
                            sequence,
                            epoch,
                            capturedStartNs ?? 0,
                            capturedStartNs != nil,
                            buffer.baseAddress,
                            buffer.count,
                            nowEpochSec
                        )
                    }
                }
            }
        }
        let status = PcmIngestStatus(rawValue: raw.status) ?? .rejected
        return PcmIngestReceipt(generation: raw.generation, nextSequence: raw.next_sequence, status: status)
    }

    public func reportPlaybackProgress(
        recordId: String,
        requestId: UInt64,
        positionMs: UInt64,
        isPlaying: Bool,
        nowEpochSec: UInt64 = 0
    ) {
        guard handle != 0 else { return }
        let receipt = recordId.withCString { recordPtr in
            koe_host_session_report_playback_progress(
                handle,
                recordPtr,
                requestId,
                positionMs,
                isPlaying,
                lastProjectedNowSec,
                nowEpochSec
            )
        }
        if receipt.needs_full_snapshot {
            refreshSnapshot(nowEpochSec: nowEpochSec)
            return
        }
        guard receipt.applied else {
            refreshSnapshotIfNeeded(minGeneration: receipt.generation, nowEpochSec: nowEpochSec)
            return
        }
        guard receipt.prev_generation == snapshot.generation,
              requestGate.acceptRustGeneration(receipt.generation) else {
            refreshSnapshot(nowEpochSec: nowEpochSec)
            return
        }
        let nextSnapshot = snapshot.updatingPlayback(
            generation: receipt.generation,
            positionMs: receipt.position_ms,
            isPlaying: receipt.is_playing
        )
        snapshot = nextSnapshot
        lastProjectedNowSec = receipt.now_epoch_sec
        if isUISlicesActive {
            if playback != snapshot.playback { playback = snapshot.playback }
        } else {
            hasDeferredSliceReconcile = true
        }
        onSnapshotChanged?(nextSnapshot)
    }

    public func ingestBleChunk(_ data: Data, nowEpochSec: UInt64 = 0) {
        guard handle != 0 else { return }
        let generation = data.withUnsafeBytes { buffer in
            koe_host_session_ingest_ble(handle, buffer.bindMemory(to: UInt8.self).baseAddress, data.count, nowEpochSec)
        }
        if generation > snapshot.generation { refreshSnapshot(nowEpochSec: nowEpochSec) }
    }

    public func pollTimers(elapsedMs: UInt64, nowEpochSec: UInt64 = 0) {
        guard handle != 0 else { return }
        let generation = koe_host_session_poll_timers(handle, elapsedMs, nowEpochSec)
        if generation > snapshot.generation { refreshSnapshot(nowEpochSec: nowEpochSec) }
    }

    public func drainOutboundBleFrames() -> [Data] {
        guard handle != 0 else { return [] }
        let owned = koe_host_session_drain_ble_tx(handle)
        defer { koe_host_bytes_free(owned) }
        guard let ptr = owned.ptr, owned.len > 0 else { return [] }
        let raw = Data(bytes: ptr, count: owned.len)
        var frames: [Data] = []
        var offset = 0
        while offset + 4 <= raw.count {
            let length = Int(
                UInt32(raw[offset])
                    | (UInt32(raw[offset + 1]) << 8)
                    | (UInt32(raw[offset + 2]) << 16)
                    | (UInt32(raw[offset + 3]) << 24)
            )
            offset += 4
            guard offset + length <= raw.count else {
                nativeError = "无法读取设备发送队列。"
                return []
            }
            frames.append(raw.subdata(in: offset..<(offset + length)))
            offset += length
        }
        if offset != raw.count {
            nativeError = "无法读取设备发送队列。"
            return []
        }
        return frames
    }

    public func drainLocalASREffectsData() -> Data {
        guard handle != 0 else { return Data() }
        let owned = koe_host_session_drain_local_asr(handle)
        defer { koe_host_bytes_free(owned) }
        guard let ptr = owned.ptr, owned.len > 0 else { return Data() }
        return Data(bytes: ptr, count: owned.len)
    }

    func applySnapshotJSON(_ json: String, projectedNowSec: UInt64 = 0) {
        do {
            let decoded = try Self.decoder.decode(HostSnapshot.self, from: Data(json.utf8))
            guard decoded.version == 2 else {
                nativeError = "数据引擎返回了不兼容的版本。"
                return
            }
            guard requestGate.acceptRustGeneration(decoded.generation) else { return }
            if projectedNowSec > 0 {
                lastProjectedNowSec = projectedNowSec
            }
            if decoded != snapshot {
                snapshot = decoded
                if isUISlicesActive {
                    reconcileSlices()
                } else {
                    hasDeferredSliceReconcile = true
                }
                onSnapshotChanged?(decoded)
            }
        } catch {
            nativeError = "无法读取数据引擎的回应，请重新打开应用。"
        }
    }

    private func syncNavigationErrorSlice() {
        if isUISlicesActive {
            let nextNav = NavigationChromeSlice(snapshot: snapshot, nativeError: nativeError)
            if navigation != nextNav { navigation = nextNav }
        } else {
            hasDeferredSliceReconcile = true
        }
    }

    public func reconcileMenuSlicesIfNeeded() {
        guard hasDeferredSliceReconcile else { return }
        let nextNavigation = NavigationChromeSlice(snapshot: snapshot, nativeError: nativeError)
        if navigation != nextNavigation { navigation = nextNavigation }
        let nextToday = TodaySlice(snapshot: snapshot)
        if today != nextToday { today = nextToday }
        if device != snapshot.device { device = snapshot.device }
        let nextSettings = SettingsSlice(snapshot: snapshot)
        if settings != nextSettings { settings = nextSettings }
    }

    private func reconcileSlices() {
        hasDeferredSliceReconcile = false
        let nextNavigation = NavigationChromeSlice(snapshot: snapshot, nativeError: nativeError)
        if navigation != nextNavigation { navigation = nextNavigation }
        let nextSidebar = SidebarSlice(snapshot: snapshot)
        if sidebar != nextSidebar { sidebar = nextSidebar }
        let nextToday = TodaySlice(snapshot: snapshot)
        if today != nextToday { today = nextToday }
        let nextQuickNote = snapshot.workspaces?.quickNote ?? .empty
        if quickNoteWorkspace != nextQuickNote { quickNoteWorkspace = nextQuickNote }
        let nextAllDay = snapshot.workspaces?.allDay ?? .empty
        if allDayWorkspace != nextAllDay { allDayWorkspace = nextAllDay }
        let resolvedLive = snapshot.workspaces?.liveMinutes ?? .empty
        let strippedLive = resolvedLive.withoutCoverage()
        if liveMinutesWorkspace != strippedLive { liveMinutesWorkspace = strippedLive }
        if liveMinutesCoverage != resolvedLive.coverage { liveMinutesCoverage = resolvedLive.coverage }
        let nextDetail = RecordDetailSlice(snapshot: snapshot)
        if recordDetail != nextDetail { recordDetail = nextDetail }
        if records != snapshot.records { records = snapshot.records }
        if tasks != snapshot.tasks { tasks = snapshot.tasks }
        if memories != snapshot.memories { memories = snapshot.memories }
        if trashRecords != snapshot.trashRecords { trashRecords = snapshot.trashRecords }
        if ask != snapshot.ask { ask = snapshot.ask }
        let nextCaptureStudio = CaptureStudioSlice(snapshot: snapshot)
        if captureStudio != nextCaptureStudio { captureStudio = nextCaptureStudio }
        if device != snapshot.device { device = snapshot.device }
        let nextSettings = SettingsSlice(snapshot: snapshot)
        if settings != nextSettings { settings = nextSettings }
        if playback != snapshot.playback { playback = snapshot.playback }
        if activeCapture != snapshot.activeCapture { activeCapture = snapshot.activeCapture }
        let nextActions = snapshot.activeCapture?.actions ?? []
        if activeCaptureActions != nextActions { activeCaptureActions = nextActions }
        if liveCaption != snapshot.liveCaption { liveCaption = snapshot.liveCaption }
    }
}
