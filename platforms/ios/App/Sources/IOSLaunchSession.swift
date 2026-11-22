import Foundation
import KoeAppleCore
import OSLog
import UIKit

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
    private nonisolated static let logger = Logger(subsystem: "com.semanticcraft.koe.ios", category: "host")

    let store: HostSessionStore
    let fileActions: IOSFileActions
    let coordinator: IOSHostCoordinator
    private let inputMonitor: IOSAudioInputMonitor
    private static let traceQueue = DispatchQueue(label: "com.semanticcraft.koe.ios.trace", qos: .utility)
    private let traceURLs: [URL]

    init(
        bridgeActions: HostBridgeActions,
        arguments: [String] = ProcessInfo.processInfo.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        source: MicrophoneSource? = nil,
        allowsCoreBluetooth: Bool = true,
        bluetoothBridge: BluetoothBridge? = nil,
        restoreIdentifiers: [String] = []
    ) {
        let config = IOSLaunchConfig.parse(arguments: arguments, environment: environment)
        let credentials = NativeCredentialsiOS(
            workspaceOverride: config.workspacePath != nil,
            environment: environment
        )
        var outputs: [URL] = []
        #if DEBUG
        let sandboxTrace = URL.documentsDirectory.appendingPathComponent("koe-trace.json")
        outputs.append(sandboxTrace.standardizedFileURL)
        #endif
        if let path = config.traceOutputPath {
            let url = URL(fileURLWithPath: path, relativeTo: .documentsDirectory).standardizedFileURL
            if !outputs.contains(url) { outputs.append(url) }
        }
        traceURLs = outputs
        store = HostSessionStore(workspacePath: config.workspacePath, credentials: credentials, verificationTrace: config.traceOutputPath != nil)
        fileActions = IOSFileActions(store: store)
        #if DEBUG
        let useRadio = allowsCoreBluetooth && config.snapshotFixturePath == nil && environment["KOE_DISABLE_CORE_BLUETOOTH"] != "1"
        #else
        let useRadio = allowsCoreBluetooth
        #endif
        let audioSession = IOSAudioSession()
        coordinator = IOSHostCoordinator(store: store, actions: bridgeActions, source: source,
                                         audioSession: audioSession, allowsCoreBluetooth: useRadio,
                                         bluetoothBridge: bluetoothBridge, restoreIdentifiers: restoreIdentifiers,
                                         allowsLocalSpeech: config.snapshotFixturePath == nil)
        inputMonitor = IOSAudioInputMonitor(store: store, audioSession: audioSession)

        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "2.7.1"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "17"
        store.send(
            .syncAppMetadata(
                version: version,
                build: build,
                platform: "ios",
                hostDisplayName: UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone",
                supportsSystemAudio: false,
                supportsSelfUpdate: false,
                nativeSpeechLabel: "Apple 本机"
            )
        )

        inputMonitor.start()
        #if DEBUG
        if let fixturePath = config.snapshotFixturePath {
            loadDebugFixture(at: fixturePath, resumeLive: arguments.contains("-koe-fixture-to-live"))
        }
        #endif

        store.onTraceRecorded = { [weak self] in self?.writeTraceFile() }
        writeTraceFile()
        Self.logger.info("Koe iOS host session ready (workspace=\(self.store.workspacePath, privacy: .public))")
    }

    #if DEBUG
    private func loadDebugFixture(at path: String, resumeLive: Bool) {
        do {
            let url = URL(fileURLWithPath: path, relativeTo: .documentsDirectory)
            let json = try String(contentsOf: url, encoding: .utf8)
            if !store.loadDebugSnapshotFixtureJSON(json, resumeLiveOnCommand: resumeLive) {
                Self.logger.error("Invalid snapshot fixture: \(self.store.nativeError ?? "读取失败", privacy: .public)")
            }
        } catch {
            Self.logger.error("Snapshot fixture read failed: \(error.localizedDescription, privacy: .public)")
            store.reportNativeError("无法读取调试快照文件。")
        }
    }
    #endif

    private func writeTraceFile() {
        guard !traceURLs.isEmpty else { return }
        let json = store.exportTraceJSON()
        Self.traceQueue.async { [traceURLs, weak store] in
            let data = Data((json + "\n").utf8)
            for url in traceURLs {
                do {
                    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try data.write(to: url, options: .atomic)
                } catch {
                    Self.logger.error("Trace write failed: \(error.localizedDescription, privacy: .public)")
                    Task { @MainActor [weak store] in store?.reportNativeError("无法保存宿主追踪文件。") }
                }
            }
        }
    }

    func shutdown() {
        inputMonitor.stop()
        coordinator.shutdown()
        store.onTraceRecorded = nil
        store.shutdown()
    }
}
