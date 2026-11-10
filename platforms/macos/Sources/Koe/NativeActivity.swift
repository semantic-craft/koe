import AppKit
import Foundation
import KoeAppleShared

@MainActor
final class NativeActivity {
    private var token: NSObjectProtocol?
    private let begin: () -> NSObjectProtocol
    private let end: (NSObjectProtocol) -> Void

    init(
        begin: @escaping () -> NSObjectProtocol = {
            ProcessInfo.processInfo.beginActivity(
                options: [.idleSystemSleepDisabled, .userInitiated],
                reason: "Koe is recording or saving results"
            )
        },
        end: @escaping (NSObjectProtocol) -> Void = { ProcessInfo.processInfo.endActivity($0) }
    ) {
        self.begin = begin
        self.end = end
    }

    func update(keepAwake: Bool) {
        if keepAwake {
            if token == nil { token = begin() }
        } else if let token {
            end(token)
            self.token = nil
        }
    }
}

@MainActor
final class NativeQuitCoordinator {
    private enum ReplyState { case idle, requesting, waiting }
    private var replyState = ReplyState.idle
    private let send: (String) -> Void
    private let reply: (Bool) -> Void
    private let activity: NativeActivity
    private var latest: LifecycleSnapshot?

    init(activity: NativeActivity? = nil, send: @escaping (String) -> Void, reply: @escaping (Bool) -> Void) {
        self.activity = activity ?? NativeActivity()
        self.send = send
        self.reply = reply
    }

    func apply(_ snapshot: LifecycleSnapshot?) {
        latest = snapshot
        guard let snapshot else { return }
        activity.update(keepAwake: snapshot.keepAwake)
        guard replyState == .waiting else { return }
        if snapshot.quitPhase == "ready" || snapshot.quitPhase == "running" {
            replyState = .idle
            reply(snapshot.quitPhase == "ready")
        }
    }

    func request() -> NSApplication.TerminateReply {
        guard replyState == .idle else { return .terminateLater }
        replyState = .requesting
        latest = nil
        send("request_quit")
        if latest?.quitPhase == "ready" {
            replyState = .idle
            return .terminateNow
        }
        guard latest?.quitPhase == "draining" || latest?.quitPhase == "blocked" else {
            replyState = .idle
            return .terminateCancel
        }
        replyState = .waiting
        return .terminateLater
    }

    func cancel() {
        guard replyState == .waiting else { return }
        replyState = .idle
        send("cancel_quit")
        reply(false)
    }

    func shutdown() { activity.update(keepAwake: false) }
}

@MainActor
final class NativeQuitPanel: NSObject {
    private let panel: NSPanel
    private let message = NSTextField(wrappingLabelWithString: "")
    private let cancel: () -> Void

    init(cancel: @escaping () -> Void) {
        self.cancel = cancel
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 430, height: 160),
                        styleMask: [.titled], backing: .buffered, defer: false)
        super.init()
        panel.title = "正在退出 Koe"
        panel.isReleasedWhenClosed = false
        let button = NSButton(title: "取消退出", target: self, action: #selector(cancelQuit))
        button.keyEquivalent = "\u{1b}"
        let stack = NSStackView(views: [message, button])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 20
        stack.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView?.addSubview(stack)
        if let content = panel.contentView {
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
                stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
                stack.centerYAnchor.constraint(equalTo: content.centerYAnchor)
            ])
        }
    }

    func show(_ snapshot: LifecycleSnapshot?) {
        message.stringValue = snapshot?.message ?? "正在保存，完成后将自动退出。"
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        NSApp?.activate(ignoringOtherApps: true)
    }

    func update(_ snapshot: LifecycleSnapshot?) {
        message.stringValue = snapshot?.message ?? "正在保存，完成后将自动退出。"
    }

    func close() { panel.close() }
    @objc private func cancelQuit() { cancel() }
}
