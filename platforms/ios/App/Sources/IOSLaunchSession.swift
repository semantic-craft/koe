import Foundation
import KoeAppleCore
import OSLog

struct IOSLaunchConfig: Equatable {
    let workspacePath: String?
    let snapshotFixturePath: String?
    let traceOutputPath: String?

    static func parse(
        arguments: [String] = ProcessInfo.processInfo.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> IOSLaunchConfig {
        func option(_ flag: String, envKey: String) -> String? {
            if let idx = arguments.firstIndex(of: flag), idx + 1 < arguments.count {
                let value = arguments[idx + 1].trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty { return value }
            }
            if let raw = environment[envKey]?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
                return raw
            }
            return nil
        }

        return IOSLaunchConfig(
            workspacePath: option("-koe-workspace", envKey: "KOE_WORKSPACE"),
            snapshotFixturePath: option("-koe-snapshot-fixture", envKey: "KOE_SNAPSHOT_FIXTURE"),
            traceOutputPath: option("-koe-trace-output", envKey: "KOE_TRACE_OUTPUT")
        )
    }
}

@MainActor
final class IOSLaunchSession {
    private static let logger = Logger(subsystem: "com.semanticcraft.koe.ios", category: "host")

    let config: IOSLaunchConfig
    let credentials: NativeCredentialsiOS
    let store: HostSessionStore
    private let sandboxTraceURL: URL

    init(
        arguments: [String] = ProcessInfo.processInfo.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        let parsed = IOSLaunchConfig.parse(arguments: arguments, environment: environment)
        self.config = parsed
        self.credentials = NativeCredentialsiOS(
            workspaceOverride: parsed.workspacePath != nil,
            environment: environment
        )
        let docsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        self.sandboxTraceURL = docsURL.appendingPathComponent("koe-trace.json")

        let resolvedWorkspace: String?
        if let explicitWorkspace = parsed.workspacePath {
            resolvedWorkspace = explicitWorkspace
        } else {
            resolvedWorkspace = nil
        }

        self.store = HostSessionStore(workspacePath: resolvedWorkspace, credentials: credentials)
        self.store.onSnapshotChanged = { [weak self] _ in
            // HostSessionStore records the command trace in defer after onSnapshotChanged fires.
            DispatchQueue.main.async {
                self?.writeTraceFile()
            }
        }

        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "2.6.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "15"
        store.send(
            .syncAppMetadata(
                version: version,
                build: build,
                platform: "ios",
                hostDisplayName: "iPhone",
                supportsSystemAudio: false,
                supportsSelfUpdate: false,
                nativeSpeechLabel: "Apple 本机"
            )
        )

        #if DEBUG
        if let fixturePath = parsed.snapshotFixturePath {
            _ = loadDebugFixture(at: fixturePath)
        }
        #endif

        writeTraceFile()
        Self.logger.info("Koe iOS host session ready (workspace=\(self.store.workspacePath, privacy: .public))")
    }

    #if DEBUG
    @discardableResult
    func loadDebugFixture(at path: String) -> Bool {
        let url = resolveReadableURL(path)
        guard let data = try? Data(contentsOf: url),
              let json = String(data: data, encoding: .utf8) else {
            store.reportNativeError("无法读取调试快照文件。")
            writeTraceFile()
            return false
        }
        let ok = store.loadDebugSnapshotFixtureJSON(json)
        writeTraceFile()
        return ok
    }
    #endif

    func writeTraceFile() {
        let json = store.exportTraceJSON()
        guard let data = (json + "\n").data(using: .utf8) else { return }
        try? FileManager.default.createDirectory(
            at: sandboxTraceURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: sandboxTraceURL, options: .atomic)

        if let explicitTrace = config.traceOutputPath {
            let explicitURL = resolveWritableURL(explicitTrace)
            try? FileManager.default.createDirectory(
                at: explicitURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? data.write(to: explicitURL, options: .atomic)
        }
    }

    private func resolveReadableURL(_ path: String) -> URL {
        if path.hasPrefix("/") {
            return URL(fileURLWithPath: path)
        }
        let docsURL = sandboxTraceURL.deletingLastPathComponent()
        return docsURL.appendingPathComponent(path)
    }

    private func resolveWritableURL(_ path: String) -> URL {
        if path.hasPrefix("/") {
            return URL(fileURLWithPath: path)
        }
        let docsURL = sandboxTraceURL.deletingLastPathComponent()
        return docsURL.appendingPathComponent(path)
    }
}
