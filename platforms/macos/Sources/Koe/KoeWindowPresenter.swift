import AppKit
import Foundation
import KoeAppleShared

@MainActor
public enum KoeWindowPresenter {
    private static var cachedWorkspaceWindow: NSWindow?
    private static weak var boundStore: HostSessionStore?
    private static let trackedWindows = NSHashTable<NSWindow>.weakObjects()
    private static let miniaturizedWindows = NSHashTable<NSWindow>.weakObjects()
    private static let deminiaturizingWindows = NSHashTable<NSWindow>.weakObjects()
    private static let windowStores = NSMapTable<NSWindow, HostSessionStore>.weakToWeakObjects()
    private static var observers: [NSObjectProtocol] = []

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

    public static func bind(
        store: HostSessionStore?,
        replacing previousStore: HostSessionStore? = nil,
        onlyUnboundWindows: Bool = false
    ) {
        installObserversIfNeeded()
        boundStore = store
        guard let store else { return }
        if let cached = cachedWorkspaceWindow, isWorkspaceWindow(cached) {
            trackedWindows.add(cached)
        }
        var ownsAnyWindow = false
        for win in trackedWindows.allObjects where isWorkspaceWindow(win) {
            let existing = windowStores.object(forKey: win)
            let canClaim: Bool
            if onlyUnboundWindows {
                canClaim = existing == nil || existing?.handle == 0 || existing === store
            } else if let previousStore {
                canClaim = existing == nil || existing?.handle == 0 || existing === store || existing === previousStore
            } else {
                canClaim = true
            }
            guard canClaim else {
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
        guard let store else { return }
        if boundStore === store {
            boundStore = nil
        }
        for win in trackedWindows.allObjects where windowStores.object(forKey: win) === store {
            windowStores.removeObject(forKey: win)
            trackedWindows.remove(win)
            miniaturizedWindows.remove(win)
            deminiaturizingWindows.remove(win)
            if cachedWorkspaceWindow === win {
                cachedWorkspaceWindow = nil
            }
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
        guard observers.isEmpty else { return }
        let names = [
            NSWindow.didBecomeKeyNotification,
            NSWindow.didBecomeMainNotification,
            NSWindow.didDeminiaturizeNotification,
            NSWindow.didMiniaturizeNotification,
            NSWindow.willCloseNotification
        ]
        observers = names.map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { notification in
                let eventName = notification.name
                let window = notification.object as? NSWindow
                MainActor.assumeIsolated {
                    handleWindowEvent(name: eventName, window: window)
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
