import AppKit
import KoeAppleShared

@MainActor
struct NativeHostActions {
    var openURL: (URL) -> Bool = { NSWorkspace.shared.open($0) }

    func apply(to store: HostSessionStore) {
        for action in store.drainHostActions() {
            switch action.type {
            case .openResponsay:
                guard let url = URL(string: "responsay://connect-koe"), openURL(url) else {
                    store.reportNativeError("无法打开 Responsay，请确认已安装，然后点击重新连接。")
                    continue
                }
            }
        }
    }
}
