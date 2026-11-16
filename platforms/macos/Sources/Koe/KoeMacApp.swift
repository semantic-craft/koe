import AppKit
import Foundation
import KoeAppleShared
import SwiftUI

private struct UncheckedWindowBox: @unchecked Sendable {
    let window: NSWindow
}

@MainActor
public enum KoeWindowPresenter {
    private static var cachedWorkspaceWindow: NSWindow?
    private static weak var boundStore: HostSessionStore?
    private static let trackedWindows = NSHashTable<NSWindow>.weakObjects()
    private static let miniaturizedWindows = NSHashTable<NSWindow>.weakObjects()
    private static let deminiaturizingWindows = NSHashTable<NSWindow>.weakObjects()
    private static let windowStores = NSMapTable<NSWindow, HostSessionStore>.weakToWeakObjects()
    private static var observersInstalled = false

    public static func isWorkspaceWindow(_ window: NSWindow) -> Bool {
        guard window.sheetParent == nil, !window.styleMask.contains(.docModalWindow) else { return false }
        let className = String(describing: type(of: window))
        if className.contains("StatusBar") || className.contains("Popup") || window is NSPanel {
            return false
        }
        return window.styleMask.contains(.titled) || window.styleMask.contains(.closable)
    }

    private static func registerWorkspaceWindow(_ window: NSWindow) -> HostSessionStore? {
        window.isReleasedWhenClosed = false
        cachedWorkspaceWindow = window
        trackedWindows.add(window)
        if windowStores.object(forKey: window) == nil, let boundStore {
            windowStores.setObject(boundStore, forKey: window)
        }
        return windowStores.object(forKey: window) ?? boundStore
    }

    public static func bind(store: HostSessionStore?, onlyUnboundWindows: Bool = false) {
        installObserversIfNeeded()
        boundStore = store
        guard let store else { return }
        if let cached = cachedWorkspaceWindow, isWorkspaceWindow(cached) {
            trackedWindows.add(cached)
        }
        var ownsAnyWindow = false
        for win in trackedWindows.allObjects where isWorkspaceWindow(win) {
            let existing = windowStores.object(forKey: win)
            guard !onlyUnboundWindows || existing == nil || existing?.handle == 0 || existing === store else {
                continue
            }
            ownsAnyWindow = true
            win.isReleasedWhenClosed = false
            windowStores.setObject(store, forKey: win)
            if win.isMiniaturized {
                miniaturizedWindows.add(win)
            } else {
                miniaturizedWindows.remove(win)
            }
        }
        if ownsAnyWindow {
            recomputeUISlicesActive(for: store, closingWindow: nil)
        }
    }

    static func unbind(store: HostSessionStore?) {
        if let store, boundStore === store {
            boundStore = nil
        }
    }

    public static func rememberWindow(_ window: NSWindow?) {
        installObserversIfNeeded()
        guard let window, isWorkspaceWindow(window) else { return }
        let targetStore = registerWorkspaceWindow(window)
        if window.isMiniaturized {
            miniaturizedWindows.add(window)
        } else {
            miniaturizedWindows.remove(window)
        }
        if let targetStore { recomputeUISlicesActive(for: targetStore, closingWindow: nil) }
    }

    public static func presentWindow(_ window: NSWindow?, activateApp: Bool = true) {
        guard let window else { return }
        installObserversIfNeeded()
        if isWorkspaceWindow(window) {
            let targetStore = registerWorkspaceWindow(window)
            miniaturizedWindows.remove(window)
            if window.isMiniaturized { deminiaturizingWindows.add(window) }
            targetStore?.setUISlicesActive(true)
        }
        if window.isMiniaturized { window.deminiaturize(nil) }
        if activateApp {
            if let app = NSApp, app.activationPolicy() != .regular {
                _ = app.setActivationPolicy(.regular)
            }
            NSApp?.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
        } else {
            window.orderBack(nil)
        }
    }

    public static func presentPrimaryWorkspaceWindow() {
        if let app = NSApp, app.activationPolicy() != .regular {
            _ = app.setActivationPolicy(.regular)
        }
        NSApp?.activate(ignoringOtherApps: true)
        let target = NSApp?.windows.first(where: { isWorkspaceWindow($0) && $0.isVisible })
            ?? (cachedWorkspaceWindow.flatMap { isWorkspaceWindow($0) ? $0 : nil })
            ?? NSApp?.windows.first(where: { isWorkspaceWindow($0) })
        if let target { presentWindow(target) }
    }

