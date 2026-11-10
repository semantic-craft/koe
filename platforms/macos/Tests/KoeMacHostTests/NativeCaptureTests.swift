import XCTest
@testable import Koe

final class NativeCaptureTests: XCTestCase {
    func testStoppedProducerKeepsAcceptedTailUntilAcknowledged() {
        let box = MicrophoneMailbox()
        box.append([1, 2]); box.append([3, 4]); box.close(); box.append([9])
        XCTAssertEqual(box.finalSequence, 2)
        XCTAssertEqual(box.peek()?.samples, [1, 2])
        box.acknowledge(0)
        XCTAssertEqual(box.peek()?.samples, [3, 4])
        box.acknowledge(1)
        XCTAssertNil(box.peek())
    }
    func testBackpressurePreservesUnacknowledgedBlockAndBoundsQueue() {
        let box = MicrophoneMailbox()
        for _ in 0..<65 { box.append([1]) }
        XCTAssertEqual(box.finalSequence, 64)
        XCTAssertNotNil(box.error)
        box.acknowledge(9)
        XCTAssertEqual(box.peek()?.sequence, 0)
        box.close()
        for sequence in 0..<64 { box.acknowledge(UInt64(sequence)) }
        XCTAssertNil(box.peek())
    }
}

import KoeAppleShared

private final class FakeMicrophone: MicrophoneSource {
    var permission: ((Bool) -> Void)?
    var receive: (([Int16]) -> Void)?
    var failure: ((String) -> Void)?
    var starts = 0
    var tail: [Int16] = []
    var startSamples: [Int16] = []
    var throwAfterStartSamples = false
    func requestPermission(_ completion: @escaping (Bool) -> Void) { permission = completion }
    func start(inputID: String, receive: @escaping ([Int16]) -> Void, failed: @escaping (String) -> Void) throws -> UInt32 {
        starts += 1; self.receive = receive; failure = failed
        if !startSamples.isEmpty { receive(startSamples) }
        if throwAfterStartSamples { throw CaptureError("injected start failure after callback") }
        return 16000
    }
    func stop() {
        if !tail.isEmpty { let samples = tail; tail = []; receive?(samples) }
    }
}

@MainActor
final class NativeCaptureIntegrationTests: XCTestCase {
    private func fixture(_ body: (HostSessionStore, FakeMicrophone, NativeCapture, URL) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("koe-native-mic-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = HostSessionStore(workspacePath: root.path)
        let source = FakeMicrophone()
        let capture = NativeCapture(source: source)
        capture.store = store
        store.onSnapshotChanged = { _ in capture.apply() }
        defer {
            store.onSnapshotChanged = nil
            store.shutdown()
            try? FileManager.default.removeItem(at: root)
        }
        try await body(store, source, capture, root)
    }
    private func awaitRecording(_ store: HostSessionStore) async {
        for _ in 0..<100 where store.snapshot.microphone?.phase == "starting" { await Task.yield() }
        XCTAssertEqual(store.snapshot.microphone?.phase, "recording")
    }
    func testLatePermissionAfterCancelCannotStartAnotherSession() async throws {
        try await fixture { store, source, _, _ in
            store.send("start_microphone", ["inputId": "fixture"])
            let late = source.permission
            store.send("cancel_microphone")
            XCTAssertNil(store.snapshot.microphone)
            store.send("start_microphone", ["inputId": "fixture"])
            late?(true)
            for _ in 0..<10 { await Task.yield() }
            XCTAssertEqual(source.starts, 0)
            source.permission?(true)
            await self.awaitRecording(store)
            XCTAssertEqual(source.starts, 1)
        }
    }
    func testStopCallbackTailReachesRustBeforeQuitReady() async throws {
        try await fixture { store, source, capture, root in
            store.send("start_microphone", ["inputId": "fixture"])
            source.permission?(true)
            await self.awaitRecording(store)
            let id = try XCTUnwrap(store.snapshot.microphone?.recordId)
            source.receive?([1, 2]); source.tail = [3, 4]
            store.send("request_quit")
            capture.apply()
            XCTAssertEqual(store.snapshot.lifecycle?.quitPhase, "ready")
            XCTAssertEqual(store.snapshot.records.count, 1)
            let bytes = try Data(contentsOf: root.appendingPathComponent("audio/\(id).wav"))
            XCTAssertEqual(Array(bytes.dropFirst(44)), [1, 0, 2, 0, 3, 0, 4, 0])
        }
    }
    func testPermissionDenialHasNoSuccessfulRecord() async throws {
        try await fixture { store, source, capture, _ in
            store.send("start_microphone", ["inputId": "fixture"])
            source.permission?(false)
            for _ in 0..<100 where store.snapshot.microphone != nil { await Task.yield(); capture.apply() }
            XCTAssertNil(store.snapshot.microphone)
            XCTAssertTrue(store.snapshot.records.isEmpty)
            XCTAssertEqual(source.starts, 0)
            XCTAssertEqual(store.snapshot.lifecycle?.keepAwake, false)
        }
    }
    func testFailedMetadataSaveKeepsQuitBlockedUntilExplicitRetry() async throws {
        try await fixture { store, source, capture, root in
            store.send("start_microphone", ["inputId": "fixture"])
            source.permission?(true)
            await self.awaitRecording(store)
            source.receive?([1, 2]); capture.apply()
            let metadata = root.appendingPathComponent("product-workspace.json")
            if FileManager.default.fileExists(atPath: metadata.path) { try FileManager.default.removeItem(at: metadata) }
            try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: false)
            store.send("request_quit"); capture.apply()
            XCTAssertEqual(store.snapshot.lifecycle?.quitPhase, "blocked")
            XCTAssertTrue(store.snapshot.records.isEmpty)
            store.send("cancel_quit")
            XCTAssertNotNil(store.snapshot.microphone)
            try FileManager.default.removeItem(at: metadata)
            store.send("retry_microphone_save")
            XCTAssertNil(store.snapshot.microphone)
            XCTAssertEqual(store.snapshot.records.count, 1)
        }
    }
}

