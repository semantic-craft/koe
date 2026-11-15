import AppKit
import Foundation
import KoeAppleShared
import SwiftUI

@MainActor
public enum KoeWindowPresenter {
    private static var cachedWorkspaceWindow: NSWindow?

    public static func isWorkspaceWindow(_ window: NSWindow) -> Bool {
        let className = String(describing: type(of: window))
        if className.contains("StatusBar") || className.contains("Popup") || window is NSPanel {
            return false
        }
        return window.styleMask.contains(.titled) || window.styleMask.contains(.closable)
    }

    public static func rememberWindow(_ window: NSWindow?) {
        guard let window, isWorkspaceWindow(window) else { return }
        window.isReleasedWhenClosed = false
        cachedWorkspaceWindow = window
    }

    public static func presentWindow(_ window: NSWindow?) {
        guard let window else { return }
        rememberWindow(window)
        if let app = NSApp, app.activationPolicy() != .regular {
            _ = app.setActivationPolicy(.regular)
        }
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        NSApp?.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    public static func presentPrimaryWorkspaceWindow() {
        if let app = NSApp, app.activationPolicy() != .regular {
            _ = app.setActivationPolicy(.regular)
        }
        NSApp?.activate(ignoringOtherApps: true)
        let target = NSApp?.windows.first(where: { isWorkspaceWindow($0) && $0.isVisible })
            ?? NSApp?.windows.first(where: { isWorkspaceWindow($0) })
            ?? cachedWorkspaceWindow
        if let target {
            presentWindow(target)
        }
    }

}

@MainActor
public final class KoeAppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    public var store: HostSessionStore? {
        didSet {
            oldValue?.onSnapshotChanged = nil
            lastSyncedInputs = nil
            inputSyncTickCounter = 0
            bluetoothBridge.store = store
            files.store = store
            playback.store = store
            capture.store = store
            localTranscription.store = store
            lastLiveRecordId = nil
            store?.onSnapshotChanged = { [weak self] snapshot in self?.applyLifecycle(snapshot) }
            if let store {
                syncAudioInputsIfNeeded(force: true)
                applyLifecycle(store.snapshot)
            }
        }
    }
    public let bluetoothBridge = BluetoothBridge()
    let files = NativeFileActions()
    private let playback: NativePlayback
    private let capture = NativeCapture()
    private let hostActions = NativeHostActions()
    private let localTranscription = NativeLocalTranscription()
    private var lastLiveRecordId: String?
    private let makeDefaultStore: @MainActor () -> HostSessionStore
    private var lastSyncedInputs: [MicrophoneInput]?
    private var inputSyncTickCounter: UInt8 = 0

    public override convenience init() {
        self.init(playback: NativePlayback())
    }

    convenience init(makeDefaultStore: @escaping @MainActor () -> HostSessionStore) {
        self.init(playback: NativePlayback(), makeDefaultStore: makeDefaultStore)
    }

    init(
        playback: NativePlayback,
        makeDefaultStore: @escaping @MainActor () -> HostSessionStore = { KoeAppDelegate.createDefaultStore() }
    ) {
        self.playback = playback
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
        NotificationCenter.default.addObserver(self, selector: #selector(releaseBleControl), name: Notification.Name("KoeReleaseBleControl"), object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(flushBle), name: Notification.Name("KoeFlushBleOutbound"), object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(rememberWindow(_:)), name: NSWindow.didBecomeKeyNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(rememberWindow(_:)), name: NSWindow.willCloseNotification, object: nil)
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
        inputSyncTickCounter = (inputSyncTickCounter + 1) % 4
        if inputSyncTickCounter == 0 {
            syncAudioInputsIfNeeded()
        }
        store?.pollTimers(elapsedMs: elapsed)
        bluetoothBridge.flushOutboundFrames()
        playback.tick()
        capture.apply()
        localTranscription.apply()
    }

    public func syncAudioInputsIfNeeded(
        force: Bool = false,
        inputsProvider: () -> [MicrophoneInput] = NativeAudioSource.inputs
    ) {
        guard let store, store.handle != 0 else { return }
        let current = Array(inputsProvider().prefix(64))
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
    @objc private func rememberWindow(_ notification: Notification) {
        KoeWindowPresenter.rememberWindow(notification.object as? NSWindow)
    }
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
        if let store { hostActions.apply(to: store) }
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
        let status = NSMenuItem(title: store?.snapshot.device.state ?? "未连接录音豆", action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())
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
            item.state = store?.snapshot.section == id ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let scanItem = NSMenuItem(title: "查找录音豆", action: #selector(scan), keyEquivalent: "")
        scanItem.target = self
        menu.addItem(scanItem)
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
        if store?.snapshot.device.autoConnect == false {
            store?.send("set_ble_auto_connect", ["enabled": true])
        }
        store?.send("device_open_guide")
    }
    @objc private func scan() {
        prepareManualScan()
        bluetoothBridge.startScanningIfPoweredOn()
        KoeWindowPresenter.presentPrimaryWorkspaceWindow()
    }
    @objc private func disconnectBle() { bluetoothBridge.disconnect() }
    @objc private func releaseBleControl() { bluetoothBridge.releaseControl() }
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
                onExport: { appDelegate.files.exportRecord($0) }
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
