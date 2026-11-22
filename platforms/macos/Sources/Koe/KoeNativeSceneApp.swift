import AppKit
import Foundation
import KoeAppleShared
import Observation
import SwiftUI

@MainActor
@Observable
final class KoeSessionHolder {
    var store: HostSessionStore?
}

private struct KoeWorkspaceSceneHost: View {
    let appDelegate: KoeAppDelegate

    var body: some View {
        if let store = appDelegate.sessionHolder.store {
            KoeWorkspaceRootView(
                store: store,
                onImport: { appDelegate.files.importFile() },
                onExport: { appDelegate.files.exportRecord($0) },
                onExportRecords: { appDelegate.files.exportRecords($0) },
                onExportWorkspace: { appDelegate.files.exportWorkspace($0) }
            )
            .onAppear {
                KoeWindowPresenter.presentPrimaryWorkspaceWindow()
            }
        } else {
            Color.clear
                .onAppear {
                    _ = appDelegate.ensureSessionStore()
                }
        }
    }
}

struct KoeNativeSceneApp: App {
    @NSApplicationDelegateAdaptor(KoeAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("Koe") {
            KoeWorkspaceSceneHost(appDelegate: appDelegate)
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
