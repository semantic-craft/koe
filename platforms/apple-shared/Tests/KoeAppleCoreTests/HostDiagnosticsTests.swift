import Foundation
@testable import KoeAppleCore
import os
import Testing

@Suite("HostDiagnosticLog redaction, error formatting, and HostSessionStore decode diagnostics")
struct HostDiagnosticsTests {
    @Test("HostDiagnosticLog.redact scrubs API keys, Bearer tokens, secret key-value pairs, and enforces 300-byte UTF-8 cap")
    func redactScrubsSecretsAndCapsLength() {
        let raw = """
        auth=Bearer tok_abc.123_XYZ key=sk-secret123456 apiKey=xyz \
        "deepseekApiKey":"ds_raw_999" token: tok_val secret="my_secret" password='hunter2'
        """
        let redacted = HostDiagnosticLog.redact(raw)

        #expect(!redacted.contains("tok_abc"))
        #expect(!redacted.contains("sk-secret123456"))
        #expect(!redacted.contains("xyz"))
        #expect(!redacted.contains("ds_raw_999"))
        #expect(!redacted.contains("tok_val"))
        #expect(!redacted.contains("my_secret"))
        #expect(!redacted.contains("hunter2"))
        #expect(redacted.contains("Bearer [REDACTED]"))
        #expect(redacted.contains("[REDACTED]"))

        let innocent = "keyNotFound path=ask-question.records[0].title"
        #expect(HostDiagnosticLog.redact(innocent) == innocent)

        let longCJK = String(repeating: "诊", count: 150)
        let truncated = HostDiagnosticLog.redact(longCJK)
        #expect(truncated.utf8.count <= HostDiagnosticLog.maxDetailUTF8Bytes)
        #expect(truncated.hasSuffix("..."))
    }

