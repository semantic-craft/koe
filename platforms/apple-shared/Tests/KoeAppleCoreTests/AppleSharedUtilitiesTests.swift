import Foundation
import KoeAppleCore
import os
import Security
import Testing

private final class MockKeychainBackend: AppleKeychainBackend {
    struct Record: Equatable, Sendable {
        let operation: String
        let query: AppleKeychainQuery
        let interactive: Bool
    }

    private struct StorageKey: Hashable, Sendable {
        let service: String
        let account: String
    }

    private struct State: Sendable {
        var items: [StorageKey: Data] = [:]
        var records: [Record] = []
        var failCopy: OSStatus?
        var failAdd: OSStatus?
        var failUpdate: OSStatus?
        var failDelete: OSStatus?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    var records: [Record] { state.withLock(\.records) }

    func setItem(_ data: Data, service: String = AppleCredentialStore.service, account: String) {
        state.withLock { $0.items[StorageKey(service: service, account: account)] = data }
    }

    func setFailures(copy: OSStatus? = nil, add: OSStatus? = nil, update: OSStatus? = nil, delete: OSStatus? = nil) {
        state.withLock {
            $0.failCopy = copy
            $0.failAdd = add
            $0.failUpdate = update
            $0.failDelete = delete
        }
    }

    func copyData(for query: AppleKeychainQuery, interactive: Bool) -> AppleKeychainReadResult {
        state.withLock { state in
            state.records.append(Record(operation: "copy", query: query, interactive: interactive))
            if let failure = state.failCopy { return .failure(failure) }
            guard let data = state.items[StorageKey(service: query.service, account: query.account)] else {
                return .notFound
            }
            return .found(data)
        }
    }

    func add(_ data: Data, for query: AppleKeychainQuery, interactive: Bool) -> OSStatus {
        state.withLock { state in
            state.records.append(Record(operation: "add", query: query, interactive: interactive))
            if let failure = state.failAdd { return failure }
            let key = StorageKey(service: query.service, account: query.account)
            if state.items[key] != nil { return errSecDuplicateItem }
            state.items[key] = data
            return errSecSuccess
        }
    }

    func update(_ data: Data, for query: AppleKeychainQuery, interactive: Bool) -> OSStatus {
        state.withLock { state in
            state.records.append(Record(operation: "update", query: query, interactive: interactive))
            if let failure = state.failUpdate { return failure }
            let key = StorageKey(service: query.service, account: query.account)
            guard state.items[key] != nil else { return errSecItemNotFound }
            state.items[key] = data
            return errSecSuccess
        }
    }

