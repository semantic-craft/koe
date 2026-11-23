import AppKit
import Foundation
import KoeMacUI
import Testing
@testable import Koe

private final class SimulatedMiniaturizedWindow: NSWindow {
    var simulatedMiniaturized = false

    override var isMiniaturized: Bool {
        simulatedMiniaturized || super.isMiniaturized
    }

    override func deminiaturize(_ sender: Any?) {
        if !simulatedMiniaturized {
            super.deminiaturize(sender)
        }
    }
}

private final class ReentrantCoreAudioPropertyListener: CoreAudioPropertyListening, @unchecked Sendable {
    private let lock = NSLock()
    private var callback: (@Sendable () -> Void)?
    private var listenerQueue: DispatchQueue?
    private(set) var activeListeners = 0
    private(set) var startCalls = 0
    private(set) var stopCalls = 0
    var onStartListeningHook: (() -> Void)?

    func startListening(queue: DispatchQueue, onPropertyChanged: @escaping @Sendable () -> Void) {
        let hook: (() -> Void)?
        lock.lock()
        hook = onStartListeningHook
        lock.unlock()
        hook?()
        lock.lock()
        startCalls += 1
        activeListeners += 1
        listenerQueue = queue
        callback = onPropertyChanged
        lock.unlock()
    }

    func stopListening(queue: DispatchQueue) {
        lock.lock()
        stopCalls += 1
        if activeListeners > 0 {
            activeListeners -= 1
        }
        callback = nil
        listenerQueue = nil
        lock.unlock()
    }

    func firePropertyChange() {
        lock.lock()
        let handler = callback
        let queue = listenerQueue
        lock.unlock()
        if let queue, let handler {
            queue.async { handler() }
        } else {
            handler?()
        }
    }

    var currentActiveListeners: Int {
        lock.lock()
        defer { lock.unlock() }
        return activeListeners
    }
}

