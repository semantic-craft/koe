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
    @ObservationIgnored var runtimeDevice: DeviceSnapshot { snapshot.device }
    @ObservationIgnored var playbackRequest: PlaybackSnapshot { snapshot.playback }
    @ObservationIgnored var microphone: MicrophoneSnapshot? { snapshot.microphone }
    @ObservationIgnored var runtimeError: String? { snapshot.error }
    @ObservationIgnored public var lifecycle: LifecycleSnapshot? { snapshot.lifecycle }
    @ObservationIgnored public private(set) var nativeError: String? {
        didSet {
            guard nativeError != oldValue else { return }
            syncNavigationErrorSlice()
        }
    }
    @ObservationIgnored public private(set) var isUISlicesActive: Bool = true
    @ObservationIgnored var hasDeferredSliceReconcile: Bool = false
    @ObservationIgnored internal private(set) var lastProjectedNowSec: UInt64 = 0
    @ObservationIgnored public private(set) var handle: UInt64 = 0
    @ObservationIgnored public let workspacePath: String
    @ObservationIgnored public var onSnapshotChanged: ((HostSnapshot) -> Void)?
    @ObservationIgnored public var onTraceRecorded: (() -> Void)?
    @ObservationIgnored public var bridgeActions = HostBridgeActions()
    @ObservationIgnored private var requestGate = ViewRequestGeneration()
    @ObservationIgnored private let credentials: HostCredentials?
    @ObservationIgnored public let diagnostics: HostDiagnosticLog
    @ObservationIgnored private var traceBuffer: HostTraceRingBuffer
    @ObservationIgnored private let verificationTrace: Bool
    @ObservationIgnored private var resumeLiveOnCommand = false

    public internal(set) var platform: HostPlatformSnapshot = .macosDefault
    public internal(set) var navigation: NavigationChromeSlice = .empty
    public internal(set) var sidebar: SidebarSlice = .empty
    public internal(set) var today: TodaySlice = .empty
    public internal(set) var quickNoteWorkspace: QuickNoteWorkspaceSnapshot = .empty
    public internal(set) var allDayWorkspace: AllDayWorkspaceSnapshot = .empty
    public internal(set) var liveMinutesWorkspace: LiveMinutesWorkspaceSnapshot = .empty
    public internal(set) var liveMinutesCoverage: MeetingCoverageSnapshot?
    public internal(set) var recordDetail: RecordDetailSlice = .empty
    public internal(set) var records: [RecordSnapshot] = []
    public internal(set) var tasks: [TaskSnapshot] = []
    public internal(set) var memories: [MemorySnapshot] = []
    public internal(set) var trashRecords: [TrashRecordSnapshot] = []
    public internal(set) var ask: AskSnapshot = HostSnapshot.empty.ask
    public internal(set) var captureStudio: CaptureStudioSlice = .empty
    public internal(set) var device: DeviceSnapshot = .empty
    public internal(set) var settings: SettingsSlice = .empty
    public internal(set) var playback: PlaybackSnapshot = HostSnapshot.empty.playback
    public internal(set) var activeCapture: ActiveCaptureSnapshot?
    public internal(set) var activeCaptureMode: CaptureMode?
    public internal(set) var activeCaptureActions: [CaptureAction] = []
    public internal(set) var liveCaption: LiveCaptionSnapshot?
    public private(set) var updatePopoverRequestCount: UInt64 = 0

    public init(
        workspacePath: String? = nil,
        credentials: HostCredentials? = nil,
        verificationTrace: Bool = false,
        diagnostics: HostDiagnosticLog = .shared
    ) {
        self.verificationTrace = verificationTrace
        self.diagnostics = diagnostics
        traceBuffer = HostTraceRingBuffer(capacity: verificationTrace ? 2048 : 20)
        self.credentials = credentials
        let directory = workspacePath ?? Self.defaultWorkspacePath(isolated: credentials?.isolated == true)
        self.workspacePath = directory
        guard Self.apiVersion() == 2 else {
            diagnostics.error(
                category: "session",
                event: "abi_version_mismatch",
                detail: "expected=2 actual=\(Self.apiVersion())",
                errorCode: "abi_mismatch"
            )
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
            diagnostics.error(
                category: "session",
                event: "session_create_failed",
                detail: "isolated=\(credentials?.isolated == true)",
                errorCode: "session_open_failed"
            )
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

    public var recentTraceEntries: [HostTraceEntry] { traceBuffer.entries }

    public func recentDiagnostics() -> [HostDiagnosticEntry] { diagnostics.recentEntries() }

    public func exportTraceJSON() -> String { traceBuffer.exportJSON(diagnostics: diagnostics) }

    public func requestUpdatePopoverPresentation() {
        updatePopoverRequestCount &+= 1
    }

    public func send(_ command: HostCommand, nowEpochSec: UInt64 = 0) {
        _ = sendReturningError(command, nowEpochSec: nowEpochSec)
    }

    public func sendReturningError(_ command: HostCommand, nowEpochSec: UInt64 = 0) -> String? {
        guard handle != 0 else { return "工作区未打开。" }
        do {
            let data = try Self.encoder.encode(command)
            return dispatchEncodedJSON(data, traceKind: "command", commandType: command.commandType, nowEpochSec: nowEpochSec)
        } catch {
            let entry = diagnostics.error(
                category: "session",
                event: "encode_command_failed",
                detailPrefix: "command=\(command.commandType) ",
                error: error
            )
            let message = "无法发送这次操作，请重试。"
            nativeError = message
            recordTrace(kind: "command", name: command.commandType, errorDetail: entry.detail)
            return message
        }
    }

    public func send(_ event: HostAdapterEvent, nowEpochSec: UInt64 = 0) {
        guard handle != 0 else { return }
        do {
            let data = try Self.encoder.encode(event)
            dispatchEncodedJSON(data, traceKind: "event", commandType: event.eventType, nowEpochSec: nowEpochSec)
        } catch {
            let entry = diagnostics.error(
                category: "session",
                event: "encode_event_failed",
                detailPrefix: "event=\(event.eventType) ",
                error: error
            )
            nativeError = "无法发送这次操作，请重试。"
            recordTrace(kind: "event", name: event.eventType, errorDetail: entry.detail)
        }
    }

    @discardableResult
    private func dispatchEncodedJSON(_ data: Data, traceKind: String, commandType: String, nowEpochSec: UInt64) -> String? {
        var traceErrorDetail: String?
        defer { recordTrace(kind: traceKind, name: commandType, errorDetail: traceErrorDetail) }
        if resumeLiveOnCommand && traceKind == "command" {
            requestGate = ViewRequestGeneration()
            resumeLiveOnCommand = false
        }
        let preservesNativeError = commandType == "sync_audio_inputs"
            || commandType == "sync_app_metadata"
            || commandType.hasPrefix("local_asr_")
        if !preservesNativeError, nativeError != nil {
            nativeError = nil
        }
        guard let command = String(bytes: data, encoding: .utf8) else {
            traceErrorDetail = diagnostics.error(
                category: "session",
                event: "command_utf8_failed",
                detail: "\(traceKind)=\(commandType) invalid UTF-8 payload",
                errorCode: "utf8_decode_failed"
            ).detail
            nativeError = "操作未能完成，请重试。工作区数据仍然保留。"
            return nativeError
        }
        let effectiveNow = nowEpochSec > 0 ? nowEpochSec : UInt64(Date().timeIntervalSince1970)
        let result: String? = command.withCString { ptr in
            guard let response = koe_host_session_dispatch_json(handle, ptr, effectiveNow) else { return nil }
            defer { koe_host_string_free(response) }
            return String(cString: response)
        }
        guard let result else {
            traceErrorDetail = diagnostics.error(
                category: "session",
                event: "dispatch_null_response",
                detail: "\(traceKind)=\(commandType) bridge returned null",
                errorCode: "ffi_dispatch_null"
            ).detail
            nativeError = "操作未能完成，请重试。工作区数据仍然保留。"
            return nativeError
        }
        let outcome = decodeAndApplySnapshot(result, projectedNowSec: effectiveNow, isFixture: false, resumeLiveOnCommand: false)
        traceErrorDetail = outcome.errorDetail
        return outcome.error
    }

    public func refreshSnapshot(nowEpochSec: UInt64 = 0) {
        guard handle != 0 else { return }
        var traceErrorDetail: String?
        defer { recordTrace(kind: "snapshot", name: "snapshot", errorDetail: traceErrorDetail) }
        let effectiveNow = nowEpochSec > 0 ? nowEpochSec : UInt64(Date().timeIntervalSince1970)
        guard let pointer = koe_host_session_snapshot_json(handle, effectiveNow) else {
            traceErrorDetail = diagnostics.error(
                category: "session",
                event: "snapshot_null_response",
                detail: "bridge returned null snapshot",
                errorCode: "ffi_snapshot_null"
            ).detail
            nativeError = "无法读取工作区状态。"
            return
        }
        defer { koe_host_string_free(pointer) }
        let outcome = decodeAndApplySnapshot(
            String(cString: pointer),
            projectedNowSec: effectiveNow,
            isFixture: false,
            resumeLiveOnCommand: false
        )
        traceErrorDetail = outcome.errorDetail
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
                diagnostics.error(category: "ble", event: "drain_tx_framing_invalid", detail: "offset=\(offset) length=\(length) total=\(raw.count)", errorCode: "ble_tx_framing")
                nativeError = "无法读取设备发送队列。"
                return []
            }
            frames.append(raw.subdata(in: offset..<(offset + length)))
            offset += length
        }
        if offset != raw.count {
            diagnostics.error(category: "ble", event: "drain_tx_trailing_bytes", detail: "offset=\(offset) total=\(raw.count)", errorCode: "ble_tx_framing")
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

#if DEBUG
    @discardableResult
    public func loadDebugSnapshotFixtureJSON(_ json: String, resumeLiveOnCommand: Bool = false) -> Bool {
        let outcome = decodeAndApplySnapshot(json, projectedNowSec: 0, isFixture: true, resumeLiveOnCommand: resumeLiveOnCommand)
        recordTrace(kind: "fixture", name: "fixture", errorDetail: outcome.errorDetail)
        return outcome.accepted
    }
#endif

    @discardableResult
    func applySnapshotJSON(_ json: String, projectedNowSec: UInt64 = 0) -> String? {
        decodeAndApplySnapshot(json, projectedNowSec: projectedNowSec, isFixture: false, resumeLiveOnCommand: false).error
    }

    private func decodeAndApplySnapshot(
        _ json: String,
        projectedNowSec: UInt64,
        isFixture: Bool,
        resumeLiveOnCommand: Bool
    ) -> (accepted: Bool, error: String?, errorDetail: String?) {
        do {
            let decoded = try Self.decoder.decode(HostSnapshot.self, from: Data(json.utf8))
            guard decoded.version == 2 else {
                let entry = diagnostics.error(
                    category: "session",
                    event: isFixture ? "fixture_version_mismatch" : "snapshot_version_mismatch",
                    detail: "expected=2 actual=\(decoded.version)",
                    errorCode: "snapshot_version_mismatch"
                )
                nativeError = "数据引擎返回了不兼容的版本。"
                return (false, nativeError, entry.detail)
            }
            if isFixture {
                if nativeError != nil { nativeError = nil }
                requestGate = ViewRequestGeneration()
                _ = requestGate.acceptRustGeneration(decoded.generation)
                self.resumeLiveOnCommand = resumeLiveOnCommand
            } else {
                guard requestGate.acceptRustGeneration(decoded.generation) else { return (false, decoded.error, nil) }
                if projectedNowSec > 0 { lastProjectedNowSec = projectedNowSec }
            }
            if decoded != snapshot {
                snapshot = decoded
                if isUISlicesActive { reconcileSlices() } else { hasDeferredSliceReconcile = true }
                onSnapshotChanged?(decoded)
            }
            return (true, decoded.error, nil)
        } catch {
            let entry = diagnostics.error(
                category: "session",
                event: isFixture ? "decode_fixture_failed" : "decode_snapshot_failed",
                error: error
            )
            nativeError = "无法读取数据引擎的回应，请重新打开应用。"
            return (false, nativeError, entry.detail)
        }
    }

    private func recordTrace(kind: String, name: String, errorDetail: String? = nil) {
        if verificationTrace && kind == "snapshot" && nativeError == nil && snapshot.error == nil { return }
        let timestampEpochMs = UInt64(max(0, Date().timeIntervalSince1970 * 1000))
        traceBuffer.append(
            HostTraceEntry(
                kind: kind,
                name: name,
                generation: snapshot.generation,
                section: snapshot.section,
                hasError: (nativeError ?? snapshot.error) != nil,
                timestampEpochMs: timestampEpochMs,
                errorDetail: errorDetail.map(HostDiagnosticLog.redact)
            )
        )
        onTraceRecorded?()
    }
}