    func delete(for query: AppleKeychainQuery, interactive: Bool) -> OSStatus {
        state.withLock { state in
            state.records.append(Record(operation: "delete", query: query, interactive: interactive))
            if let failure = state.failDelete { return failure }
            let key = StorageKey(service: query.service, account: query.account)
            guard state.items.removeValue(forKey: key) != nil else { return errSecItemNotFound }
            return errSecSuccess
        }
    }
}

@Suite("AppleCredentialStore, ExportFilenameSanitizer, HostAudioInputDescriptor, and ProviderSnapshot")
struct AppleSharedUtilitiesTests {
    @Test("AppleCredentialStore isolated and environment modes enforce strict references and allow rewriting deleted references")
    func credentialStoreIsolatedAndEnvironmentMatrix() throws {
        let isolated = AppleCredentialStore(mode: .isolated)
        #expect(isolated.isolated)

        let ref = try #require(try isolated.perform(operation: 5, reference: "qwen", value: "sk-1"))
        #expect(ref.hasPrefix("isolated-"))
        #expect(try isolated.perform(operation: 1, reference: ref, value: "sk-1") == ref)
        #expect(try isolated.perform(operation: 0, reference: ref, value: "") == "sk-1")
        #expect(try isolated.perform(operation: 2, reference: ref, value: "") == "")
        #expect(try isolated.perform(operation: 0, reference: ref, value: "") == nil)
        #expect(try isolated.perform(operation: 1, reference: ref, value: "sk-2") == ref)
        #expect(try isolated.perform(operation: 0, reference: ref, value: "") == "sk-2")
        #expect(try isolated.perform(operation: 3, reference: "", value: "") == nil)
        #expect(try isolated.perform(operation: 4, reference: ref, value: "") == "")

        let bareUUID = UUID().uuidString.lowercased()
        let cliRef = "isolated-1234-999-1"
        #expect(try isolated.perform(operation: 2, reference: cliRef, value: "") == "")
        for invalid in ["", "bad-ref", bareUUID, "isolated-not-a-uuid"] {
            #expect(throws: AppleCredentialFailure.invalidReference) {
                _ = try isolated.perform(operation: 0, reference: invalid, value: "")
            }
            #expect(throws: AppleCredentialFailure.invalidReference) {
                _ = try isolated.perform(operation: 1, reference: invalid, value: "sk")
            }
        }
        for invalidDelete in ["", "bad-ref", bareUUID, "isolated-", "isolated-bad/ref"] {
            #expect(throws: AppleCredentialFailure.invalidReference) {
                _ = try isolated.perform(operation: 2, reference: invalidDelete, value: "")
            }
        }
        #expect(throws: AppleCredentialFailure.unsupportedOperation) {
            _ = try isolated.perform(operation: 99, reference: ref, value: "")
        }

        let envMode = AppleCredentialMode.resolve(
            environment: [
                "KOE_CREDENTIAL_SOURCE": "environment",
                "DASHSCOPE_API_KEY": "  sk-qwen-env \n",
                "DEEPSEEK_API_KEY": "  sk-ds-env\t",
            ],
            allowsSystemStorage: true
        )
        #expect(envMode == .environment(qwen: "sk-qwen-env", deepseek: "sk-ds-env"))

        let envStore = AppleCredentialStore(mode: envMode)
        let qwenRef = try #require(try envStore.perform(operation: 5, reference: "qwen", value: "sk-qwen-env"))
        #expect(qwenRef.hasPrefix("isolated-environment-qwen-"))
        #expect(try envStore.perform(operation: 0, reference: qwenRef, value: "") == "sk-qwen-env")
        #expect(try envStore.perform(operation: 2, reference: qwenRef, value: "") == "")
        #expect(try envStore.perform(operation: 0, reference: qwenRef, value: "") == nil)
        #expect(try envStore.perform(operation: 1, reference: qwenRef, value: "sk-qwen-env") == qwenRef)
        #expect(try envStore.perform(operation: 0, reference: qwenRef, value: "") == "sk-qwen-env")
        #expect(throws: AppleCredentialFailure.invalidReference) {
            _ = try envStore.perform(operation: 1, reference: qwenRef, value: "wrong-value")
        }
        let legacy = try #require(try envStore.perform(operation: 3, reference: "", value: ""))
        #expect(legacy.contains("sk-qwen-env"))
        #expect(legacy.contains("sk-ds-env"))
    }

    @Test("AppleCredentialStore production Keychain mode enforces UUID validation, duplicate updates, 65_536-byte cap, and accessibility")
    func credentialStoreKeychainMatrix() throws {
        let backend = MockKeychainBackend()
        let store = AppleCredentialStore(
            mode: .productionKeychain,
            accessibility: .afterFirstUnlockThisDeviceOnly,
            keychain: backend
        )
        #expect(!store.isolated)

        let uuid = try #require(try store.perform(operation: 5, reference: "qwen", value: "secret"))
        #expect(UUID(uuidString: uuid) != nil)
        #expect(backend.records.isEmpty)

        #expect(try store.perform(operation: 0, reference: uuid, value: "") == nil)
        #expect(try store.perform(operation: 1, reference: uuid, value: "v1") == uuid)
        #expect(try store.perform(operation: 0, reference: uuid, value: "") == "v1")

        #expect(try store.perform(operation: 1, reference: uuid, value: "v2") == uuid)
        #expect(try store.perform(operation: 0, reference: uuid, value: "") == "v2")
        #expect(backend.records.contains { $0.operation == "update" && $0.query.account == uuid })
        #expect(backend.records.allSatisfy { $0.query.accessibility == .afterFirstUnlockThisDeviceOnly })

        backend.setItem(Data(#"{"qwen":"legacy"}"#.utf8), service: AppleCredentialStore.legacyService, account: AppleCredentialStore.legacyAccount)
        #expect(try store.perform(operation: 3, reference: "", value: "") == #"{"qwen":"legacy"}"#)

        #expect(try store.perform(operation: 4, reference: "", value: "") == "")
        #expect(try store.perform(operation: 4, reference: uuid, value: "") == "")
        let authRecords = backend.records.filter(\.interactive)
        #expect(authRecords.map(\.query.account) == [AppleCredentialStore.legacyAccount, uuid])

        let exactLimit = String(repeating: "a", count: AppleCredentialStore.maxSecretBytes)
        backend.setItem(Data(exactLimit.utf8), account: uuid)
        #expect(try store.perform(operation: 0, reference: uuid, value: "") == exactLimit)

        backend.setItem(Data(repeating: 0x61, count: AppleCredentialStore.maxSecretBytes + 1), account: uuid)
        #expect(throws: AppleCredentialFailure.keychainError(errSecDecode)) {
            _ = try store.perform(operation: 0, reference: uuid, value: "")
        }

        backend.setItem(Data([0xFF, 0xFE]), account: uuid)
        #expect(throws: AppleCredentialFailure.keychainError(errSecDecode)) {
            _ = try store.perform(operation: 0, reference: uuid, value: "")
        }

        #expect(try store.perform(operation: 2, reference: uuid, value: "") == "")
        #expect(try store.perform(operation: 2, reference: uuid, value: "") == "")

        let countBeforeCrossMode = backend.records.count
        for isolatedRef in ["isolated-\(uuid)", "isolated-1234-999-1"] {
            #expect(try store.perform(operation: 2, reference: isolatedRef, value: "") == "")
            #expect(try store.perform(operation: 4, reference: isolatedRef, value: "") == "")
            #expect(throws: AppleCredentialFailure.invalidReference) {
                _ = try store.perform(operation: 0, reference: isolatedRef, value: "")
            }
            #expect(throws: AppleCredentialFailure.invalidReference) {
                _ = try store.perform(operation: 1, reference: isolatedRef, value: "v")
            }
        }
        for invalid in ["", "bad-ref", "isolated-", "isolated-bad/ref"] {
            #expect(throws: AppleCredentialFailure.invalidReference) {
                _ = try store.perform(operation: 0, reference: invalid, value: "")
            }
            #expect(throws: AppleCredentialFailure.invalidReference) {
                _ = try store.perform(operation: 1, reference: invalid, value: "v")
            }
            #expect(throws: AppleCredentialFailure.invalidReference) {
                _ = try store.perform(operation: 2, reference: invalid, value: "")
            }
        }
        #expect(throws: AppleCredentialFailure.invalidReference) {
            _ = try store.perform(operation: 4, reference: "not-a-uuid", value: "")
        }
        #expect(throws: AppleCredentialFailure.unsupportedOperation) {
            _ = try store.perform(operation: 99, reference: uuid, value: "")
        }
        #expect(backend.records.count == countBeforeCrossMode)

        backend.setFailures(delete: errSecInteractionNotAllowed)
        #expect(throws: AppleCredentialFailure.keychainError(errSecInteractionNotAllowed)) {
            _ = try store.perform(operation: 2, reference: uuid, value: "")
        }
    }

    @Test("Rust FFI hostCredentialCallback maps thrown invalidReference to unavailable rather than silent missing")
    @MainActor
    func rustFFICrossModeReferenceMapsToUnavailable() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("koe-ffi-cred-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let backend = MockKeychainBackend()
        let productionStore = AppleCredentialStore(mode: .productionKeychain, keychain: backend)
        let first = HostSessionStore(workspacePath: root.path, credentials: productionStore)
        first.send(.configureProvider(apiKey: "prod-secret", model: "deepseek-flash"))
        #expect(first.settings.provider.qwenConfigured)
        #expect(first.settings.provider.credentialState == "ready")
        first.shutdown()

        let isolatedStore = AppleCredentialStore(mode: .isolated)
        let reopened = HostSessionStore(workspacePath: root.path, credentials: isolatedStore)
        defer { reopened.shutdown() }
        #expect(reopened.settings.provider.credentialState == "unavailable")
        #expect(!reopened.settings.provider.qwenConfigured)
    }

    @Test("ExportFilenameSanitizer handles separators, control characters, dotfiles, whitespace, extensions, and CJK")
    func exportFilenameSanitizerMatrix() {
        #expect(ExportFilenameSanitizer.markdownFilename(stem: "架构/周会") == "架构-周会.md")
        #expect(ExportFilenameSanitizer.markdownFilename(stem: "导出/标题:一") == "导出-标题-一.md")
        #expect(ExportFilenameSanitizer.markdownFilename(stem: "a\\b:c/d\0e\u{0007}f") == "a-b-c-d-e-f.md")
        #expect(ExportFilenameSanitizer.markdownFilename(stem: "...") == "Koe 记录.md")
        #expect(ExportFilenameSanitizer.markdownFilename(stem: ".hidden") == "hidden.md")
        #expect(ExportFilenameSanitizer.markdownFilename(stem: "  ..report..  ") == "report.md")
        #expect(ExportFilenameSanitizer.markdownFilename(stem: "   \n\t  ") == "Koe 记录.md")
        #expect(ExportFilenameSanitizer.markdownFilename(stem: "/:\\\0") == "Koe 记录.md")
        #expect(ExportFilenameSanitizer.markdownFilename(stem: "---") == "Koe 记录.md")
        #expect(ExportFilenameSanitizer.markdownFilename(stem: nil, fallback: "实时纪要") == "实时纪要.md")

        #expect(ExportFilenameSanitizer.sanitizeMarkdownFilename("架构/周会.MD") == "架构-周会.md")
        #expect(ExportFilenameSanitizer.sanitizeMarkdownFilename("..md") == "Koe 记录.md")
        #expect(ExportFilenameSanitizer.sanitizeMarkdownFilename("...笔\0记.md") == "笔-记.md")
        #expect(ExportFilenameSanitizer.sanitizeMarkdownFilename("plain") == "plain.md")

        #expect(ExportFilenameSanitizer.validatedMarkdownFilename("..md") == "Koe 记录.md")
        #expect(ExportFilenameSanitizer.validatedMarkdownFilename("/: \\\0.md") == "Koe 记录.md")
        #expect(ExportFilenameSanitizer.validatedMarkdownFilename("...笔\0记.md") == "笔-记.md")
        #expect(ExportFilenameSanitizer.validatedMarkdownFilename("notes.MD") == "notes.md")
        #expect(ExportFilenameSanitizer.validatedMarkdownFilename("notes.txt") == nil)
        #expect(ExportFilenameSanitizer.validatedMarkdownFilename("notes.md ") == nil)

        let longCJKTitle = String(repeating: "记", count: 100)
        let boundedName = ExportFilenameSanitizer.markdownFilename(stem: longCJKTitle)
        #expect(boundedName.hasSuffix(".md"))
        #expect(boundedName.utf8.count <= 183)
        #expect(boundedName == String(repeating: "记", count: 60) + ".md")

        let truncatedSeparatorsTitle = String(repeating: "/", count: 185) + "tail"
        #expect(ExportFilenameSanitizer.markdownFilename(stem: truncatedSeparatorsTitle) == "Koe 记录.md")
    }

    @Test("HostAudioInputDescriptor.normalized drops invalid IDs, deduplicates preserving default, preserves default past index 64, and truncates name/transport")
    func audioInputDescriptorNormalizationMatrix() {
        #expect(HostAudioInputDescriptor.maxCount == 64)
        #expect(HostAudioInputDescriptor.maxFieldUTF8Bytes == 256)

        let overLimitID = String(repeating: "麦", count: 100)
        let cjkName = String(repeating: "麦", count: 100)
        let fourByteEmoji = String(repeating: "🎙", count: 70)
        let zwjEmoji = String(repeating: "👨‍👩‍👧‍👦", count: 20)
        let combiningCluster = "a" + String(repeating: "\u{0301}", count: 200)

        var raw: [HostAudioInputDescriptor] = [
            HostAudioInputDescriptor(id: "   ", name: "Empty ID", transport: "usb", isDefault: true),
            HostAudioInputDescriptor(id: overLimitID, name: "Overlong ID", transport: "usb", isDefault: true),
            HostAudioInputDescriptor(id: "  dev-0  ", name: cjkName, transport: fourByteEmoji, isDefault: false),
            HostAudioInputDescriptor(id: "dev-0", name: "Duplicate", transport: "usb", isDefault: false),
            HostAudioInputDescriptor(id: "dev-1", name: zwjEmoji, transport: "   ", isDefault: false),
            HostAudioInputDescriptor(id: "dev-2", name: combiningCluster, transport: "usb", isDefault: false),
        ]
        raw.append(contentsOf: (3..<65).map { idx in
            HostAudioInputDescriptor(id: "dev-\(idx)", name: "Device \(idx)", transport: "external", isDefault: false)
        })
        raw.append(HostAudioInputDescriptor(id: "late-default", name: "Late Default Mic", transport: "built_in", isDefault: true))
        raw.append(HostAudioInputDescriptor(id: "dev-66", name: "Extra", transport: "external", isDefault: false))

        let normalized = HostAudioInputDescriptor.normalized(raw)
        #expect(normalized.count == 64)
        #expect(!normalized.contains(where: { $0.id.isEmpty || $0.id.utf8.count > 256 }))
        #expect(normalized[0].id == "dev-0")
        #expect(normalized[0].name == String(repeating: "麦", count: 85))
        #expect(normalized[0].name.utf8.count == 255)
        #expect(normalized[0].transport == String(repeating: "🎙", count: 64))
        #expect(normalized[0].transport.utf8.count == 256)
        #expect(normalized[1].id == "dev-1")
        #expect(normalized[1].name == String(repeating: "👨‍👩‍👧‍👦", count: 10))
        #expect(normalized[1].name.utf8.count == 250)
        #expect(normalized[1].transport == "external")
        #expect(normalized[2].id == "dev-2")
        #expect(normalized[2].name.utf8.count == 255)
        #expect(normalized[2].name.unicodeScalars.first == UnicodeScalar("a"))
        #expect(normalized.last?.id == "late-default")
        #expect(normalized.last?.isDefault == true)
        #expect(HostAudioInputDescriptor.normalized(normalized) == normalized)

        let dupNormalized = HostAudioInputDescriptor.normalized([
            HostAudioInputDescriptor(id: "dup-id", name: "First", transport: "usb", isDefault: false),
            HostAudioInputDescriptor(id: " dup-id ", name: "Second", transport: "usb", isDefault: true),
        ])
        #expect(dupNormalized.count == 1)
        #expect(dupNormalized[0].id == "dup-id")
        #expect(dupNormalized[0].isDefault == true)
    }

    @Test("ProviderSnapshot.persistedModelFingerprint tracks only persisted model configuration fields")
    func persistedModelFingerprintTracksModelFieldsOnly() {
        let base = ProviderSnapshot.empty
        let credentialOnlyChange = ProviderSnapshot(
            meetingAudioPolicy: "cloud_allowed",
            meetingAudioStatus: "enabled",
            meetingAudioPolicyError: "notice",
            configured: true,
            qwenConfigured: true,
            deepseekConfigured: true,
            asrConfigured: true,
            asrIsRealtime: false,
            asrProvider: base.asrProvider,
            asrModel: base.asrModel,
            llmProvider: base.llmProvider,
            model: base.model,
            enableThinking: base.enableThinking,
            qwenWorkspaceId: base.qwenWorkspaceId,
            asrEndpoint: base.asrEndpoint,
            chatEndpoint: base.chatEndpoint,
            credentialState: "ready",
            deepseekCredentialState: "ready",
            isolated: false
        )
        #expect(credentialOnlyChange.persistedModelFingerprint == base.persistedModelFingerprint)

        let modelVariants: [ProviderSnapshot] = [
            ProviderSnapshot(
                meetingAudioPolicy: base.meetingAudioPolicy, meetingAudioStatus: nil, meetingAudioPolicyError: nil,
                configured: false, qwenConfigured: false, deepseekConfigured: false, asrConfigured: false,
                asrIsRealtime: true, asrProvider: "deepseek", asrModel: base.asrModel, llmProvider: base.llmProvider,
                model: base.model, enableThinking: base.enableThinking, qwenWorkspaceId: base.qwenWorkspaceId,
                asrEndpoint: base.asrEndpoint, chatEndpoint: base.chatEndpoint,
                credentialState: "missing", deepseekCredentialState: "missing", isolated: true
            ),
            ProviderSnapshot(
                meetingAudioPolicy: base.meetingAudioPolicy, meetingAudioStatus: nil, meetingAudioPolicyError: nil,
                configured: false, qwenConfigured: false, deepseekConfigured: false, asrConfigured: false,
                asrIsRealtime: true, asrProvider: base.asrProvider, asrModel: "qwen-audio-3.1-asr-flash",
                llmProvider: base.llmProvider, model: base.model, enableThinking: base.enableThinking,
                qwenWorkspaceId: base.qwenWorkspaceId, asrEndpoint: base.asrEndpoint, chatEndpoint: base.chatEndpoint,
                credentialState: "missing", deepseekCredentialState: "missing", isolated: true
            ),
            ProviderSnapshot(
                meetingAudioPolicy: base.meetingAudioPolicy, meetingAudioStatus: nil, meetingAudioPolicyError: nil,
                configured: false, qwenConfigured: false, deepseekConfigured: false, asrConfigured: false,
                asrIsRealtime: true, asrProvider: base.asrProvider, asrModel: base.asrModel, llmProvider: "custom",
                model: base.model, enableThinking: base.enableThinking, qwenWorkspaceId: base.qwenWorkspaceId,
                asrEndpoint: base.asrEndpoint, chatEndpoint: base.chatEndpoint,
                credentialState: "missing", deepseekCredentialState: "missing", isolated: true
            ),
            ProviderSnapshot(
                meetingAudioPolicy: base.meetingAudioPolicy, meetingAudioStatus: nil, meetingAudioPolicyError: nil,
                configured: false, qwenConfigured: false, deepseekConfigured: false, asrConfigured: false,
                asrIsRealtime: true, asrProvider: base.asrProvider, asrModel: base.asrModel,
                llmProvider: base.llmProvider, model: "deepseek-v4-pro", enableThinking: base.enableThinking,
                qwenWorkspaceId: base.qwenWorkspaceId, asrEndpoint: base.asrEndpoint, chatEndpoint: base.chatEndpoint,
                credentialState: "missing", deepseekCredentialState: "missing", isolated: true
            ),
            ProviderSnapshot(
                meetingAudioPolicy: base.meetingAudioPolicy, meetingAudioStatus: nil, meetingAudioPolicyError: nil,
                configured: false, qwenConfigured: false, deepseekConfigured: false, asrConfigured: false,
                asrIsRealtime: true, asrProvider: base.asrProvider, asrModel: base.asrModel,
                llmProvider: base.llmProvider, model: base.model, enableThinking: true,
                qwenWorkspaceId: base.qwenWorkspaceId, asrEndpoint: base.asrEndpoint, chatEndpoint: base.chatEndpoint,
                credentialState: "missing", deepseekCredentialState: "missing", isolated: true
            ),
            ProviderSnapshot(
                meetingAudioPolicy: base.meetingAudioPolicy, meetingAudioStatus: nil, meetingAudioPolicyError: nil,
                configured: false, qwenConfigured: false, deepseekConfigured: false, asrConfigured: false,
                asrIsRealtime: true, asrProvider: base.asrProvider, asrModel: base.asrModel,
                llmProvider: base.llmProvider, model: base.model, enableThinking: base.enableThinking,
                qwenWorkspaceId: "ws-bj-1", asrEndpoint: base.asrEndpoint, chatEndpoint: base.chatEndpoint,
                credentialState: "missing", deepseekCredentialState: "missing", isolated: true
            ),
            ProviderSnapshot(
                meetingAudioPolicy: base.meetingAudioPolicy, meetingAudioStatus: nil, meetingAudioPolicyError: nil,
                configured: false, qwenConfigured: false, deepseekConfigured: false, asrConfigured: false,
                asrIsRealtime: true, asrProvider: base.asrProvider, asrModel: base.asrModel,
                llmProvider: base.llmProvider, model: base.model, enableThinking: base.enableThinking,
                qwenWorkspaceId: base.qwenWorkspaceId, asrEndpoint: "wss://example.com/asr",
                chatEndpoint: base.chatEndpoint,
                credentialState: "missing", deepseekCredentialState: "missing", isolated: true
            ),
            ProviderSnapshot(
                meetingAudioPolicy: base.meetingAudioPolicy, meetingAudioStatus: nil, meetingAudioPolicyError: nil,
                configured: false, qwenConfigured: false, deepseekConfigured: false, asrConfigured: false,
                asrIsRealtime: true, asrProvider: base.asrProvider, asrModel: base.asrModel,
                llmProvider: base.llmProvider, model: base.model, enableThinking: base.enableThinking,
                qwenWorkspaceId: base.qwenWorkspaceId, asrEndpoint: base.asrEndpoint,
                chatEndpoint: "https://example.com/chat",
                credentialState: "missing", deepseekCredentialState: "missing", isolated: true
            ),
        ]

        for variant in modelVariants {
            #expect(variant.persistedModelFingerprint != base.persistedModelFingerprint)
        }
        #expect(Set(modelVariants.map(\.persistedModelFingerprint)).count == modelVariants.count)
    }
}