    private static func installObserversIfNeeded() {
        guard !observersInstalled else { return }
        observersInstalled = true
        let names = [
            NSWindow.didBecomeKeyNotification,
            NSWindow.didBecomeMainNotification,
            NSWindow.didDeminiaturizeNotification,
            NSWindow.didMiniaturizeNotification,
            NSWindow.willCloseNotification
        ]
        for name in names {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { notification in
                if Thread.isMainThread {
                    MainActor.assumeIsolated {
                        handleWindowEvent(name: notification.name, window: notification.object as? NSWindow)
                    }
                } else {
                    let windowBox = (notification.object as? NSWindow).map(UncheckedWindowBox.init)
                    let notifName = notification.name
                    Task { @MainActor in handleWindowEvent(name: notifName, window: windowBox?.window) }
                }
            }
        }
    }

    private static func handleWindowEvent(name: Notification.Name, window: NSWindow?) {
        guard let window else { return }
        if name == NSWindow.willCloseNotification {
            guard trackedWindows.contains(window) else { return }
        }
        guard isWorkspaceWindow(window), let targetStore = registerWorkspaceWindow(window) else { return }
        switch name {
        case NSWindow.willCloseNotification:
            deminiaturizingWindows.remove(window)
            miniaturizedWindows.remove(window)
            recomputeUISlicesActive(for: targetStore, closingWindow: window)
        case NSWindow.didMiniaturizeNotification:
            deminiaturizingWindows.remove(window)
            miniaturizedWindows.add(window)
            recomputeUISlicesActive(for: targetStore, closingWindow: nil)
        case NSWindow.didDeminiaturizeNotification:
            deminiaturizingWindows.remove(window)
            miniaturizedWindows.remove(window)
            recomputeUISlicesActive(for: targetStore, closingWindow: nil)
        default:
            miniaturizedWindows.remove(window)
            recomputeUISlicesActive(for: targetStore, closingWindow: nil)
        }
    }

    private static func recomputeUISlicesActive(for store: HostSessionStore, closingWindow: NSWindow?) {
        let windows = trackedWindows.allObjects.filter {
            isWorkspaceWindow($0) && (windowStores.object(forKey: $0) ?? boundStore) === store
        }
        guard !windows.isEmpty else { return }
        let anyActive = windows.contains { window in
            window !== closingWindow
                && (window.isVisible || deminiaturizingWindows.contains(window))
                && !miniaturizedWindows.contains(window)
        }
        store.setUISlicesActive(anyActive)
    }
}

