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

    func testPendingCaptureKeepsScreenAwakeAndServicesExpiredTrash() async throws {
        let root = directory
        let session = IOSLaunchSession(bridgeActions: HostBridgeActions(), arguments: ["Koe", "-koe-workspace", root.path], environment: [:])
        defer { session.shutdown() }
        addTeardownBlock { try FileManager.default.removeItem(at: root) }

        let store = session.store
        session.coordinator.setScenePhase(.background)
        let oldDate = UInt64(Date().timeIntervalSince1970) - 31 * 86_400
        store.send(.createNote(title: "旧记录", text: "正文"), nowEpochSec: oldDate)
        let id = try XCTUnwrap(store.snapshot.records.first?.id)
        store.send(.trashRecord(recordId: id), nowEpochSec: oldDate)
        store.send(.startMicrophone(inputId: "fixture"), nowEpochSec: oldDate)
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
        ], environment: [:])
        defer { session.shutdown() }
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }

        session.store.refreshSnapshot()
        let expected = session.store.recentTraceEntries
        let deadline = ContinuousClock.now + .seconds(1)
        var entries: [HostTraceEntry]
        repeat {
            entries = try JSONDecoder().decode([HostTraceEntry].self, from: Data(contentsOf: output))
            if entries == expected { break }
            try await Task.sleep(for: .milliseconds(25))
        } while ContinuousClock.now < deadline
        XCTAssertEqual(entries.count, expected.count, "快照未变时也应保留最后一次追踪事件")
        XCTAssertEqual(entries.last, expected.last)
    }

    func testTraceWriteFailureReachesStore() throws {
        let root = directory
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        let session = IOSLaunchSession(bridgeActions: HostBridgeActions(), arguments: [
            "Koe", "-koe-workspace", root.appendingPathComponent("workspace").path,
            "-koe-trace-output", root.path,
        ], environment: [:])
        defer { session.shutdown() }

        XCTAssertTrue(session.store.nativeError?.contains("追踪") == true)
    }
}
