import KoeAppleCore
import SwiftUI

@main
struct KoeiOSApp: App {
    @Environment(\.scenePhase) private var scenePhase
    private let session = IOSLaunchSession()

    var body: some Scene {
        WindowGroup {
            IOSRootTabView(store: session.store)
                .onChange(of: scenePhase, initial: true) { _, nextPhase in
                    session.store.setUISlicesActive(nextPhase == .active)
                }
        }
    }
}
