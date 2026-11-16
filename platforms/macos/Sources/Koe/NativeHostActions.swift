import KoeAppleShared

@MainActor
struct NativeHostActions {
    func apply(to store: HostSessionStore) {
        _ = store.drainHostActions()
    }
}
