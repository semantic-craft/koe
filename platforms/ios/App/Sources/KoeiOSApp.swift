import KoeAppleCore
import SwiftUI

@MainActor
final class IOSAppDelegate: NSObject, UIApplicationDelegate {
    private var pendingRestoreIdentifiers: [String] = []
    private var initializedSession: IOSLaunchSession?
    var makeSession: ([String]) -> IOSLaunchSession = { restoreIdentifiers in
        IOSLaunchSession(bridgeActions: HostBridgeActions(), restoreIdentifiers: restoreIdentifiers)
    }

    var session: IOSLaunchSession {
        get {
            if let initializedSession { return initializedSession }
            let created = makeSession(pendingRestoreIdentifiers)
            initializedSession = created
            return created
        }
        set {
            initializedSession = newValue
        }
    }

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        if let identifiers = options?[.bluetoothCentrals] as? [String] {
            pendingRestoreIdentifiers = identifiers
            if let initializedSession {
                initializedSession.coordinator.bluetoothBridge.restoreCentralIfNeeded(restoreIdentifiers: identifiers)
            } else {
                _ = session
            }
        }
        return true
    }
}

@main
struct KoeiOSApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @UIApplicationDelegateAdaptor(IOSAppDelegate.self) private var delegate
    private var session: IOSLaunchSession { delegate.session }

    var body: some Scene {
        WindowGroup {
            IOSRootTabView(store: session.store)
                .modifier(IOSFileExportPresentation(actions: session.fileActions))
                .environment(session.fileActions)
                .onChange(of: scenePhase, initial: true) { _, nextPhase in
                    session.coordinator.setScenePhase(nextPhase)
                }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.willTerminateNotification)) { _ in
                    session.shutdown()
                }
        }
    }
}