extension NativeCaptureIntegrationTests {
    func testSpoolCreationFailureCanRetryBufferedStartAudio() async throws {
        try await fixture { store, source, capture, root in
            let audio = root.appendingPathComponent("audio")
            try Data([0]).write(to: audio)
            source.startSamples = [7, 8]
            store.send("start_microphone", ["inputId": "fixture"])
            source.permission?(true)
            for _ in 0..<100 where source.starts == 0 { await Task.yield() }
            capture.apply()
            XCTAssertNotNil(store.snapshot.microphone?.error)
            XCTAssertTrue(store.snapshot.records.isEmpty)
            let id = try XCTUnwrap(store.snapshot.microphone?.recordId)
            try FileManager.default.removeItem(at: audio)
            store.send("retry_microphone_save")
            capture.apply()
            XCTAssertNil(store.snapshot.microphone)
            let bytes = try Data(contentsOf: root.appendingPathComponent("audio/\(id).wav"))
            XCTAssertEqual(Array(bytes.dropFirst(44)), [7, 0, 8, 0])
        }
    }
}

extension NativeCaptureTests {
    func testStopFenceWaitsForCallbackAlreadyConvertingSamples() {
        let fence = AudioCallbackFence()
        let box = MicrophoneMailbox()
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let stopped = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            guard fence.enter() else { return }
            entered.signal()
            release.wait()
            box.append([42])
            fence.leave()
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
        DispatchQueue.global().async {
            fence.closeAndWait()
            box.close()
            stopped.signal()
        }
        XCTAssertEqual(stopped.wait(timeout: .now() + 0.02), .timedOut)
        release.signal()
        XCTAssertEqual(stopped.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(box.peek()?.samples, [42])
        XCTAssertFalse(fence.enter())
    }
}


extension NativeCaptureIntegrationTests {
    func testStartFailureAfterCallbackDoesNotStrandQuit() async throws {
        try await fixture { store, source, capture, _ in
            source.startSamples = [7, 8]
            source.tail = [9, 10]
            source.throwAfterStartSamples = true
            store.send("start_microphone", ["inputId": "fixture"])
            source.permission?(true)
            for _ in 0..<100 where source.starts == 0 { await Task.yield() }
            capture.apply()
            store.send("request_quit")
            for _ in 0..<10 { capture.apply() }
            XCTAssertTrue(store.snapshot.records.isEmpty)
            XCTAssertEqual(store.snapshot.lifecycle?.quitPhase, "ready")
            XCTAssertNil(store.snapshot.microphone)
        }
    }
}
