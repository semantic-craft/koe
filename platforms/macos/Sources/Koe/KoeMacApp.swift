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
            lastSyncedAppMetadata = nil
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
                resumeMicrophone: { [weak self] in self?.capture.resume() },
                openExternalURL: { url in KoeAppDelegate.openValidatedExternalURL(url) },
                revealPathInFinder: { [weak self] path in
                    let root = self?.store?.workspacePath ?? KoeMainEntry.workspacePath ?? HostSessionStore.defaultWorkspacePath()
                    KoeAppDelegate.revealLocalDirectory(path, withinWorkspace: root)
                }
            )
            if let store {
                KoeWindowPresenter.bind(
                    store: store,
                    replacing: oldValue,
                    onlyUnboundWindows: oldValue == nil
                )
                syncAppMetadataIfNeeded()
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
    private let capture = NativeCapture(source: NativeAudioSource(), systemSource: NativeSystemAudioSource())
    private let localTranscription = NativeLocalTranscription()
    private var lastLiveRecordId: String?
    private let makeDefaultStore: @MainActor () -> HostSessionStore
    private var lastSyncedInputs: [MicrophoneInput]?
    private var lastSyncedAppMetadata: (version: String, build: String)?
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

    public func syncAppMetadataIfNeeded(infoDictionary: [String: Any]? = Bundle.main.infoDictionary) {
        guard let store, store.handle != 0, let infoDictionary else { return }
        guard let rawVersion = (infoDictionary["CFBundleShortVersionString"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !rawVersion.isEmpty else {
            return
        }
        let rawBuild = (infoDictionary["CFBundleVersion"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveBuild = (rawBuild?.isEmpty == false) ? rawBuild! : AppUpdateSnapshot.defaultBuild
        if let lastSyncedAppMetadata,
           lastSyncedAppMetadata.version == rawVersion,
           lastSyncedAppMetadata.build == effectiveBuild {
            return
        }
        store.reconcileMenuSlicesIfNeeded()
        let current = store.settings.appUpdate
        lastSyncedAppMetadata = (version: rawVersion, build: effectiveBuild)
        guard rawVersion != current.currentVersion || effectiveBuild != current.currentBuild else {
            return
        }
        store.send(.syncAppMetadata(version: rawVersion, build: effectiveBuild))
    }

    #if DEBUG
    nonisolated public static let defaultAllowLoopback = true
    #else
    nonisolated public static let defaultAllowLoopback = false
    #endif

    public static func isAllowedExternalReleaseURL(
        _ url: URL,
        allowLoopback: Bool = defaultAllowLoopback
    ) -> Bool {
        guard url.user == nil, url.password == nil, url.fragment == nil else { return false }
        let rawString = url.absoluteString
        let rawBeforeQueryOrFrag = rawString.prefix { $0 != "?" && $0 != "#" }.lowercased()
        if rawBeforeQueryOrFrag.contains("\\")
            || rawBeforeQueryOrFrag.contains("%2e")
            || rawBeforeQueryOrFrag.contains("%2f")
            || rawBeforeQueryOrFrag.contains("%5c") {
            return false
        }
        let pathSegments = url.path.split(separator: "/", omittingEmptySubsequences: false)
        if pathSegments.contains(".") || pathSegments.contains("..") {
            return false
        }
        let scheme = url.scheme?.lowercased()
        let rawHost = url.host?.lowercased() ?? ""
        let host = rawHost.hasSuffix(".") ? String(rawHost.dropLast()) : rawHost
        if host == "127.0.0.1" || host == "localhost" || host == "::1" || host == "[::1]" {
            return allowLoopback && (scheme == "http" || scheme == "https")
        }
        guard scheme == "https", host == "github.com" else { return false }
        let port = url.port ?? 443
        guard port == 443 else { return false }
        let path = url.path
        return path == "/semantic-craft/koe/releases"
            || path.hasPrefix("/semantic-craft/koe/releases/")
    }

    private static func openValidatedExternalURL(_ url: URL) {
        guard isAllowedExternalReleaseURL(url) else { return }
        NSWorkspace.shared.open(url)
    }

    private static func normalizedDirectoryPath(_ url: URL) -> String {
        var path = url.path
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        return path
    }

    public static func isSafeRevealDirectory(_ path: String, withinWorkspace workspaceRoot: String) -> Bool {
        validatedRevealDirectoryURL(path, withinWorkspace: workspaceRoot) != nil
    }

    private static func validatedRevealDirectoryURL(_ path: String, withinWorkspace workspaceRoot: String) -> URL? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedRoot = workspaceRoot.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.hasPrefix("/"), !trimmed.contains("\0"),
              !trimmedRoot.isEmpty, trimmedRoot.hasPrefix("/"), !trimmedRoot.contains("\0") else {
            return nil
        }
        if trimmed.split(separator: "/").contains("..") || trimmedRoot.split(separator: "/").contains("..") {
            return nil
        }
        let fm = FileManager.default
        let stdRoot = URL(fileURLWithPath: trimmedRoot).standardizedFileURL
        let rootURL = stdRoot.resolvingSymlinksInPath()
        var rootIsDir: ObjCBool = false
        guard fm.fileExists(atPath: rootURL.path, isDirectory: &rootIsDir), rootIsDir.boolValue else { return nil }

        let stdTarget = URL(fileURLWithPath: trimmed).standardizedFileURL
        if let attrs = try? fm.attributesOfItem(atPath: stdTarget.path),
           (attrs[.type] as? FileAttributeType) == .typeSymbolicLink {
            return nil
        }
        let targetURL = stdTarget.resolvingSymlinksInPath()
        var targetIsDir: ObjCBool = false
        guard fm.fileExists(atPath: targetURL.path, isDirectory: &targetIsDir), targetIsDir.boolValue else { return nil }

        let rootPath = normalizedDirectoryPath(rootURL)
        let targetPath = normalizedDirectoryPath(targetURL)
        let rootPrefix = rootPath == "/" ? "/" : rootPath + "/"
        guard targetPath == rootPath || targetPath.hasPrefix(rootPrefix) else { return nil }

        let stdRootPath = normalizedDirectoryPath(stdRoot)
        let stdTargetPath = normalizedDirectoryPath(stdTarget)
        let stdRootPrefix = stdRootPath == "/" ? "/" : stdRootPath + "/"
        if stdTargetPath.hasPrefix(stdRootPrefix) {
            var cursor = rootURL
            for component in stdTargetPath.dropFirst(stdRootPrefix.count).split(separator: "/") {
                cursor = cursor.appendingPathComponent(String(component))
                if let attrs = try? fm.attributesOfItem(atPath: cursor.path),
                   (attrs[.type] as? FileAttributeType) == .typeSymbolicLink {
                    return nil
                }
            }
        }
        return targetURL
    }

    private static func revealLocalDirectory(_ path: String, withinWorkspace workspaceRoot: String) {
        guard let target = validatedRevealDirectoryURL(path, withinWorkspace: workspaceRoot) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([target])
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
        bluetoothBridge.shutdown()
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
        for section in HostSection.menuSections {
            let item = NSMenuItem(title: section.title, action: #selector(navigate(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = section.rawValue
            item.state = activeSection == section.rawValue ? .on : .off
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
        let appUpdate = store?.settings.appUpdate ?? .empty
        let versionItem = NSMenuItem(title: appUpdate.compactMenuVersionLabel, action: nil, keyEquivalent: "")
        versionItem.isEnabled = false
        menu.addItem(versionItem)
        let updateTitle: String
        if appUpdate.isChecking {
            updateTitle = "正在检查更新…"
        } else if appUpdate.isUpdateAvailable, let latest = appUpdate.latestVersion, !latest.isEmpty {
            updateTitle = "检查更新…（新版本 v\(latest)）"
        } else {
            updateTitle = "检查更新…"
        }
        let isQuitting = store?.lifecycle.map { $0.quitPhase != "running" } ?? false
        let checkUpdateItem = NSMenuItem(title: updateTitle, action: #selector(checkForUpdatesFromMenu), keyEquivalent: "")
        checkUpdateItem.target = self
        checkUpdateItem.isEnabled = !appUpdate.isChecking && !isQuitting
        menu.addItem(checkUpdateItem)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出 Koe", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }
    @objc private func navigate(_ item: NSMenuItem) {
        if let section = item.representedObject as? String { store?.send(.navigate(section: section)) }
        KoeWindowPresenter.presentPrimaryWorkspaceWindow()
    }
    public func requestUpdateCheck() {
        let activeStore = ensureSessionStore()
        activeStore.reconcileMenuSlicesIfNeeded()
        if let quitPhase = activeStore.lifecycle?.quitPhase, quitPhase != "running" {
            activeStore.send(.checkAppUpdate)
            return
        }
        activeStore.requestUpdatePopoverPresentation()
        activeStore.send(.checkAppUpdate)
    }
    @objc public func checkForUpdatesFromMenu() {
        KoeWindowPresenter.presentPrimaryWorkspaceWindow()
        requestUpdateCheck()
    }
    @objc public func showAboutPanel() {
        let activeStore = ensureSessionStore()
        activeStore.reconcileMenuSlicesIfNeeded()
        let appUpdate = activeStore.settings.appUpdate
        NSApp?.activate(ignoringOtherApps: true)
        NSApp?.orderFrontStandardAboutPanel(options: [
            .applicationName: "Koe",
            .applicationVersion: appUpdate.currentVersion,
            .version: appUpdate.currentBuild
        ])
    }
    func prepareManualScan() {
        store?.send(.deviceOpenGuide)
    }
    func handleBleScanRequest() {
        bluetoothBridge.requestScan()
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
                onExportRecords: { appDelegate.files.exportRecords($0) },
                onExportWorkspace: { appDelegate.files.exportWorkspace($0) }
            )
            .onAppear {
                KoeWindowPresenter.presentPrimaryWorkspaceWindow()
            }
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("关于 Koe") {
                    appDelegate.showAboutPanel()
                }
                Divider()
                Button("检查更新…") {
                    appDelegate.checkForUpdatesFromMenu()
                }
            }
        }
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
