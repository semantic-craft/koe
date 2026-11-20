import KoeAppleCore
import SwiftUI

@main
struct KoeiOSApp: App {
    @Environment(\.scenePhase) private var scenePhase
    private let session = IOSLaunchSession(bridgeActions: HostBridgeActions())

    var body: some Scene {
        WindowGroup {
            IOSRootTabView(store: session.store)
                .onChange(of: scenePhase, initial: true) { _, nextPhase in
                    session.coordinator.setScenePhase(nextPhase)
                }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.willTerminateNotification)) { _ in
                    session.shutdown()
                }
        }
    }
}
