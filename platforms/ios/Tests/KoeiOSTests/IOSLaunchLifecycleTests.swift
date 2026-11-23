import Foundation
import KoeAppleCore
import UIKit
import XCTest
@testable import KoeiOSApp

@MainActor
final class IOSLaunchLifecycleTests: XCTestCase {
    private var directory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    func testSavingAndOffscreenWorkBalanceBackgroundTasks() throws {
        let root = directory
        defer { try? FileManager.default.removeItem(at: root) }
        let store = HostSessionStore(workspacePath: root.path, credentials: NativeCredentialsiOS(forceIsolated: true))
        defer { store.shutdown() }
        var names: [String] = []
        var expired: [@MainActor () -> Void] = []
        var ended: [Int] = []
        let host = IOSHostCoordinator(store: store, actions: HostBridgeActions(), source: TestMicrophone(),
                                      allowsCoreBluetooth: false, allowsLocalSpeech: false, beginBackgroundTask: { name, callback in
            names.append(name)
            expired.append(callback)
            return UIBackgroundTaskIdentifier(rawValue: names.count)
        }, endBackgroundTask: { ended.append($0.rawValue) })
        defer { host.shutdown() }
        host.setScenePhase(.active)
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "ios-rich-snapshot", withExtension: "json"))
        var fixture = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        func publish(_ phase: String, keepAwake: Bool) throws {
            var capture = try XCTUnwrap(fixture["activeCapture"] as? [String: Any])
            capture["phase"] = phase
            fixture["activeCapture"] = capture
            fixture["lifecycle"] = ["keepAwake": keepAwake, "quitPhase": "idle"]
            let data = try JSONSerialization.data(withJSONObject: fixture)
            XCTAssertTrue(store.loadDebugSnapshotFixtureJSON(String(decoding: data, as: UTF8.self)))
        }
        try publish("saving", keepAwake: true)
        XCTAssertEqual(names, ["KoeSaveRecording"])
        try publish("recording", keepAwake: true)
        XCTAssertEqual(ended, [1])
        host.setScenePhase(.background)
        host.setScenePhase(.inactive)
        XCTAssertEqual(names.count, 2)
        try XCTUnwrap(expired.last)()
        host.setScenePhase(.background)
        XCTAssertEqual(names.count, 2)
        XCTAssertEqual(ended, [1, 2])
        host.setScenePhase(.active)
        host.setScenePhase(.background)
        try XCTUnwrap(expired.first)()
        host.shutdown()
        XCTAssertEqual(ended, [1, 2, 3])
    }

    func testPendingCaptureKeepsScreenAwakeAndServicesExpiredTrash() async throws {
        let root = directory
        let source = TestMicrophone()
        source.permission = nil
        let session = IOSLaunchSession(bridgeActions: HostBridgeActions(), arguments: ["Koe", "-koe-workspace", root.path],
                                       environment: [:], source: source, allowsCoreBluetooth: false)
        defer { session.shutdown() }
        addTeardownBlock { try FileManager.default.removeItem(at: root) }

        let store = session.store
        session.coordinator.setScenePhase(.background)
        let oldDate = UInt64(Date().timeIntervalSince1970) - 31 * 86_400
        store.send(.createNote(title: "旧记录", text: "正文"), nowEpochSec: oldDate)
        let id = try XCTUnwrap(store.snapshot.records.first?.id)
        store.send(.trashRecord(recordId: id), nowEpochSec: oldDate)
        store.send(.startCaptureMode(mode: .quickNote, stayOnPage: true), nowEpochSec: oldDate)
        let ticket = try XCTUnwrap(store.snapshot.microphone)
        XCTAssertEqual(store.lifecycle?.keepAwake, true)
        XCTAssertTrue(UIApplication.shared.isIdleTimerDisabled)
        XCTAssertEqual(store.snapshot.trashRecords.map(\.id), [id])

        let deadline = ContinuousClock.now + .seconds(2)
        while !store.snapshot.trashRecords.isEmpty && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertTrue(store.snapshot.trashRecords.isEmpty, "后台有未完成工作时应由宿主轮询清理过期记录")

        store.send(.microphoneFailed(recordId: ticket.recordId, sessionId: ticket.sessionId,
                                     lane: ticket.lane, message: "测试结束"))
        store.send(.microphoneStopped(recordId: ticket.recordId, sessionId: ticket.sessionId,
                                      lane: ticket.lane, sequence: 0))
        XCTAssertEqual(store.lifecycle?.keepAwake, false)
        XCTAssertFalse(UIApplication.shared.isIdleTimerDisabled)

        store.send(.createNote(title: "第二条", text: "正文"), nowEpochSec: oldDate)
        let nextID = try XCTUnwrap(store.snapshot.records.first?.id)
        store.send(.trashRecord(recordId: nextID), nowEpochSec: oldDate)
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(store.snapshot.trashRecords.map(\.id), [nextID], "空闲后台应停止轮询")

        session.coordinator.setScenePhase(.active)
        let foregroundDeadline = ContinuousClock.now + .seconds(2)
        while !store.trashRecords.isEmpty && ContinuousClock.now < foregroundDeadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertTrue(store.trashRecords.isEmpty, "回到前台后应恢复轮询并发布到界面")
    }

    func testSnapshotReadWithNoStateChangeStillReachesTraceFile() async throws {
        let root = directory
        let output = root.appendingPathComponent("trace.json")
        let session = IOSLaunchSession(bridgeActions: HostBridgeActions(), arguments: [
            "Koe", "-koe-workspace", root.appendingPathComponent("workspace").path,
            "-koe-trace-output", output.path,
        ], environment: [:], allowsCoreBluetooth: false)
        addTeardownBlock {
            await IOSLaunchSession.flushTraceQueue()
            try FileManager.default.removeItem(at: root)
        }

        let nowEpochSec = UInt64(Date().timeIntervalSince1970)
        session.store.refreshSnapshot(nowEpochSec: nowEpochSec)
        let snapshot = session.store.snapshot
        session.store.reportNativeError("测试追踪快照")
        session.store.refreshSnapshot(nowEpochSec: nowEpochSec)
        XCTAssertEqual(session.store.snapshot, snapshot)
        XCTAssertEqual(session.store.recentTraceEntries.last?.kind, "snapshot")

        session.shutdown()
        let expected = session.store.recentTraceEntries
        await IOSLaunchSession.flushTraceQueue()
        let entries = try JSONDecoder().decode([HostTraceEntry].self, from: Data(contentsOf: output))
        XCTAssertEqual(entries, expected, "快照未变时也应保留最后一次追踪事件")
    }

    func testTraceWriteFailureDoesNotPolluteUserErrorBar() async throws {
        let root = directory
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock {
            await IOSLaunchSession.flushTraceQueue()
            try FileManager.default.removeItem(at: root)
        }
        let session = IOSLaunchSession(bridgeActions: HostBridgeActions(), arguments: [
            "Koe", "-koe-workspace", root.appendingPathComponent("workspace").path,
            "-koe-trace-output", root.path,
        ], environment: [:], allowsCoreBluetooth: false)
        defer { session.shutdown() }

        await IOSLaunchSession.flushTraceQueue()
        XCTAssertNil(session.store.nativeError)
        XCTAssertNil(session.store.navigation.effectiveError)
    }
}
