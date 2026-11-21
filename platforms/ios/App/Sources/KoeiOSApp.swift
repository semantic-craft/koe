import KoeAppleCore
import SwiftUI

@MainActor
final class IOSAppDelegate: NSObject, UIApplicationDelegate {
    lazy var session = IOSLaunchSession(bridgeActions: HostBridgeActions())

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        if let identifiers = options?[.bluetoothCentrals] as? [String] {
            session.coordinator.bluetoothBridge.restoreCentralIfNeeded(restoreIdentifiers: identifiers)
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