@MainActor
public final class KoeAppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    public var store: HostSessionStore? {
        didSet {
            oldValue?.onSnapshotChanged = nil
            lastSyncedInputs = nil
            lastObservedHardwareGeneration = 0
            bluetoothBridge.store = store
            files.store = store
            playback.store = store
            capture.store = store
            localTranscription.store = store
            lastLiveRecordId = nil
            store?.onSnapshotChanged = { [weak self] snapshot in self?.applyLifecycle(snapshot) }
            if let store {
                KoeWindowPresenter.bind(store: store, onlyUnboundWindows: oldValue == nil)
                audioInputMonitor.start { [weak self] in
                    self?.syncAudioInputsIfNeeded()
                }
                syncAudioInputsIfNeeded(force: true)
                applyLifecycle(store.snapshot)
            } else {
                KoeWindowPresenter.unbind(store: oldValue)
                audioInputMonitor.stop()
            }
        }
    }
    public let bluetoothBridge = BluetoothBridge()
    let files = NativeFileActions()
    private let playback: NativePlayback
    private let audioInputMonitor: CoreAudioInputMonitor
    private let defaultInputsProvider: () -> [MicrophoneInput]
    private let capture = NativeCapture()
    private let localTranscription = NativeLocalTranscription()
    private var lastLiveRecordId: String?
    private let makeDefaultStore: @MainActor () -> HostSessionStore
    private var lastSyncedInputs: [MicrophoneInput]?
    private var lastObservedHardwareGeneration: UInt64 = 0

    public override convenience init() {
        self.init(playback: NativePlayback())
    }

    convenience init(makeDefaultStore: @escaping @MainActor () -> HostSessionStore) {
        self.init(playback: NativePlayback(), makeDefaultStore: makeDefaultStore)
    }

    init(
        playback: NativePlayback,
        audioInputMonitor: CoreAudioInputMonitor = CoreAudioInputMonitor(),
        defaultInputsProvider: @escaping () -> [MicrophoneInput] = NativeAudioSource.inputs,
        makeDefaultStore: @escaping @MainActor () -> HostSessionStore = { KoeAppDelegate.createDefaultStore() }
    ) {
        self.playback = playback
        self.audioInputMonitor = audioInputMonitor
        self.defaultInputsProvider = defaultInputsProvider
        self.makeDefaultStore = makeDefaultStore
        super.init()
    }

    private static func createDefaultStore() -> HostSessionStore {
        HostSessionStore(
            workspacePath: KoeMainEntry.workspacePath,
            credentials: NativeCredentials(workspaceOverride: KoeMainEntry.workspacePath != nil)
        )
    }

    @discardableResult
    public func ensureSessionStore() -> HostSessionStore {
        if let store { return store }
        let initialized = makeDefaultStore()
        store = initialized
        return initialized
    }
    private lazy var lifecycle = NativeQuitCoordinator(
        send: { [weak self] in self?.store?.send($0) },
        reply: { [weak self] allowed in
            self?.quitPanel?.close()
            self?.quitPanel = nil
            NSApp?.reply(toApplicationShouldTerminate: allowed)
        }
    )
    private var quitPanel: NativeQuitPanel?
    private var statusItem: NSStatusItem?
    private var timer: Timer?
    private var lastTick = ProcessInfo.processInfo.systemUptime

    public func applicationDidFinishLaunching(_ notification: Notification) {
        _ = ensureSessionStore()
        bluetoothBridge.activateHost()
        NSApp?.applicationIconImage = NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "Koe"
        item.menu = buildStatusMenu()
        statusItem = item
        NotificationCenter.default.addObserver(self, selector: #selector(scan), name: Notification.Name("KoeRequestBleScan"), object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(disconnectBle), name: Notification.Name("KoeRequestBleDisconnect"), object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(flushBle), name: Notification.Name("KoeFlushBleOutbound"), object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(resumeMicrophone), name: Notification.Name("KoeResumeMicrophone"), object: nil)
        lastTick = ProcessInfo.processInfo.systemUptime
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
        KoeWindowPresenter.presentPrimaryWorkspaceWindow()
    }

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = UInt64(max(0, now - lastTick) * 1000)
        lastTick = now
        store?.pollTimers(elapsedMs: elapsed)
        bluetoothBridge.flushOutboundFrames()
        playback.tick()
        capture.apply()
        localTranscription.apply()
    }

    public func syncAudioInputsIfNeeded(
        force: Bool = false,
        inputsProvider: (() -> [MicrophoneInput])? = nil
    ) {
        guard let store, store.handle != 0 else { return }
        let observedGeneration = audioInputMonitor.currentChangeGeneration
        if !force, inputsProvider == nil, lastSyncedInputs != nil, observedGeneration == lastObservedHardwareGeneration {
            return
        }
        if inputsProvider == nil {
            lastObservedHardwareGeneration = observedGeneration
        }
        let current = Array((inputsProvider ?? defaultInputsProvider)().prefix(64))
        guard force || lastSyncedInputs != current else { return }
        lastSyncedInputs = current
        let payload: [[String: Any]] = current.map { input in
            [
                "id": input.id,
                "name": input.name,
                "transport": input.transport,
                "isDefault": input.isDefault
            ]
        }
        store.send("sync_audio_inputs", ["inputs": payload])
    }

    @objc private func resumeMicrophone() { capture.resume() }
    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        KoeWindowPresenter.presentPrimaryWorkspaceWindow()
        return true
    }
    private func applyLifecycle(_ snapshot: HostSnapshot) {
        let liveRecordId = snapshot.device.liveRecordId
        if let liveRecordId, liveRecordId != lastLiveRecordId {
            KoeWindowPresenter.presentPrimaryWorkspaceWindow()
        }
        lastLiveRecordId = liveRecordId
        bluetoothBridge.syncWithRuntimeDevice(store?.snapshot.device ?? snapshot.device)
        playback.tick()
        capture.apply()
        let current = store?.snapshot.lifecycle ?? snapshot.lifecycle
        lifecycle.apply(current)
        quitPanel?.update(current)
    }
    public func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let store, store.handle != 0 else { return .terminateNow }
        if quitPanel != nil { return .terminateLater }
        let result = lifecycle.request()
        bluetoothBridge.flushOutboundFrames()
        if result == .terminateLater {
            let panel = NativeQuitPanel { [weak self] in self?.lifecycle.cancel() }
            quitPanel = panel
            panel.show(store.snapshot.lifecycle)
        }
        return result
    }
    public func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
        audioInputMonitor.stop()
        playback.stop()
        lifecycle.shutdown()
        localTranscription.shutdown()
        store?.shutdown()
    }
    public func applicationDockMenu(_ sender: NSApplication) -> NSMenu? { buildStatusMenu() }
    public func menuNeedsUpdate(_ menu: NSMenu) { populate(menu) }
    public func buildStatusMenu() -> NSMenu {
        let menu = NSMenu(title: "Koe")
        menu.delegate = self
        populate(menu)
        return menu
    }
    private func populate(_ menu: NSMenu) {
        menu.removeAllItems()
        store?.reconcileMenuSlicesIfNeeded()
        let device = store?.device
        let picker = store?.today.picker
        let isPhoneOwner = picker?.beanControlOwner == "phone"
        let statusTitle = isPhoneOwner ? "录音豆：已让出给手机" : (device?.state ?? "未连接录音豆")
        let status = NSMenuItem(title: statusTitle, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())
        let activeSection = store?.navigation.section
        for (id, title) in [
            ("today", "模式选择"),
            ("notes", "随心闪记"),
            ("all_day", "全天听记"),
            ("live_minutes", "实时纪要"),
            ("voice_input", "语音输入"),
            ("ask", "问 AI"),
            ("records", "所有记录"),
            ("tasks", "行动"),
            ("settings", "设置")
        ] {
            let item = NSMenuItem(title: title, action: #selector(navigate(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = id
            item.state = activeSection == id ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        if isPhoneOwner {
            let reconnectItem = NSMenuItem(title: "连回 Mac 录音豆", action: #selector(scanFromMenu), keyEquivalent: "")
            reconnectItem.target = self
            menu.addItem(reconnectItem)
        } else {
            let scanItem = NSMenuItem(title: "查找录音豆", action: #selector(scanFromMenu), keyEquivalent: "")
            scanItem.target = self
            menu.addItem(scanItem)
            let handoffItem = NSMenuItem(title: "切回手机（释放控制权）", action: #selector(releaseBleControl), keyEquivalent: "")
            handoffItem.target = self
            handoffItem.isEnabled = store?.canReleaseToPhone ?? (device?.transferPhase != "pulling_offline")
            menu.addItem(handoffItem)
        }
        let open = NSMenuItem(title: "打开 Koe", action: #selector(openWindow), keyEquivalent: "o")
        open.target = self
        menu.addItem(open)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出 Koe", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }
    @objc private func navigate(_ item: NSMenuItem) {
        if let section = item.representedObject as? String { store?.send("navigate", ["section": section]) }
        KoeWindowPresenter.presentPrimaryWorkspaceWindow()
    }
    func prepareManualScan() {
        store?.send(.deviceOpenGuide)
    }
    func handleBleScanRequest() {
        if store?.device.autoConnect == false {
            store?.send(.setBleAutoConnect(enabled: true))
        }
        bluetoothBridge.startScanningIfPoweredOn()
    }
    @objc private func scan() {
        handleBleScanRequest()
    }
    @objc private func scanFromMenu() {
        prepareManualScan()
        bluetoothBridge.startScanningIfPoweredOn()
        KoeWindowPresenter.presentPrimaryWorkspaceWindow()
    }
    @objc private func disconnectBle() { bluetoothBridge.disconnect() }
    @objc private func releaseBleControl() { store?.send(.deviceRelease) }
    @objc private func flushBle() { bluetoothBridge.flushOutboundFrames() }
    @objc private func openWindow() { KoeWindowPresenter.presentPrimaryWorkspaceWindow() }
    @objc private func quit() { NSApp?.terminate(nil) }
}

struct KoeNativeSceneApp: App {
    @NSApplicationDelegateAdaptor(KoeAppDelegate.self) private var appDelegate
    var body: some Scene {
        WindowGroup("Koe") {
            KoeWorkspaceRootView(
                store: appDelegate.ensureSessionStore(),
                onImport: { appDelegate.files.importFile() },
                onExport: { appDelegate.files.exportRecord($0) },
                onExportWorkspace: { appDelegate.files.exportWorkspace($0) }
            )
            .onAppear {
                KoeWindowPresenter.presentPrimaryWorkspaceWindow()
            }
        }
        .windowResizability(.contentMinSize)
    }
}

@main
public enum KoeMainEntry {
    @MainActor static var workspacePath: String?
    @MainActor
    public static func main() {
        let args = CommandLine.arguments
        if args.contains("--verify-self") { exit(KoeSelfCheckRunner.runVerifySelf()) }
        if args.contains("--smoke-test") { exit(KoeSelfCheckRunner.runSmokeTest()) }
        if let index = args.firstIndex(of: "--workspace-root") {
            guard args.indices.contains(index + 1), args[index + 1].hasPrefix("/") else {
                fputs("--workspace-root requires an absolute directory path\n", stderr)
                exit(2)
            }
            workspacePath = args[index + 1]
        }
        KoeNativeSceneApp.main()
    }
}
