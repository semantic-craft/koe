import Foundation
import KoeMacUI
import Security

private struct MacKeychainInteractionGate: AppleKeychainInteractionGate {
    func run(interactive: Bool, _ body: () -> Void) -> OSStatus {
        var wasAllowed = DarwinBoolean(false)
        let getStatus = SecKeychainGetUserInteractionAllowed(&wasAllowed)
        guard getStatus == errSecSuccess else { return getStatus }
        let setStatus = SecKeychainSetUserInteractionAllowed(interactive)
        guard setStatus == errSecSuccess else { return setStatus }
        defer { SecKeychainSetUserInteractionAllowed(wasAllowed.boolValue) }
        body()
        return errSecSuccess
    }
}

final class NativeCredentials: HostCredentials {
    typealias Failure = AppleCredentialFailure

    private let store: AppleCredentialStore

    var isolated: Bool { store.isolated }

    static func allowsSystemStorage(debug: Bool, sourceOverride: Bool, workspaceOverride: Bool, trusted: Bool) -> Bool {
        !debug && !sourceOverride && !workspaceOverride && trusted
    }

    init(workspaceOverride: Bool, environment: [String: String] = ProcessInfo.processInfo.environment) {
        #if DEBUG
        let debug = true
        #else
        let debug = false
        #endif
        let mode = AppleCredentialMode.resolve(
            environment: environment,
            allowsSystemStorage: Self.allowsSystemStorage(
                debug: debug,
                sourceOverride: environment["KOE_CREDENTIAL_SOURCE"] != nil,
                workspaceOverride: workspaceOverride,
                trusted: Self.trustedSignature()
            )
        )
        store = AppleCredentialStore(
            mode: mode,
            accessibility: .platformDefault,
            keychain: SystemAppleKeychainBackend(interactionGate: MacKeychainInteractionGate())
        )
    }

    init(mode: AppleCredentialMode, keychain: any AppleKeychainBackend) {
        store = AppleCredentialStore(
            mode: mode,
            accessibility: .platformDefault,
            keychain: keychain
        )
    }

    func perform(operation: UInt32, reference: String, value: String) throws -> String? {
        try store.perform(operation: operation, reference: reference, value: value)
    }

    private static func trustedSignature() -> Bool {
        var code: SecCode?
        var requirement: SecRequirement?
        let rule = """
        anchor apple generic and identifier "com.anker.ankerRecorder" and \
        certificate leaf[field.1.2.840.113635.100.6.1.13] exists and \
        certificate leaf[subject.OU] = "LQAVR62TK2"
        """
        return SecCodeCopySelf([], &code) == errSecSuccess
            && SecRequirementCreateWithString(rule as CFString, [], &requirement) == errSecSuccess
            && code.map { SecCodeCheckValidity($0, [], requirement) == errSecSuccess } == true
    }
}
