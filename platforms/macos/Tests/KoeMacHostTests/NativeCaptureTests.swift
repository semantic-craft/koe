import XCTest
@testable import Koe

final class NativeCaptureTests: XCTestCase {
    func testStoppedProducerKeepsAcceptedTailUntilAcknowledged() {
        let box = MicrophoneMailbox(nextSequence: 0)
        box.append(CapturedPCM(samples: [1, 2], capturedStartNs: 0)); box.append(CapturedPCM(samples: [3, 4], capturedStartNs: 0)); box.close(); box.append(CapturedPCM(samples: [9], capturedStartNs: 0))
        XCTAssertEqual(box.finalSequence, 2)
        XCTAssertEqual(box.peek()?.pcm.samples, [1, 2])
        box.acknowledge(0)
        XCTAssertEqual(box.peek()?.pcm.samples, [3, 4])
        box.acknowledge(1)
        XCTAssertNil(box.peek())
    }
    func testBackpressurePreservesUnacknowledgedBlockAndBoundsQueue() {
        let box = MicrophoneMailbox(nextSequence: 0)
        for _ in 0..<65 { box.append(CapturedPCM(samples: [1], capturedStartNs: 0)) }
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

final class FakeMicrophone: MicrophoneSource {
    var permission: ((Bool) -> Void)?
    var receive: (([Int16]) -> Void)?
    var failure: ((String) -> Void)?
    var clockNs: UInt64 = 1_000_000_000
    var firstOffsetNs: UInt64 = 0
    var nextSampleNs: UInt64 = 0
    var sampleRate: UInt32 = 16000
    var emit: ((CapturedPCM) -> Void)?
    var permissionRequests = 0
    var starts = 0
    var tail: [Int16] = []
    var stopFailure: String?
    var startSamples: [Int16] = []
    var throwAfterStartSamples = false
    func requestPermission(_ completion: @escaping (Bool) -> Void) { permissionRequests += 1; permission = completion }
    func start(inputID: String, expectedSampleRate: UInt32?, receive: @escaping (CapturedPCM) -> Void, failed: @escaping (String) -> Void) throws -> UInt32 {
        starts += 1; emit = receive; failure = failed
        nextSampleNs = clockNs + firstOffsetNs
        self.receive = { [weak self] samples in
            guard let self else { return }
            receive(CapturedPCM(samples: samples, capturedStartNs: self.nextSampleNs))
            self.nextSampleNs += UInt64(samples.count) * 1_000_000_000 / UInt64(self.sampleRate)
        }
        if !startSamples.isEmpty { self.receive?(startSamples) }
        if throwAfterStartSamples { throw CaptureError("injected start failure after callback") }
        return sampleRate
    }
    func stop() {
        if !tail.isEmpty { let samples = tail; tail = []; receive?(samples) }
        if let stopFailure { self.stopFailure = nil; failure?(stopFailure) }
    }
}

@MainActor
final class NativeCaptureIntegrationTests: XCTestCase {
    func fixture(_ body: (HostSessionStore, FakeMicrophone, NativeCapture, URL) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("koe-native-mic-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = HostSessionStore(workspacePath: root.path)
        let source = FakeMicrophone()
        let capture = NativeCapture(source: source, nowNanoseconds: { source.clockNs })
        capture.store = store
        store.onSnapshotChanged = { _ in capture.apply() }
        defer {
            store.onSnapshotChanged = nil
            store.shutdown()
            try? FileManager.default.removeItem(at: root)
        }
        try await body(store, source, capture, root)
    }
    func awaitState(_ predicate: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !predicate(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertTrue(predicate(), "Expected final capture state before timeout", file: file, line: line)
    }
    func awaitRecording(_ store: HostSessionStore) async {
        await awaitState { store.snapshot.microphone?.phase == "recording" }
    }
    func testPauseDrainsAcceptedTailAndCanFinishQuit() async throws {
        try await fixture { store, source, capture, root in
            store.send("start_microphone", ["inputId": "fixture"])
            source.permission?(true)
            await self.awaitRecording(store)
            let id = try XCTUnwrap(store.snapshot.microphone?.recordId)
            source.receive?([1, 2]); source.tail = [3, 4]
            store.send("pause_microphone")
            capture.apply()
            XCTAssertEqual(store.snapshot.microphone?.phase, "paused")
            XCTAssertEqual(store.snapshot.microphone?.nextSequence, 2)
            store.send("request_quit")
            capture.apply()
            XCTAssertEqual(store.snapshot.lifecycle?.quitPhase, "ready")
            let bytes = try Data(contentsOf: root.appendingPathComponent("audio/\(id).wav"))
            XCTAssertEqual(Array(bytes.dropFirst(44)), [1, 0, 2, 0, 3, 0, 4, 0])
        }
    }
    func testLatePermissionAfterCancelCannotStartAnotherSession() async throws {
        try await fixture { store, source, _, _ in
            store.send("start_microphone", ["inputId": "fixture"])
            let late = source.permission
            store.send("cancel_microphone")
            XCTAssertNil(store.snapshot.microphone)
            store.send("start_microphone", ["inputId": "fixture"])
            late?(true)
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
            await self.awaitState { capture.apply(); return store.snapshot.microphone == nil }
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
            await self.awaitState { capture.apply(); return store.snapshot.microphone?.error != nil }
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
        let box = MicrophoneMailbox(nextSequence: 0)
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let stopped = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            guard fence.enter() else { return }
            entered.signal()
            release.wait()
            box.append(CapturedPCM(samples: [42], capturedStartNs: 0))
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
        XCTAssertEqual(box.peek()?.pcm.samples, [42])
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
            await self.awaitState { capture.apply(); return store.snapshot.microphone == nil }
            store.send("request_quit")
            XCTAssertEqual(source.starts, 1)
            XCTAssertTrue(store.snapshot.records.isEmpty)
            XCTAssertEqual(store.snapshot.lifecycle?.quitPhase, "ready")
            XCTAssertNil(store.snapshot.microphone)
        }
    }
}
