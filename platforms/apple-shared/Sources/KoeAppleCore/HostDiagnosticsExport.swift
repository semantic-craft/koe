import CKoeHostApi
import Foundation

public extension HostSessionStore {
    static func diagnosticsBundleFilename(nowEpochSec: UInt64 = 0) -> String {
        let effectiveNow = nowEpochSec > 0 ? nowEpochSec : UInt64(max(0, Date().timeIntervalSince1970))
        return "koe-diagnostics-\(effectiveNow).json"
    }

    func exportRustDiagnosticsJSON(nowEpochSec: UInt64 = 0) -> String? {
        guard handle != 0 else { return nil }
        let effectiveNow = nowEpochSec > 0 ? nowEpochSec : UInt64(max(0, Date().timeIntervalSince1970))
        guard let pointer = koe_host_session_export_diagnostics_json(handle, effectiveNow) else {
            diagnostics.error(
                category: "diagnostics",
                event: "export_rust_null_response",
                detail: "bridge returned null diagnostics bundle",
                errorCode: "ffi_diagnostics_null"
            )
            return nil
        }
        defer { koe_host_string_free(pointer) }
        return String(cString: pointer)
    }

    func exportDiagnosticsBundleJSON(nowEpochSec: UInt64 = 0) -> String {
        let rustObject: Any = {
            guard let raw = exportRustDiagnosticsJSON(nowEpochSec: nowEpochSec),
                  let parsed = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) else {
                return NSNull()
            }
            return parsed
        }()

        let hostDiagnosticsObject: Any = encodeToJSONObject(recentDiagnostics()) ?? []
        let hostTraceObject: Any = encodeToJSONObject(recentTraceEntries) ?? []
        let merged: [String: Any] = [
            "rust": rustObject,
            "hostDiagnostics": hostDiagnosticsObject,
            "hostTrace": hostTraceObject,
        ]

        do {
            let data = try JSONSerialization.data(
                withJSONObject: merged,
                options: [.sortedKeys, .prettyPrinted]
            )
            if let text = String(data: data, encoding: .utf8) {
                return text
            }
        } catch {
            diagnostics.error(
                category: "diagnostics",
                event: "serialize_bundle_failed",
                error: error
            )
        }
        return "{\"rust\":null,\"hostDiagnostics\":[],\"hostTrace\":[]}"
    }

    private func encodeToJSONObject<T: Encodable>(_ value: T) -> Any? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }
}