extension SerializedMacHostSuites {
@Suite("Post-interrogate hardening regressions for window presenter and CoreAudio monitor", .serialized)
struct HardeningRegressionTests {
    @MainActor
    private func waitUntil(
        timeoutSeconds: Double = 2.0,
        predicate: @MainActor () -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now + .milliseconds(Int(timeoutSeconds * 1000))
        while !predicate(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        return predicate()
    }

    @Test("KoeWindowPresenter keeps slices active during deminiaturize, excludes modal sheets and untracked foreign windows, and rebinds tracked windows on store swap")
    @MainActor
    func windowPresenterDeminiaturizeSheetForeignAndRebindInvariants() throws {
        let root1 = FileManager.default.temporaryDirectory.appendingPathComponent("koe-win-hardening-1-\(UUID().uuidString)")
        let root2 = FileManager.default.temporaryDirectory.appendingPathComponent("koe-win-hardening-2-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root1, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root2, withIntermediateDirectories: true)
        let store1 = HostSessionStore(workspacePath: root1.path)
        let store2 = HostSessionStore(workspacePath: root2.path)

        let frame = NSRect(x: -16000, y: -16000, width: 960, height: 640)
        let workspaceWindow = SimulatedMiniaturizedWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        workspaceWindow.alphaValue = 0
        workspaceWindow.collectionBehavior = [.ignoresCycle, .transient]

        let sheetWindow = NSWindow(
            contentRect: NSRect(x: -16000, y: -16000, width: 420, height: 260),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        sheetWindow.isReleasedWhenClosed = false
        sheetWindow.alphaValue = 0

        let docModalWindow = NSWindow(
            contentRect: NSRect(x: -16000, y: -16000, width: 420, height: 260),
            styleMask: [.titled, .docModalWindow],
            backing: .buffered,
            defer: false
        )
        docModalWindow.isReleasedWhenClosed = false

        let foreignWindow = NSWindow(
            contentRect: NSRect(x: -16000, y: -16000, width: 320, height: 200),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        foreignWindow.isReleasedWhenClosed = true

        defer {
            if workspaceWindow.attachedSheet != nil {
                workspaceWindow.endSheet(sheetWindow)
            }
            sheetWindow.orderOut(nil)
            docModalWindow.orderOut(nil)
            foreignWindow.orderOut(nil)
            workspaceWindow.orderOut(nil)
            KoeWindowPresenter.bind(store: nil)
            store1.shutdown()
            store2.shutdown()
            try? FileManager.default.removeItem(at: root1)
            try? FileManager.default.removeItem(at: root2)
        }

        KoeWindowPresenter.bind(store: store1)
        KoeWindowPresenter.presentWindow(workspaceWindow, activateApp: false)
        #expect(store1.isUISlicesActive)

        #expect(!KoeWindowPresenter.isWorkspaceWindow(docModalWindow))
        workspaceWindow.beginSheet(sheetWindow)
        #expect(sheetWindow.sheetParent === workspaceWindow)
        #expect(!KoeWindowPresenter.isWorkspaceWindow(sheetWindow))
        workspaceWindow.endSheet(sheetWindow)
        #expect(store1.isUISlicesActive)

        #expect(foreignWindow.isReleasedWhenClosed)
        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: foreignWindow)
        #expect(foreignWindow.isReleasedWhenClosed)
        #expect(store1.isUISlicesActive)

        workspaceWindow.simulatedMiniaturized = true
        NotificationCenter.default.post(name: NSWindow.didMiniaturizeNotification, object: workspaceWindow)
        #expect(!store1.isUISlicesActive)

        KoeWindowPresenter.presentWindow(workspaceWindow, activateApp: false)
        #expect(workspaceWindow.isMiniaturized)
        #expect(store1.isUISlicesActive)
        workspaceWindow.simulatedMiniaturized = false
        NotificationCenter.default.post(name: NSWindow.didDeminiaturizeNotification, object: workspaceWindow)
        #expect(store1.isUISlicesActive)

        KoeWindowPresenter.bind(store: store2)
        #expect(store2.isUISlicesActive)
        workspaceWindow.close()
        #expect(!store2.isUISlicesActive)
    }

    @Test("CoreAudioInputMonitor preserves mid-debounce HAL updates across overlapping syncs, bumps generation on restart, and leaves zero active listeners on re-entrant stop")
    @MainActor
    func coreAudioInputMonitorMidDebounceRestartAndReentrantStopInvariants() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("koe-audio-hardening-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = HostSessionStore(workspacePath: root.path)
        let listener = ReentrantCoreAudioPropertyListener()
        let monitor = CoreAudioInputMonitor(listener: listener, debounceInterval: .milliseconds(35))

        let builtIn = MicrophoneInput(id: "built-in", name: "MacBook Pro 麦克风", transport: "built_in", isDefault: true)
        let builtInSecondary = MicrophoneInput(id: "built-in", name: "MacBook Pro 麦克风", transport: "built_in", isDefault: false)
        let usbMic = MicrophoneInput(id: "usb-mic", name: "Shure MV7", transport: "usb", isDefault: true)
        let btMic = MicrophoneInput(id: "bt-mic", name: "AirPods Pro", transport: "bluetooth", isDefault: true)
        var simulatedInputs = [builtIn]

        let delegate = KoeAppDelegate(
            playback: NativePlayback(),
            audioInputMonitor: monitor,
            defaultInputsProvider: { simulatedInputs }
        )
        defer {
            delegate.store = nil
            store.shutdown()
            try? FileManager.default.removeItem(at: root)
        }

        delegate.store = store
        #expect(store.snapshot.capture.inputs.map(\.id) == ["built-in"])

        simulatedInputs = [builtInSecondary, usbMic]
        listener.firePropertyChange()
        try? await Task.sleep(for: .milliseconds(5))
        delegate.syncAudioInputsIfNeeded(force: true, inputsProvider: { [builtIn] })
        #expect(store.snapshot.capture.inputs.map(\.id) == ["built-in"])

        let settledAfterMidDebounce = await waitUntil(timeoutSeconds: 1.5) {
            store.snapshot.capture.inputs.map(\.id) == ["usb-mic", "built-in"]
        }
        #expect(settledAfterMidDebounce)

        let genBeforeStop = monitor.currentChangeGeneration
        monitor.stop()
        #expect(listener.currentActiveListeners == 0)
        simulatedInputs = [btMic, builtInSecondary]
        monitor.start { [weak delegate] in
            delegate?.syncAudioInputsIfNeeded()
        }
        #expect(monitor.currentChangeGeneration > genBeforeStop)
        delegate.syncAudioInputsIfNeeded(force: false)
        #expect(store.snapshot.capture.inputs.map(\.id) == ["bt-mic", "built-in"])

        let reentrantListener = ReentrantCoreAudioPropertyListener()
        let reentrantMonitor = CoreAudioInputMonitor(listener: reentrantListener, debounceInterval: .milliseconds(20))
        reentrantListener.onStartListeningHook = { [weak reentrantMonitor] in
            reentrantMonitor?.stop()
        }
        reentrantMonitor.start {}
        #expect(reentrantListener.currentActiveListeners == 0)
    }
}
}
