import AppKit
import Foundation
import KoeAppleShared

protocol MicrophoneSource: AnyObject {
    func requestPermission(_ completion: @escaping (Bool) -> Void)
    func start(inputID: String, receive: @escaping ([Int16]) -> Void, failed: @escaping (String) -> Void) throws -> UInt32
    func stop()
}

final class MicrophoneMailbox: @unchecked Sendable {
    struct Block { let sequence: UInt64; let samples: [Int16] }
    private let lock = NSLock()
    private var blocks: [Block] = []
    private var sequence: UInt64 = 0
    private var closed = false
    private var failure: String?
    func append(_ samples: [Int16]) {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return }
        guard !samples.isEmpty, samples.count <= 8192, blocks.count < 64 else {
            failure = "音频处理未能跟上采集，已停止并保留已接收的音频。"
            closed = true
            return
        }
        blocks.append(Block(sequence: sequence, samples: samples))
        sequence += 1
    }
    func fail(_ message: String) {
        lock.lock(); defer { lock.unlock() }
        failure = failure ?? message
        closed = true
    }
    func close() { lock.lock(); defer { lock.unlock() }; closed = true }
    func peek() -> Block? { lock.lock(); defer { lock.unlock() }; return blocks.first }
    func acknowledge(_ sequence: UInt64) {
        lock.lock(); defer { lock.unlock() }
        if blocks.first?.sequence == sequence { blocks.removeFirst() }
    }
    var error: String? { lock.lock(); defer { lock.unlock() }; return failure }
    var finalSequence: UInt64 { lock.lock(); defer { lock.unlock() }; return sequence }
}

@MainActor
final class NativeCapture {
    weak var store: HostSessionStore?
    private let source: MicrophoneSource
    private var ticket: MicrophoneSnapshot?
    private var mailbox: MicrophoneMailbox?
    private var stopped = false
    private var terminalSent = false
    private var failureSent = false
    private var applying = false
    init(source: MicrophoneSource = NativeAudioSource()) { self.source = source }

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
    func apply() {
        guard !applying, let store else { return }
        applying = true
        defer { applying = false }
        guard let current = store.snapshot.microphone else {
            if ticket != nil { source.stop(); mailbox?.close() }
            ticket = nil; mailbox = nil
            return
        }
        if ticket?.sessionId != current.sessionId {
            source.stop(); mailbox?.close()
            ticket = current; mailbox = MicrophoneMailbox()
            stopped = false; terminalSent = false; failureSent = false
            if current.phase == "starting" {
                let sessionID = current.sessionId
                source.requestPermission { [weak self] allowed in
                    Task { @MainActor in self?.permission(allowed, sessionID: sessionID) }
                }
            }
        }
        guard let mailbox else { return }
        if let error = mailbox.error, !failureSent {
            failureSent = true
            send("microphone_failed", ["message": error])
        }
        let phase = store.snapshot.microphone?.phase
        if phase == "stopping" || phase == "cancelling" || mailbox.error != nil {
            if !stopped { source.stop(); mailbox.close(); stopped = true }
        }
        for _ in 0..<64 {
            guard let block = mailbox.peek() else { break }
            send("microphone_chunk", ["sequence": block.sequence, "samples": block.samples])
            guard store.snapshot.microphone?.sessionId == current.sessionId,
                  store.snapshot.microphone?.nextSequence == block.sequence + 1 else { return }
            mailbox.acknowledge(block.sequence)
        }
        if stopped, mailbox.peek() == nil, !terminalSent {
            terminalSent = true
            send("microphone_stopped", ["sequence": mailbox.finalSequence])
        }
    }
    private func permission(_ allowed: Bool, sessionID: String) {
        guard ticket?.sessionId == sessionID,
              store?.snapshot.microphone?.sessionId == sessionID,
              store?.snapshot.microphone?.phase == "starting", !stopped,
              let mailbox else { return }
        guard allowed else {
            mailbox.fail("未获得麦克风权限，请在系统设置中允许 Koe 使用麦克风。")
            apply()
            return
        }
        do {
            let rate = try source.start(inputID: ticket?.inputId ?? "", receive: { mailbox.append($0) }, failed: { mailbox.fail($0) })
            send("microphone_started", ["sampleRate": rate])
            if store?.snapshot.microphone?.phase != "recording" {
                mailbox.fail(store?.snapshot.error ?? "无法创建麦克风音频文件。")
            }
        } catch { mailbox.fail(error.localizedDescription) }
        apply()
    }
    private func send(_ type: String, _ fields: [String: Any]) {
        guard let ticket else { return }
        var payload = fields
        payload["recordId"] = ticket.recordId
        payload["sessionId"] = ticket.sessionId
        payload["lane"] = ticket.lane
        store?.send(type, payload)
    }
}
