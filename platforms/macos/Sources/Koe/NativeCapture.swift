import AppKit
import Foundation
import KoeAppleShared

@MainActor
final class NativeCapture {
    private final class EpochRun {
        let identity: CaptureIdentity
        let mailbox: MicrophoneMailbox
        let initialSequence: UInt64
        var fenced = false
        var pausedSent = false
        var stoppedSent = false
        var failureSent = false
        init(_ snapshot: MicrophoneSnapshot, lane: CaptureLaneSnapshot) {
            identity = CaptureIdentity(snapshot)
            initialSequence = lane.nextSequence
            mailbox = MicrophoneMailbox(nextSequence: initialSequence)
        }
    }
    private struct PermissionRequest: Equatable {
        let token = UUID()
        let identity: CaptureIdentity
        let resuming: Bool
    }
    weak var store: HostSessionStore?
    private let source: MicrophoneSource
    private let nowNanoseconds: () throws -> UInt64
    private var run: EpochRun?
    private var pendingPermission: PermissionRequest?
    private var applying = false
    init(source: MicrophoneSource = NativeAudioSource(),
         nowNanoseconds: @escaping () throws -> UInt64 = HostAudioClock.nowNanoseconds) {
        self.source = source
        self.nowNanoseconds = nowNanoseconds
    }

