import CKoeHostApi
import Foundation
import Observation

@MainActor
public struct ViewRequestGeneration {
    public private(set) var latestRustGeneration: UInt64 = 0
    public init() {}
    public mutating func acceptRustGeneration(_ generation: UInt64) -> Bool {
        guard generation >= latestRustGeneration else { return false }
        latestRustGeneration = generation
        return true
    }
}

@MainActor
@Observable
public final class HostSessionStore {
    public private(set) var snapshot: HostSnapshot = .empty
    public private(set) var nativeError: String?
    @ObservationIgnored public private(set) var handle: UInt64 = 0
    @ObservationIgnored public var onSnapshotChanged: ((HostSnapshot) -> Void)?
    @ObservationIgnored private var requestGate = ViewRequestGeneration()

    @ObservationIgnored private let credentials: HostCredentials?

    public init(workspacePath: String? = nil, credentials: HostCredentials? = nil) {
        self.credentials = credentials
        guard Self.apiVersion() == 2 else {
            nativeError = "应用与数据引擎版本不一致，请重新构建应用。"
            return
        }
        let directory = workspacePath ?? Self.defaultWorkspacePath(isolated: credentials?.isolated == true)
        if let credentials {
            let context = Unmanaged.passUnretained(credentials as AnyObject).toOpaque()
            handle = directory.withCString {
                koe_host_session_create_with_credentials($0, hostCredentialCallback, context, credentials.isolated)
            }
        } else {
            handle = directory.withCString { koe_host_session_create($0) }
        }
        guard handle != 0 else {
            nativeError = "无法打开工作区，请检查文件夹的访问权限。"
            return
        }
        refreshSnapshot()
    }

    deinit { if handle != 0 { _ = koe_host_session_destroy(handle) } }

    public static func apiVersion() -> UInt32 { koe_host_api_version() }

    public static func defaultWorkspacePath(isolated: Bool = false) -> String {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent(isolated ? "KoeWorkspaceDevelopment" : "KoeWorkspace", isDirectory: true).path
    }

    public func shutdown() {
        guard handle != 0 else { return }
        _ = koe_host_session_destroy(handle)
        handle = 0
    }

    public func reportNativeError(_ message: String) { nativeError = message }

    public func clearError() {
        nativeError = nil
        send(.clearError)
    }

    public func send(_ command: HostCommand, nowEpochSec: UInt64 = 0) {
        guard handle != 0 else { return }
        do {
            let data = try JSONEncoder().encode(command)
            dispatchEncodedJSON(data, commandType: command.commandType, nowEpochSec: nowEpochSec)
        } catch {
            nativeError = "无法发送这次操作，请重试。"
        }
    }

    public func send(_ type: String, _ fields: [String: Any] = [:], nowEpochSec: UInt64 = 0) {
        var payload = fields
        payload["type"] = type
        dispatchCommand(payload, nowEpochSec: nowEpochSec)
    }

    public func dispatchCommand(_ payload: [String: Any], nowEpochSec: UInt64 = 0) {
        guard handle != 0 else { return }
        do {
            let data = try JSONSerialization.data(withJSONObject: payload)
            dispatchEncodedJSON(data, commandType: payload["type"] as? String, nowEpochSec: nowEpochSec)
        } catch {
            nativeError = "无法发送这次操作，请重试。"
        }
    }

    private func dispatchEncodedJSON(_ data: Data, commandType: String?, nowEpochSec: UInt64) {
        if commandType != "playback_progress" && commandType != "sync_audio_inputs" { nativeError = nil }
        guard let command = String(data: data, encoding: .utf8) else { return }
        let result: String? = command.withCString { ptr in
            guard let response = koe_host_session_dispatch_json(handle, ptr, nowEpochSec) else { return nil }
            defer { koe_host_string_free(response) }
            return String(cString: response)
        }
        guard let result else {
            nativeError = "操作未能完成，请重试。工作区数据仍然保留。"
            return
        }
        applySnapshotJSON(result)
    }

    public func refreshSnapshot(nowEpochSec: UInt64 = 0) {
        guard handle != 0 else { return }
        guard let pointer = koe_host_session_snapshot_json(handle, nowEpochSec) else {
            nativeError = "无法读取工作区状态。"
            return
        }
        defer { koe_host_string_free(pointer) }
        applySnapshotJSON(String(cString: pointer))
    }

    public func ingestBleChunk(_ data: Data, nowEpochSec: UInt64 = 0) {
        guard handle != 0 else { return }
        let generation = data.withUnsafeBytes { buffer in
            koe_host_session_ingest_ble(handle, buffer.bindMemory(to: UInt8.self).baseAddress, data.count, nowEpochSec)
        }
        if generation > snapshot.generation { refreshSnapshot(nowEpochSec: nowEpochSec) }
    }

    public func pollTimers(elapsedMs: UInt64, nowEpochSec: UInt64 = 0) {
        guard handle != 0 else { return }
        let generation = koe_host_session_poll_timers(handle, elapsedMs, nowEpochSec)
        if generation > snapshot.generation { refreshSnapshot(nowEpochSec: nowEpochSec) }
    }

    public func drainOutboundBleFramesHex() -> [String] {
        guard handle != 0, let pointer = koe_host_session_drain_ble_tx_json(handle) else { return [] }
        defer { koe_host_string_free(pointer) }
        guard let data = String(cString: pointer).data(using: .utf8),
              let frames = try? JSONDecoder().decode([String].self, from: data) else {
            nativeError = "无法读取设备发送队列。"
            return []
        }
        return frames
    }

    public func drainHostActions() -> [HostAction] {
        guard handle != 0, let pointer = koe_host_session_drain_host_actions_json(handle) else { return [] }
        defer { koe_host_string_free(pointer) }
        do {
            return try JSONDecoder().decode([HostAction].self, from: Data(String(cString: pointer).utf8))
        } catch {
            nativeError = "无法读取应用启动请求，请重新连接。"
            return []
        }
    }

    public func drainLocalASREffectsJSON() -> Data? {
        guard handle != 0, let pointer = koe_host_session_drain_local_asr_json(handle) else { return nil }
        defer { koe_host_string_free(pointer) }
        return Data(String(cString: pointer).utf8)
    }

    func applySnapshotJSON(_ json: String) {
        do {
            let decoded = try JSONDecoder().decode(HostSnapshot.self, from: Data(json.utf8))
            guard decoded.version == 2 else {
                nativeError = "数据引擎返回了不兼容的版本。"
                return
            }
            guard requestGate.acceptRustGeneration(decoded.generation) else { return }
            if decoded != snapshot {
                snapshot = decoded
                onSnapshotChanged?(decoded)
            }
        } catch {
            nativeError = "无法读取数据引擎的回应，请重新打开应用。"
        }
    }
}
