import Foundation
import OSLog

/// Native producer for the Rust capture session: one independent run per lane ("microphone" and the
/// optional "system"), each with its own bounded mailbox, sequence, fence and terminal barrier.
@MainActor
public final class NativeCapture {
    private final class LaneRun {
        let identity: CaptureIdentity
        let mailbox: MicrophoneMailbox
        let initialSequence: UInt64
        var fenced = false
        var pausedSent = false
        var stoppedSent = false
        var failureSent = false
        var lane: String { identity.lane }
        init(_ snapshot: MicrophoneSnapshot, lane: String, state: CaptureLaneSnapshot) {
            identity = CaptureIdentity(snapshot, lane: lane)
            initialSequence = state.nextSequence
            mailbox = MicrophoneMailbox(nextSequence: initialSequence, limit: lane == "system" ? 256 : 64)
        }
    }
    private final class AbortFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.lock(); value = true; lock.unlock() }
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    }
    private struct PermissionRequest: Equatable {
        let token = UUID()
        let session: CaptureSession
        let resuming: Bool
        let lanes: [String]
        let abort = AbortFlag()
        static func == (lhs: Self, rhs: Self) -> Bool { lhs.token == rhs.token }
    }
    static let microphoneDenied = "未获得麦克风权限，请在系统设置中允许 Koe 使用麦克风。"

    public weak var store: HostSessionStore?
    private let source: MicrophoneSource
    private let systemSource: SystemAudioSource?
    private let logger: Logger
    private let nowNanoseconds: () throws -> UInt64
    private var session: CaptureSession?
    private var runs: [String: LaneRun] = [:]
    private var pendingPermission: PermissionRequest? {
        didSet { if oldValue != pendingPermission { oldValue?.abort.set() } }
    }
    private var permissionResults: [String: SystemAudioAuthResult] = [:]
    private var applying = false

    public init(source: MicrophoneSource, systemSource: SystemAudioSource? = nil,
                logger: Logger = Logger(subsystem: "com.semanticcraft.koe", category: "capture"),
                nowNanoseconds: @escaping () throws -> UInt64 = HostAudioClock.nowNanoseconds) {
        self.logger = logger
        self.source = source
        self.systemSource = systemSource
        self.nowNanoseconds = nowNanoseconds
    }

    private var orderedRuns: [LaneRun] { runs.keys.sorted().compactMap { runs[$0] } }

    public func resume() {
        guard let current = store?.microphone, current.phase == "paused",
              pendingPermission == nil, session == CaptureSession(current) else { return }
        requestPermissions(for: current, resuming: true)
    }

    public func apply() {
        guard !applying, let store else { return }
        applying = true
        defer { applying = false }
        guard let current = store.microphone else {
            stopAll()
            runs = [:]
            session = nil
            pendingPermission = nil
            return
        }
        if session != CaptureSession(current) {
            stopAll()
            pendingPermission = nil
            session = CaptureSession(current)
            runs = [:]
            for (lane, state) in current.lanes where !state.stopped {
                runs[lane] = LaneRun(current, lane: lane, state: state)
            }
            if current.lanes.isEmpty {
                activeDiagnostics.error(
                    category: "capture",
                    event: "missing_lanes",
                    detail: "phase=\(current.phase)",
                    errorCode: "missing_lanes"
                )
                store.reportNativeError("录音快照缺少音轨，无法继续采集。")
            }
            if current.phase == "starting" { requestPermissions(for: current, resuming: false) }
        }
        orderedRuns.forEach(reportFailure)
        if ["pausing", "stopping", "cancelling", "saving"].contains(store.microphone?.phase ?? "") {
            pendingPermission = nil
            stopAll()
            orderedRuns.forEach(reportFailure)
        }
        var maxIngestGeneration: UInt64 = 0
        for run in orderedRuns where drain(run, maxIngestGeneration: &maxIngestGeneration) == .awaitingSessionSync {
            store.refreshSnapshotIfNeeded(minGeneration: maxIngestGeneration)
            return
        }
        store.refreshSnapshotIfNeeded(minGeneration: maxIngestGeneration)
        if ["pausing", "stopping", "cancelling", "saving"].contains(store.microphone?.phase ?? "") {
            pendingPermission = nil
            stopAll()
            orderedRuns.forEach(reportFailure)
            var tailGeneration: UInt64 = 0
            for run in orderedRuns where run.mailbox.peek() != nil {
                if drain(run, maxIngestGeneration: &tailGeneration) == .awaitingSessionSync {
                    store.refreshSnapshotIfNeeded(minGeneration: tailGeneration)
                    return
                }
            }
            store.refreshSnapshotIfNeeded(minGeneration: tailGeneration)
        }
        for run in orderedRuns { finish(run) }
    }

    private enum DrainOutcome {
        case drained
        case awaitingSessionSync
    }

    private func drain(_ run: LaneRun, maxIngestGeneration: inout UInt64) -> DrainOutcome {
        guard let store else { return .awaitingSessionSync }
        for _ in 0..<run.mailbox.limit {
            guard let block = run.mailbox.peek() else { break }
            let receipt = store.ingestMicrophonePCM(
                recordId: run.identity.recordId,
                sessionId: run.identity.sessionId,
                lane: run.lane,
                sequence: block.sequence,
                epoch: run.identity.epoch,
                capturedStartNs: block.pcm.capturedStartNs,
                samples: block.pcm.samples
            )
            maxIngestGeneration = max(maxIngestGeneration, receipt.generation)
            if receipt.status == .accepted, receipt.nextSequence == block.sequence + 1 {
                run.mailbox.acknowledge(block.sequence)
            } else {
                store.refreshSnapshotIfNeeded(minGeneration: maxIngestGeneration)
                guard let latest = store.microphone, CaptureSession(latest) == session,
                      let lane = latest.lanes[run.lane] else { return .awaitingSessionSync }
                stop(run)
                if lane.error != nil { return .awaitingSessionSync }
                run.mailbox.fail(store.runtimeError ?? "音频块未被接纳，已停止并保留此前收到的音频。")
                reportFailure(run)
                run.mailbox.discardUnaccepted(nextSequence: lane.nextSequence)
                break
            }
        }
        return .drained
    }

    /// Terminal barrier per lane: paused/stopped carries the final sequence once callbacks are fenced.
    private func finish(_ run: LaneRun) {
        guard run.fenced, run.mailbox.peek() == nil, let latest = store?.microphone,
              CaptureSession(latest) == session, let lane = latest.lanes[run.lane], !lane.stopped else { return }
        if run.failureSent || ["stopping", "cancelling", "saving"].contains(latest.phase) {
            guard !run.stoppedSent else { return }
            run.stoppedSent = true
            send(.microphoneStopped(
                recordId: run.identity.recordId,
                sessionId: run.identity.sessionId,
                lane: run.lane,
                sequence: run.mailbox.finalSequence,
                epoch: run.identity.epoch
            ))
        } else if latest.phase == "pausing", !run.pausedSent {
            run.pausedSent = true
            send(.microphonePaused(
                recordId: run.identity.recordId,
                sessionId: run.identity.sessionId,
                lane: run.lane,
                sequence: run.mailbox.finalSequence,
                epoch: run.identity.epoch
            ))
        }
    }

    private func requestPermissions(for snapshot: MicrophoneSnapshot, resuming: Bool) {
        let lanes = snapshot.lanes.filter { !$0.value.stopped }.keys.sorted()
        let request = PermissionRequest(session: CaptureSession(snapshot), resuming: resuming, lanes: lanes)
        pendingPermission = request
        permissionResults = [:]
        if lanes.contains("microphone") {
            source.requestPermission { [weak self] allowed in
                Task { @MainActor in
                    self?.permission("microphone", allowed ? .authorized : .denied(Self.microphoneDenied), request: request)
                }
            }
        }
        if lanes.contains("system") {
            let abort = request.abort
            let completion: @Sendable (SystemAudioAuthResult) -> Void = { [weak self] result in
                Task { @MainActor in self?.permission("system", result, request: request) }
            }
            if let systemSource {
                systemSource.authorize(shouldAbort: { abort.isSet }, completion)
            } else {
                completion(.unavailable("当前平台不支持录制系统音频。"))
            }
        }
    }

    private func permission(_ lane: String, _ result: SystemAudioAuthResult, request: PermissionRequest) {
        guard pendingPermission == request, !applying else { return }
        permissionResults[lane] = result
        guard request.lanes.allSatisfy({ permissionResults[$0] != nil }) else { return }
        let results = permissionResults
        guard let current = store?.microphone, CaptureSession(current) == request.session,
              current.phase == (request.resuming ? "paused" : "starting") else { return }
        pendingPermission = nil
        applying = true
        defer { applying = false; apply() }
        let granted = request.lanes.filter { results[$0] == .authorized }
        guard !granted.isEmpty else {
            for lane in request.lanes {
                runs[lane]?.mailbox.fail(results[lane]?.failureMessage ?? "未获得采集权限。")
            }
            return
        }
        do {
            let clock = try nowNanoseconds()
            if request.resuming {
                send(.resumeMicrophone(clockNs: clock))
            } else {
                send(.microphonePrepared(
                    recordId: request.session.recordId,
                    sessionId: request.session.sessionId,
                    epoch: request.session.epoch,
                    clockNs: clock
                ))
            }
            guard let prepared = store?.microphone,
                  prepared.recordId == request.session.recordId, prepared.sessionId == request.session.sessionId,
                  prepared.epoch == request.session.epoch + (request.resuming ? 1 : 0),
                  prepared.clockNs == clock,
                  prepared.phase == (request.resuming ? "recording" : "starting") else {
                for lane in request.lanes { runs[lane]?.mailbox.fail(store?.runtimeError ?? "无法确认音频采样时钟。") }
                return
            }
            if request.resuming {
                session = CaptureSession(prepared)
                runs = [:]
                for lane in request.lanes {
                    guard let state = prepared.lanes[lane] else { continue }
                    runs[lane] = LaneRun(prepared, lane: lane, state: state)
                }
            }
            for lane in request.lanes where results[lane] != .authorized {
                runs[lane]?.mailbox.fail(results[lane]?.failureMessage ?? "未获得采集权限。")
            }
            for lane in granted {
                guard let run = runs[lane] else { continue }
                start(run, snapshot: prepared, expectedRate: prepared.lanes[lane]?.sampleRate)
            }
        } catch {
            activeDiagnostics.error(category: "capture", event: "clock_failed", error: error)
            for lane in request.lanes { runs[lane]?.mailbox.fail(error.localizedDescription) }
        }
    }

    private func start(_ run: LaneRun, snapshot: MicrophoneSnapshot, expectedRate: UInt32?) {
        let mailbox = run.mailbox
        let system = run.lane == "system"
        let label = system ? "系统音频" : "麦克风"
        do {
            let rate: UInt32
            if system {
                guard let systemSource else { throw CaptureError("当前平台不支持录制系统音频。") }
                rate = try systemSource.start(expectedSampleRate: expectedRate,
                    receive: { mailbox.append($0) }, failed: { mailbox.fail($0) })
            } else {
                rate = try source.start(inputID: snapshot.inputId, expectedSampleRate: expectedRate,
                    receive: { mailbox.append($0) }, failed: { mailbox.fail($0) })
            }
            guard expectedRate == nil || expectedRate == rate else {
                throw CaptureError("\(label)采样率发生变化，已保留此前收到的音频。")
            }
            send(.microphoneStarted(
                recordId: run.identity.recordId,
                sessionId: run.identity.sessionId,
                lane: run.lane,
                sampleRate: rate
            ))
            guard let lane = store?.microphone?.lanes[run.lane], lane.started, lane.error == nil else {
                mailbox.fail(store?.runtimeError ?? "无法创建\(label)音频文件。")
                return
            }
        } catch {
            activeDiagnostics.error(
                category: "capture",
                event: "lane_start_failed",
                detailPrefix: "lane=\(run.lane) ",
                error: error
            )
            stop(run)
            mailbox.discardUnaccepted(nextSequence: run.initialSequence)
            mailbox.fail("\(label)启动失败：\(error.localizedDescription)")
        }
    }

    private var activeDiagnostics: HostDiagnosticLog { store?.diagnostics ?? .shared }

    private func send(_ event: HostAdapterEvent) {
        logger.info("Capture event \(event.eventType, privacy: .public)")
        store?.send(event)
    }

    public func shutdown() {
        if let store, let microphone = store.microphone, microphone.phase != "saving" {
            store.performCaptureAction(.end)
            apply()
        }
        pendingPermission = nil
        stopAll()
        source.stop()
        runs.removeAll()
        session = nil
        store = nil
    }

    private func stopAll() { orderedRuns.forEach(stop) }

    private func stop(_ run: LaneRun) {
        guard !run.fenced else { return }
        if run.lane == "system" { systemSource?.stop() } else { source.stop() }
        run.mailbox.close()
        run.fenced = true
    }

    /// A failed lane is fenced and reported; Rust keeps the session alive while another lane records.
    private func reportFailure(_ run: LaneRun) {
        guard let error = run.mailbox.error, !run.failureSent else { return }
        activeDiagnostics.error(
            category: "capture",
            event: "lane_failed",
            detail: "lane=\(run.lane) reason=\(error)",
            errorCode: "lane_failed"
        )
        run.failureSent = true
        stop(run)
        send(.microphoneFailed(
            recordId: run.identity.recordId,
            sessionId: run.identity.sessionId,
            lane: run.lane,
            message: error,
            epoch: run.identity.epoch
        ))
    }
}
