import AppKit
import Foundation
import KoeAppleShared
import SwiftUI

@MainActor
public final class KoeAppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    public var store: HostSessionStore? {
        didSet {
            oldValue?.onSnapshotChanged = nil
            oldValue?.bridgeActions = HostBridgeActions()
            if let oldValue, oldValue !== store {
                oldValue.shutdown()
            }
            lastSyncedInputs = nil
            lastObservedHardwareGeneration = 0
            bluetoothBridge.store = store
            files.store = store
            playback.store = store
            capture.store = store
            localTranscription.store = store
            lastLiveRecordId = nil
            store?.onSnapshotChanged = { [weak self] snapshot in
                self?.applyLifecycle(device: snapshot.device, lifecycle: snapshot.lifecycle)
            }
            store?.bridgeActions = HostBridgeActions(
                requestBleScan: { [weak self] in self?.handleBleScanRequest() },
                flushBleOutbound: { [weak self] in self?.bluetoothBridge.flushOutboundFrames() },
                resumeMicrophone: { [weak self] in self?.capture.resume() }
            )
            if let store {
                KoeWindowPresenter.bind(store: store, onlyUnboundWindows: oldValue == nil)
                audioInputMonitor.start { [weak self] in
                    self?.syncAudioInputsIfNeeded()
                }
                syncAudioInputsIfNeeded(force: true)
                store.reconcileMenuSlicesIfNeeded()
                applyLifecycle(device: store.device, lifecycle: store.lifecycle)
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
        let descriptors = current.map {
            HostAudioInputDescriptor(id: $0.id, name: $0.name, transport: $0.transport, isDefault: $0.isDefault)
        }
        store.send(.syncAudioInputs(inputs: descriptors))
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        KoeWindowPresenter.presentPrimaryWorkspaceWindow()
        return true
    }
    private func applyLifecycle(device: DeviceSnapshot, lifecycle current: LifecycleSnapshot?) {
        let liveRecordId = device.liveRecordId
        if let liveRecordId, liveRecordId != lastLiveRecordId {
            KoeWindowPresenter.presentPrimaryWorkspaceWindow()
        }
        lastLiveRecordId = liveRecordId
        bluetoothBridge.syncWithRuntimeDevice(device)
        bluetoothBridge.flushOutboundFrames()
        playback.tick()
        capture.apply()
        lifecycle.apply(current)
        quitPanel?.update(current)
    }
    public func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let store, store.handle != 0 else { return .terminateNow }
        store.reconcileMenuSlicesIfNeeded()
        if quitPanel != nil { return .terminateLater }
        let result = lifecycle.request()
        bluetoothBridge.flushOutboundFrames()
        if result == .terminateLater {
            let panel = NativeQuitPanel { [weak self] in self?.lifecycle.cancel() }
            quitPanel = panel
            panel.show(store.lifecycle)
        }
        return result
    }
    public func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
        timer = nil
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
        if let section = item.representedObject as? String { store?.send(.navigate(section: section)) }
        KoeWindowPresenter.presentPrimaryWorkspaceWindow()
    }
    func prepareManualScan() {
        store?.send(.deviceOpenGuide)
    }
    func handleBleScanRequest() {
        store?.reconcileMenuSlicesIfNeeded()
        if store?.device.autoConnect == false {
            store?.send(.setBleAutoConnect(enabled: true))
        }
        bluetoothBridge.startScanningIfPoweredOn()
    }
    @objc private func scanFromMenu() {
        prepareManualScan()
        bluetoothBridge.startScanningIfPoweredOn()
        KoeWindowPresenter.presentPrimaryWorkspaceWindow()
    }
    @objc private func releaseBleControl() { store?.send(.deviceRelease) }
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