    @Test("HostDiagnosticLog.redact catches truncated JSON strings, prefixed secret keys, Authorization schemes, and dotted sk- keys")
    func redactCoversTruncatedJsonPrefixedKeysAuthorizationAndDottedSk() {
        let cases: [(input: String, forbidden: [String])] = [
            (#"...{"deepseekApiKey":"ds_secret_99..."#, ["ds_secret_99"]),
            (#""apiKey":"raw_secret_without_closing_quote"#, ["raw_secret_without_closing_quote"]),
            ("DASHSCOPE_API_KEY=ds_raw_999 DEEPSEEK_API_KEY=ds_alt_888", ["ds_raw_999", "ds_alt_888"]),
            (#""qwenApiKey":"ds_raw_999" qwen_api_key=qwen_val_777"#, ["ds_raw_999", "qwen_val_777"]),
            ("authToken=tok_1 client_secret=sec_1 private_key=pk_secret_2", ["tok_1", "sec_1", "pk_secret_2"]),
            ("Authorization: Basic dXNlcjpwYXNz", ["dXNlcjpwYXNz", "Basic dXNlc"]),
            (#""authorization":"Basic dXNlcjpwYXNz""#, ["dXNlcjpwYXNz"]),
            ("key=sk-proj.abc.def trailing=ok", ["sk-proj", "abc", "def"]),
        ]

        for entry in cases {
            let redacted = HostDiagnosticLog.redact(entry.input)
            for secret in entry.forbidden {
                #expect(!redacted.contains(secret), "leaked \(secret) in \(redacted)")
            }
            #expect(redacted.contains("[REDACTED]"))
        }

        let preserved = "keyNotFound path=config.apiKey expected=Int"
        #expect(HostDiagnosticLog.redact(preserved) == preserved)
    }

    @Test("HostDiagnosticLog.describe formats DecodingError paths, redacts EncodingError without leaking value, and describes NSError")
    func describeErrorsWithPathsAndNoSecretLeaks() {
        struct Nested: Codable {
            struct Child: Codable { let title: String }
            let records: [Child]
        }

        let missingKeyJSON = Data(#"{"records":[{"other":"x"}]}"#.utf8)
        do {
            _ = try JSONDecoder().decode(Nested.self, from: missingKeyJSON)
            Issue.record("Expected keyNotFound")
        } catch {
            let text = HostDiagnosticLog.describe(error: error)
            #expect(text.contains("keyNotFound"))
            #expect(text.contains("records[0].title"))
            #expect(HostDiagnosticLog.errorCode(for: error) == "decoding_key_not_found")
        }

        let wrongTypeJSON = Data(#"{"records":[{"title":42}]}"#.utf8)
        do {
            _ = try JSONDecoder().decode(Nested.self, from: wrongTypeJSON)
            Issue.record("Expected typeMismatch")
        } catch {
            let text = HostDiagnosticLog.describe(error: error)
            #expect(text.contains("typeMismatch"))
            #expect(text.contains("records[0].title"))
            #expect(HostDiagnosticLog.errorCode(for: error) == "decoding_type_mismatch")
        }

        struct SecretCarrier: Encodable {
            let apiKey: String
            func encode(to encoder: any Encoder) throws {
                let container = encoder.container(keyedBy: CodingKeys.self)
                throw EncodingError.invalidValue(
                    apiKey,
                    EncodingError.Context(
                        codingPath: container.codingPath + [CodingKeys.apiKey],
                        debugDescription: "Cannot encode value for apiKey=\(apiKey)"
                    )
                )
            }
            enum CodingKeys: String, CodingKey { case apiKey }
        }

        do {
            _ = try JSONEncoder().encode(SecretCarrier(apiKey: "sk-supersecretvalue999"))
            Issue.record("Expected EncodingError.invalidValue")
        } catch {
            let text = HostDiagnosticLog.describe(error: error)
            #expect(text.contains("invalidValue"))
            #expect(text.contains("path=apiKey"))
            #expect(!text.contains("sk-supersecretvalue999"))
            #expect(HostDiagnosticLog.errorCode(for: error) == "encoding_invalid_value")
        }

        let nsErr = NSError(
            domain: "com.semanticcraft.test",
            code: 133,
            userInfo: [NSLocalizedDescriptionKey: "failed with Bearer secret_token_123"]
        )
        let nsText = HostDiagnosticLog.describe(error: nsErr)
        #expect(nsText.contains("com.semanticcraft.test"))
        #expect(nsText.contains("133"))
        #expect(!nsText.contains("secret_token_123"))
    }

    @Test("HostDiagnosticLog ring buffer caps entries and notifies injected test sink")
    func ringBufferCapsAndNotifiesSink() {
        let observed = OSAllocatedUnfairLock(initialState: [HostDiagnosticEntry]())
        let log = HostDiagnosticLog(maxCapacity: 3) { entry in
            observed.withLock { $0.append(entry) }
        }
        for idx in 1...5 {
            log.info(category: "test", event: "evt_\(idx)", detail: "detail_\(idx)")
        }
        let entries = log.recentEntries()
        #expect(entries.count == 3)
        #expect(entries.map(\.event) == ["evt_3", "evt_4", "evt_5"])
        #expect(observed.withLock(\.count) == 5)
    }

    @Test("HostSessionStore pinpoints exact failing field path in HostDiagnosticLog and HostTraceEntry.errorDetail")
    @MainActor
    func hostSessionStoreLogsExactDecodingFieldPath() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("koe-diag-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let diagnostics = HostDiagnosticLog()
        let store = HostSessionStore(workspacePath: directory.path, diagnostics: diagnostics)
        defer { store.shutdown() }

        let baselineTraceJSON = store.exportTraceJSON()
        #expect(!baselineTraceJSON.contains("errorDetail"))

        let wrongGenerationJSON = """
        {
          "version": 2,
          "generation": "oops",
          "section": "today",
          "canGoBack": false,
          "selectedRecordId": null,
          "focusSegmentId": null,
          "records": [],
          "detail": null,
          "tasks": [],
          "memories": [],
          "ask": { "scope": "all", "recordId": null, "phase": "idle", "messages": [] },
          "device": { "state": "未连接", "connected": false, "busy": false, "files": [], "progress": 0.0 },
          "provider": { "configured": false, "model": "qwen-plus" },
          "playback": { "recordId": null, "positionMs": 0, "isPlaying": false },
          "error": null,
          "notice": null
        }
        """
        let acceptedWrongType = store.loadDebugSnapshotFixtureJSON(wrongGenerationJSON)
        #expect(!acceptedWrongType)

        let typeDiag = try #require(diagnostics.recentEntries().last)
        #expect(typeDiag.level == "error")
        #expect(typeDiag.detail.contains("typeMismatch"))
        #expect(typeDiag.detail.contains("generation"))

        let typeTrace = try #require(store.recentTraceEntries.last)
        #expect(typeTrace.hasError)
        #expect(typeTrace.errorDetail?.contains("generation") == true)

        let missingRecordTitleJSON = """
        {
          "version": 2,
          "generation": 9,
          "section": "today",
          "canGoBack": false,
          "selectedRecordId": null,
          "focusSegmentId": null,
          "records": [
            {
              "id": "rec-1",
              "createdAtEpochSec": 1700000000,
              "durationMs": 1000,
              "source": "文本",
              "status": "已保存",
              "segmentCount": 0,
              "preview": ""
            }
          ],
          "detail": null,
          "tasks": [],
          "memories": [],
          "ask": { "scope": "all", "recordId": null, "phase": "idle", "messages": [] },
          "device": { "state": "未连接", "connected": false, "busy": false, "files": [], "progress": 0.0 },
          "provider": { "configured": false, "model": "qwen-plus" },
          "playback": { "recordId": null, "positionMs": 0, "isPlaying": false },
          "error": null,
          "notice": null
        }
        """
        let acceptedMissingKey = store.loadDebugSnapshotFixtureJSON(missingRecordTitleJSON)
        #expect(!acceptedMissingKey)

        let keyDiag = try #require(diagnostics.recentEntries().last)
        #expect(keyDiag.level == "error")
        #expect(keyDiag.detail.contains("keyNotFound"))
        #expect(keyDiag.detail.contains("records[0].title"))

        let keyTrace = try #require(store.recentTraceEntries.last)
        #expect(keyTrace.hasError)
        #expect(keyTrace.errorDetail?.contains("records[0].title") == true)
    }
}