    func chooseInput() {
        guard let store, store.snapshot.microphone == nil else { return }
        let inputs = NativeAudioSource.inputs()
        let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 320, height: 26))
        picker.addItem(withTitle: "系统默认麦克风")
        for input in inputs { picker.addItem(withTitle: input.name) }
        let alert = NSAlert()
        alert.messageText = "选择录音输入"
        alert.informativeText = "录音先保存到本机。输入设备变化时会停止并保存已收到的音频。"
        alert.accessoryView = picker
        alert.addButton(withTitle: "开始录音")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let index = picker.indexOfSelectedItem
        store.send("start_microphone", ["inputId": index > 0 ? inputs[index - 1].id : ""])
        apply()
    }
    func resume() {
        guard let current = store?.snapshot.microphone, current.phase == "paused",
              pendingPermission == nil, run?.identity == CaptureIdentity(current) else { return }
        requestPermission(for: current, resuming: true)
    }

    func apply() {
        guard !applying, let store else { return }
        applying = true
        defer { applying = false }
        guard let current = store.snapshot.microphone else {
            if let run { stop(run) }
            run = nil
            pendingPermission = nil
            return
        }
        guard let lane = current.lanes[current.lane] else {
            if let run { stop(run) }
            store.reportNativeError("录音快照缺少当前音轨，无法继续采集。")
            return
        }
        if run?.identity != CaptureIdentity(current) {
            if let run { stop(run) }
            pendingPermission = nil
            run = EpochRun(current, lane: lane)
            if current.phase == "starting" { requestPermission(for: current, resuming: false) }
        }
        guard let run else { return }
        reportFailure(run)
        if ["pausing", "stopping", "cancelling", "saving"].contains(store.snapshot.microphone?.phase ?? "") {
            pendingPermission = nil
            stop(run)
            reportFailure(run)
        }
        for _ in 0..<64 {
            guard let block = run.mailbox.peek() else { break }
            send("microphone_chunk", run, ["sequence": block.sequence, "samples": block.pcm.samples,
                "timing": ["epoch": run.identity.epoch, "capturedStartNs": block.pcm.capturedStartNs]])
            guard let latest = store.snapshot.microphone, CaptureIdentity(latest) == run.identity,
                  let lane = latest.lanes[run.identity.lane] else { return }
            if lane.nextSequence == block.sequence + 1 {
                run.mailbox.acknowledge(block.sequence)
            } else {
                stop(run)
                if lane.error != nil { return }
                run.mailbox.fail(store.snapshot.error ?? "音频块未被接纳，已停止并保留此前收到的音频。")
                reportFailure(run)
                run.mailbox.discardUnaccepted(nextSequence: lane.nextSequence)
                break
            }
        }
        guard run.fenced, run.mailbox.peek() == nil,
              let latest = store.snapshot.microphone, CaptureIdentity(latest) == run.identity else { return }
        if latest.phase == "pausing", !run.pausedSent {
            run.pausedSent = true
            send("microphone_paused", run, ["sequence": run.mailbox.finalSequence, "epoch": run.identity.epoch])
        } else if ["stopping", "cancelling", "saving"].contains(latest.phase), !run.stoppedSent {
            run.stoppedSent = true
            send("microphone_stopped", run, ["sequence": run.mailbox.finalSequence, "epoch": run.identity.epoch])
        }
    }

    private func requestPermission(for snapshot: MicrophoneSnapshot, resuming: Bool) {
        let request = PermissionRequest(identity: CaptureIdentity(snapshot), resuming: resuming)
        pendingPermission = request
        source.requestPermission { [weak self] allowed in
            Task { @MainActor in self?.permission(allowed, request: request) }
        }
    }

    private func permission(_ allowed: Bool, request: PermissionRequest) {
        guard pendingPermission == request, !applying,
              let current = store?.snapshot.microphone, CaptureIdentity(current) == request.identity,
              current.phase == (request.resuming ? "paused" : "starting"), let previous = run else { return }
        pendingPermission = nil
        applying = true
        defer { applying = false; apply() }
        guard allowed else {
            previous.mailbox.fail("未获得麦克风权限，请在系统设置中允许 Koe 使用麦克风。")
            return
        }
        do {
            let clock = try nowNanoseconds()
            if request.resuming {
                store?.send("resume_microphone", ["clockNs": clock])
            } else {
                store?.send("microphone_prepared", ["recordId": request.identity.recordId,
                    "sessionId": request.identity.sessionId, "epoch": request.identity.epoch, "clockNs": clock])
            }
            guard let prepared = store?.snapshot.microphone,
                  prepared.recordId == current.recordId, prepared.sessionId == current.sessionId,
                  prepared.epoch == current.epoch + (request.resuming ? 1 : 0),
                  prepared.clockNs == clock,
                  prepared.phase == (request.resuming ? "recording" : "starting") else {
                previous.mailbox.fail(store?.snapshot.error ?? "无法确认音频采样时钟。")
                return
            }
            guard let lane = prepared.lanes[prepared.lane] else {
                throw CaptureError("录音快照缺少当前音轨，无法开始采集。")
            }
            let active: EpochRun
            if request.resuming {
                active = EpochRun(prepared, lane: lane)
                run = active
            } else {
                active = previous
            }
            start(active, snapshot: prepared, expectedRate: lane.sampleRate)
        } catch {
            previous.mailbox.fail(error.localizedDescription)
        }
    }

    private func start(_ run: EpochRun, snapshot: MicrophoneSnapshot, expectedRate: UInt32?) {
        let mailbox = run.mailbox
        do {
            let rate = try source.start(inputID: snapshot.inputId, expectedSampleRate: expectedRate,
                receive: { mailbox.append($0) }, failed: { mailbox.fail($0) })
            guard expectedRate == nil || expectedRate == rate else {
                throw CaptureError("麦克风采样率发生变化，已保留此前收到的音频。")
            }
            send("microphone_started", run, ["sampleRate": rate])
            if store?.snapshot.microphone?.phase != "recording" {
                mailbox.fail(store?.snapshot.error ?? "无法创建麦克风音频文件。")
            }
        } catch {
            stop(run)
            mailbox.discardUnaccepted(nextSequence: run.initialSequence)
            mailbox.fail("麦克风启动失败：\(error.localizedDescription)")
        }
    }

    private func stop(_ run: EpochRun) {
        guard !run.fenced else { return }
        source.stop()
        run.mailbox.close()
        run.fenced = true
    }

    private func reportFailure(_ run: EpochRun) {
        guard let error = run.mailbox.error, !run.failureSent else { return }
        run.failureSent = true
        send("microphone_failed", run, ["message": error, "epoch": run.identity.epoch])
    }

    private func send(_ type: String, _ run: EpochRun, _ fields: [String: Any]) {
        var payload = fields
        payload["recordId"] = run.identity.recordId
        payload["sessionId"] = run.identity.sessionId
        payload["lane"] = run.identity.lane
        store?.send(type, payload)
    }
}
