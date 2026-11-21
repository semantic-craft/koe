import Foundation
import KoeAppleCore
@testable import KoeiOSApp
import XCTest

@MainActor
final class KoeiOSHostTests: XCTestCase {
    func testRealRustHostSessionAndIOSMetadata() {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("koe-ios-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        XCTAssertEqual(HostSessionStore.apiVersion(), 2)

        let credentials = NativeCredentialsiOS(forceIsolated: true)
        let store = HostSessionStore(workspacePath: workspace.path, credentials: credentials)
        defer { store.shutdown() }

        XCTAssertNotEqual(store.handle, 0)
        store.send(
            .syncAppMetadata(
                version: "2.6.0",
                build: "15",
                platform: "ios",
                hostDisplayName: "iPhone",
                supportsSystemAudio: false,
                supportsSelfUpdate: false,
                nativeSpeechLabel: "Apple 本机"
            )
        )

        XCTAssertEqual(store.platform.id, "ios")
        XCTAssertEqual(store.platform.hostDisplayName, "iPhone")
        XCTAssertFalse(store.platform.supportsSystemAudio)
        XCTAssertFalse(store.platform.supportsSelfUpdate)
        XCTAssertEqual(store.platform.nativeSpeechLabel, "Apple 本机")
        XCTAssertFalse(store.captureStudio.studio.canIncludeSystemAudio)
    }

    func testCreateNoteTrashAndRestoreRoundTrip() throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("koe-ios-roundtrip-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let credentials = NativeCredentialsiOS(forceIsolated: true)
        let store = HostSessionStore(workspacePath: workspace.path, credentials: credentials)
        defer { store.shutdown() }

        store.send(.createNote(title: "iOS 闪记验收", text: "测试真实 Rust 写入与回收站恢复。", stayOnPage: true))
        let created = try XCTUnwrap(store.records.first(where: { $0.title == "iOS 闪记验收" }))
        XCTAssertEqual(store.records.count, 1)

        store.send(.trashRecord(recordId: created.id))
        XCTAssertTrue(store.records.isEmpty)
        XCTAssertEqual(store.trashRecords.map(\.id), [created.id])
        XCTAssertEqual(store.navigation.undoTrash?.recordId, created.id)

        store.send(.restoreRecord(recordId: created.id))
        XCTAssertEqual(store.records.map(\.id), [created.id])
        XCTAssertTrue(store.trashRecords.isEmpty)
    }

    func testNativeCredentialsiOSIsolatedLifecycleAndInvalidRefRejection() throws {
        let credentials = NativeCredentialsiOS(forceIsolated: true)
        XCTAssertTrue(credentials.isolated)

        let qwenRef = try XCTUnwrap(try credentials.perform(operation: 5, reference: "qwen", value: "sk-qwen-test"))
        XCTAssertTrue(qwenRef.hasPrefix("isolated-"))
        let createdQwen = try credentials.perform(operation: 1, reference: qwenRef, value: "sk-qwen-test")
        XCTAssertEqual(createdQwen, qwenRef)
        XCTAssertEqual(try credentials.perform(operation: 0, reference: qwenRef, value: ""), "sk-qwen-test")

        let deepseekRef = try XCTUnwrap(try credentials.perform(operation: 5, reference: "deepseek", value: "sk-ds-test"))
        XCTAssertEqual(try credentials.perform(operation: 1, reference: deepseekRef, value: "sk-ds-test"), deepseekRef)
        XCTAssertEqual(try credentials.perform(operation: 0, reference: deepseekRef, value: ""), "sk-ds-test")

        XCTAssertEqual(try credentials.perform(operation: 4, reference: qwenRef, value: ""), "")
        XCTAssertNil(try credentials.perform(operation: 3, reference: "", value: ""))

        XCTAssertEqual(try credentials.perform(operation: 2, reference: qwenRef, value: ""), "")
        XCTAssertNil(try credentials.perform(operation: 0, reference: qwenRef, value: ""))

        XCTAssertThrowsError(try credentials.perform(operation: 1, reference: "bad-ref", value: "secret")) { error in
            XCTAssertEqual(error as? NativeCredentialsiOS.Failure, .invalidReference)
        }
        XCTAssertThrowsError(try credentials.perform(operation: 0, reference: "bad-ref", value: "")) { error in
            XCTAssertEqual(error as? NativeCredentialsiOS.Failure, .invalidReference)
        }
        XCTAssertThrowsError(try credentials.perform(operation: 2, reference: "bad-ref", value: "")) { error in
            XCTAssertEqual(error as? NativeCredentialsiOS.Failure, .invalidReference)
        }
        XCTAssertThrowsError(try credentials.perform(operation: 99, reference: qwenRef, value: "")) { error in
            XCTAssertEqual(error as? NativeCredentialsiOS.Failure, .unsupportedOperation)
        }

        let envCredentials = NativeCredentialsiOS(
            forceIsolated: true,
            environment: [
                "KOE_CREDENTIAL_SOURCE": "environment",
                "DASHSCOPE_API_KEY": "sk-env-qwen",
                "DEEPSEEK_API_KEY": "sk-env-ds",
            ]
        )
        let legacyPayload = try XCTUnwrap(try envCredentials.perform(operation: 3, reference: "", value: ""))
        XCTAssertTrue(legacyPayload.contains("sk-env-qwen"))
        XCTAssertTrue(legacyPayload.contains("sk-env-ds"))
    }

    func testLaunchSessionLoadsRichFixtureAndWritesSecretFreeTrace() async throws {
        let fixtureURL = try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: "ios-rich-snapshot", withExtension: "json")
        )
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("koe-ios-launch-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let workspaceDir = tempDir.appendingPathComponent("workspace", isDirectory: true)
        let traceURL = tempDir.appendingPathComponent("trace.json")

        let session = IOSLaunchSession(
            bridgeActions: HostBridgeActions(),
            arguments: [
                "Koe",
                "-koe-workspace", workspaceDir.path,
                "-koe-snapshot-fixture", fixtureURL.path,
                "-koe-trace-output", traceURL.path,
            ],
            environment: [:], allowsCoreBluetooth: false
        )
        defer { session.shutdown() }

        XCTAssertEqual(session.store.platform.hostDisplayName, "iPhone")
        XCTAssertEqual(session.store.device.deviceName, "Soundcore Work")
        XCTAssertEqual(session.store.device.batteryPercent, 85)
        XCTAssertEqual(session.store.device.boxBatteryPercent, 72)
        XCTAssertEqual(session.store.records.count, 2)
        XCTAssertEqual(session.store.ask.messages.count, 2)
        XCTAssertNotNil(session.store.activeCapture)
        XCTAssertNotNil(session.store.liveCaption)

        let secret = "sk-should-never-appear-in-trace"
        session.store.send(.configureProvider(apiKey: secret, model: "deepseek-flash"))

        let expected = session.store.recentTraceEntries
        let deadline = ContinuousClock.now + .seconds(2)
        var traceText = ""
        repeat {
            traceText = (try? String(contentsOf: traceURL, encoding: .utf8)) ?? ""
            if (try? JSONDecoder().decode([HostTraceEntry].self, from: Data(traceText.utf8))) == expected { break }
            try await Task.sleep(for: .milliseconds(20))
        } while ContinuousClock.now < deadline
        XCTAssertFalse(traceText.contains(secret))
        XCTAssertFalse(traceText.contains("iOS 架构同步会"))
        let entries = try JSONDecoder().decode([HostTraceEntry].self, from: Data(traceText.utf8))
        XCTAssertEqual(entries, expected)
        XCTAssertTrue(entries.contains(where: { $0.kind == "fixture" && $0.name == "fixture" }))
    }
}
