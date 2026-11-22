import Foundation
import KoeAppleCore

final class NativeCredentialsiOS: HostCredentials {
    typealias Failure = AppleCredentialFailure

    private let store: AppleCredentialStore

    var isolated: Bool { store.isolated }

    init(
        workspaceOverride: Bool = false,
        forceIsolated: Bool = false,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        #if DEBUG
        let isDebug = true
        #else
        let isDebug = false
        #endif
        let mode = AppleCredentialMode.resolve(
            environment: environment,
            allowsSystemStorage: !forceIsolated && !isDebug && !workspaceOverride && environment["KOE_CREDENTIAL_SOURCE"] == nil
        )
        store = AppleCredentialStore(
            mode: mode,
            accessibility: .afterFirstUnlockThisDeviceOnly
        )
    }

    init(mode: AppleCredentialMode, keychain: any AppleKeychainBackend) {
        store = AppleCredentialStore(
            mode: mode,
            accessibility: .afterFirstUnlockThisDeviceOnly,
            keychain: keychain
        )
    }

    func perform(operation: UInt32, reference: String, value: String) throws -> String? {
        try store.perform(operation: operation, reference: reference, value: value)
    }
}
