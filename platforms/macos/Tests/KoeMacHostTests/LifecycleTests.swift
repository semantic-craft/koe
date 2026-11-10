import AppKit
import Foundation
import KoeAppleShared
import Testing
@testable import Koe

@Suite("Activity and durable quit")
@MainActor
struct LifecycleTests {
    @Test("AppKit termination is intercepted before destroying the runtime")
    func interceptsSystemQuit() {
        let delegate: NSApplicationDelegate = KoeAppDelegate()
        #expect(delegate.responds(to: #selector(NSApplicationDelegate.applicationShouldTerminate(_:))),
                "Without applicationShouldTerminate AppKit quits immediately, even with owned audio or results")
    }

    @Test("Overlapping work owns one activity token until Rust reports idle")
    func activityOwnership() {
        var starts = 0
        var ends = 0
        let activity = NativeActivity(begin: { starts += 1; return NSObject() }, end: { _ in ends += 1 })
        activity.update(keepAwake: true)
        activity.update(keepAwake: true)
        activity.update(keepAwake: true)
        #expect(starts == 1)
        #expect(ends == 0)
        activity.update(keepAwake: false)
        activity.update(keepAwake: false)
        #expect(ends == 1)
    }

    @Test("AppKit receives one delayed reply only after durable ready")
    func delayedReply() {
        var replies: [Bool] = []
        var commands: [String] = []
        var coordinator: NativeQuitCoordinator!
        defer { coordinator = nil }
        coordinator = NativeQuitCoordinator(activity: NativeActivity(begin: { NSObject() }, end: { _ in }), send: {
            commands.append($0)
            coordinator.apply(LifecycleSnapshot(keepAwake: true, quitPhase: "draining"))
        }, reply: { replies.append($0) })
        #expect(coordinator.request() == .terminateLater)
        #expect(coordinator.request() == .terminateLater)
        #expect(commands == ["request_quit"])
        coordinator.apply(LifecycleSnapshot(keepAwake: true, quitPhase: "blocked", message: "保存失败"))
        #expect(replies.isEmpty)
        coordinator.apply(LifecycleSnapshot(keepAwake: false, quitPhase: "ready"))
        coordinator.apply(LifecycleSnapshot(keepAwake: false, quitPhase: "ready"))
        #expect(replies == [true])
    }

    @Test("Cancel replies false and late ready cannot terminate the app")
    func cancelledReply() {
        var replies: [Bool] = []
        var commands: [String] = []
        var coordinator: NativeQuitCoordinator!
        defer { coordinator = nil }
        coordinator = NativeQuitCoordinator(activity: NativeActivity(begin: { NSObject() }, end: { _ in }), send: {
            commands.append($0)
            coordinator.apply(LifecycleSnapshot(keepAwake: true, quitPhase: $0 == "cancel_quit" ? "running" : "draining"))
        }, reply: { replies.append($0) })
        #expect(coordinator.request() == .terminateLater)
        coordinator.cancel()
        coordinator.apply(LifecycleSnapshot(keepAwake: false, quitPhase: "ready"))
        #expect(commands == ["request_quit", "cancel_quit"])
        #expect(replies == [false])
        coordinator.shutdown()
    }

    @Test("Synchronous idle quit returns now without a premature delayed reply")
    func immediateReply() {
        var replies: [Bool] = []
        var coordinator: NativeQuitCoordinator!
        defer { coordinator = nil }
        coordinator = NativeQuitCoordinator(send: { _ in
            coordinator.apply(LifecycleSnapshot(keepAwake: false, quitPhase: "ready"))
        }, reply: { replies.append($0) })
        #expect(coordinator.request() == .terminateNow)
        #expect(replies.isEmpty)
    }

    @Test("Missing or undecodable fresh quit response cannot reuse cached ready")
    func failedSnapshot() {
        let coordinator = NativeQuitCoordinator(send: { _ in }, reply: { _ in Issue.record("Unexpected termination reply") })
        coordinator.apply(LifecycleSnapshot(keepAwake: false, quitPhase: "ready"))
        #expect(coordinator.request() == .terminateCancel)
    }

    @Test("Real Rust snapshots hold activity through audio save and delayed AppKit reply")
    func runtimeBridge() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("koe-quit-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = HostSessionStore(workspacePath: root.path)
        defer { store.shutdown() }
        var starts = 0
        var ends = 0
        var replies: [Bool] = []
        let activity = NativeActivity(begin: { starts += 1; return NSObject() }, end: { _ in ends += 1 })
        let coordinator = NativeQuitCoordinator(activity: activity, send: { store.send($0) }, reply: { replies.append($0) })
        store.onSnapshotChanged = { coordinator.apply($0.lifecycle) }
        defer { store.onSnapshotChanged = nil }
        store.ingestBleChunk(frame(group: 0x18, command: 0x81, payload: [0x93, 0x03, 0, 0]), nowEpochSec: 1_800_000_000)
        var opus: [UInt8] = [
            0x78, 0x81, 0xa7, 0x5d, 0x6c, 0x9e, 0x99, 0xac, 0x00, 0x00, 0x06, 0x7e, 0x56, 0x39, 0xf7, 0x3b,
    0x1e, 0xa2, 0xdc, 0x31, 0x0f, 0x52, 0x38, 0x39, 0x39, 0x3e, 0xa3, 0xd0, 0x84, 0x47, 0xcb, 0xe1,
    0xb6, 0xb8, 0xff, 0x44, 0x14, 0x3d, 0x76, 0x21, 0xaf, 0x07, 0x34, 0xdd, 0x07, 0x87, 0xec, 0x99,
    0xfe, 0xc0, 0xf5, 0x44, 0x18, 0x9d, 0x5f, 0x48, 0x29, 0x42, 0xde, 0xd8, 0x2f, 0x85, 0xb6, 0x18,
    0xf4, 0x3b, 0x64, 0x92, 0xde, 0x94, 0x70, 0x50, 0xe0, 0x97, 0x68, 0x7d, 0x6c, 0x10, 0xd0, 0xaf,
    0x63, 0x85, 0x53, 0xa2, 0x71, 0x65, 0xe7, 0x91, 0x29, 0x01, 0x80, 0x53, 0x15, 0x04,
        ]
        opus += Array(repeating: 0, count: 160 - opus.count)
        store.ingestBleChunk(frame(group: 0x1a, command: 0x08, payload: [0, 0, 0, 0, 0] + opus + [0]), nowEpochSec: 1_800_000_000)
        #expect(store.snapshot.records.count == 1)
        #expect(starts == 1)
        #expect(ends == 0)
        #expect(coordinator.request() == .terminateLater)
        store.ingestBleChunk(frame(group: 0x18, command: 0x82, payload: [0]), nowEpochSec: 1_800_000_001)
        #expect(replies.isEmpty)
        store.pollTimers(elapsedMs: 2_000, nowEpochSec: 1_800_000_003)
        #expect(store.snapshot.lifecycle?.quitPhase == "ready")
        #expect(replies == [true])
        #expect(ends == 1)
        let id = try #require(store.snapshot.records.first?.id)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("audio/\(id).opus").path))
        store.shutdown()
        let reopened = HostSessionStore(workspacePath: root.path)
        defer { reopened.shutdown() }
        #expect(reopened.snapshot.records.map(\.id) == [id])
    }

    private func frame(group: UInt8, command: UInt8, payload: [UInt8]) -> Data {
        let count = UInt16(payload.count + 10)
        var bytes: [UInt8] = [0x09, 0xff, 0, 0, 1, group, command, UInt8(count & 0xff), UInt8(count >> 8)] + payload
        bytes.append(bytes.reduce(0, &+))
        return Data(bytes)
    }
}
