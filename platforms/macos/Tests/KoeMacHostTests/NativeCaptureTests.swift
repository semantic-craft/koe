import XCTest
@testable import Koe
@testable import KoeAppleCore

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
    func testRingBufferWraparoundPreservesFIFOAcrossCycles() {
        let box = MicrophoneMailbox(nextSequence: 10, limit: 4)
        for index in 0..<10 {
            let expectedSeq = UInt64(10 + index)
            box.append(CapturedPCM(samples: [Int16(index)], capturedStartNs: UInt64(index) * 100))
            XCTAssertEqual(box.peek()?.sequence, expectedSeq)
            XCTAssertEqual(box.peek()?.pcm.samples, [Int16(index)])
            box.acknowledge(expectedSeq)
            XCTAssertNil(box.peek())
        }
        for index in 10..<14 {
            box.append(CapturedPCM(samples: [Int16(index)], capturedStartNs: 0))
        }
        XCTAssertNil(box.error)
        XCTAssertEqual(box.finalSequence, 24)
        box.acknowledge(20)
        box.acknowledge(21)
        box.append(CapturedPCM(samples: [99], capturedStartNs: 0))
        XCTAssertNil(box.error)
        XCTAssertEqual(box.peek()?.sequence, 22)
    }
}

final class FakeMicrophone: MicrophoneSource, @unchecked Sendable {
    var permission: (@Sendable (Bool) -> Void)?
    var receive: (([Int16]) -> Void)?
    var failure: (@Sendable (String) -> Void)?
    var clockNs: UInt64 = 1_000_000_000
    var firstOffsetNs: UInt64 = 0
    var nextSampleNs: UInt64 = 0
    var sampleRate: UInt32 = 16000
    var emit: (@Sendable (CapturedPCM) -> Void)?
    var permissionRequests = 0
    var starts = 0
    var tail: [Int16] = []
    var stopFailure: String?
    var startSamples: [Int16] = []
    var throwAfterStartSamples = false
    func requestPermission(_ completion: @escaping @Sendable (Bool) -> Void) { permissionRequests += 1; permission = completion }
    func start(inputID: String, expectedSampleRate: UInt32?, receive: @escaping @Sendable (CapturedPCM) -> Void, failed: @escaping @Sendable (String) -> Void) throws -> UInt32 {
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
    func fixture(_ body: @MainActor (HostSessionStore, FakeMicrophone, NativeCapture, URL) async throws -> Void) async throws {
        try await dualFixture { store, microphone, _, capture, root in try await body(store, microphone, capture, root) }
    }
    func dualFixture(_ body: @MainActor (HostSessionStore, FakeMicrophone, FakeSystemAudio, NativeCapture, URL) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("koe-native-mic-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = HostSessionStore(workspacePath: root.path)
        let source = FakeMicrophone()
        let system = FakeSystemAudio()
        system.clock = { source.clockNs }
        let capture = NativeCapture(source: source, systemSource: system, nowNanoseconds: { source.clockNs })
        capture.store = store
        store.onSnapshotChanged = { _ in capture.apply() }
        defer {
            store.onSnapshotChanged = nil
            store.shutdown()
            try? FileManager.default.removeItem(at: root)
        }
        try await body(store, source, system, capture, root)
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
            store.send(.startCaptureMode(mode: .quickNote, stayOnPage: true))
            source.permission?(true)
            await self.awaitRecording(store)
            let id = try XCTUnwrap(store.snapshot.microphone?.recordId)
            source.receive?([1, 2]); source.tail = [3, 4]
            store.send(.captureAction(action: .pause))
            capture.apply()
            XCTAssertEqual(store.snapshot.microphone?.phase, "paused")
            XCTAssertEqual(store.snapshot.microphone?.nextSequence, 2)
            store.send(.requestQuit)
            capture.apply()
            XCTAssertEqual(store.snapshot.lifecycle?.quitPhase, "ready")
            let bytes = try Data(contentsOf: root.appendingPathComponent("audio/\(id).wav"))
            XCTAssertEqual(Array(bytes.dropFirst(44)), [1, 0, 2, 0, 3, 0, 4, 0])
        }
    }
    func testLatePermissionAfterCancelCannotStartAnotherSession() async throws {
        try await fixture { store, source, _, _ in
            store.send(.startCaptureMode(mode: .quickNote, stayOnPage: true))
            let late = source.permission
            store.send(.captureAction(action: .cancel))
            XCTAssertNil(store.snapshot.microphone)
            store.send(.startCaptureMode(mode: .quickNote, stayOnPage: true))
            late?(true)
            source.permission?(true)
            await self.awaitRecording(store)
            XCTAssertEqual(source.starts, 1)
        }
    }
    func testStopCallbackTailReachesRustBeforeQuitReady() async throws {
        try await fixture { store, source, capture, root in
            store.send(.startCaptureMode(mode: .quickNote, stayOnPage: true))
            source.permission?(true)
            await self.awaitRecording(store)
            let id = try XCTUnwrap(store.snapshot.microphone?.recordId)
            source.receive?([1, 2]); source.tail = [3, 4]
            store.send(.requestQuit)
            capture.apply()
            XCTAssertEqual(store.snapshot.lifecycle?.quitPhase, "ready")
            XCTAssertEqual(store.snapshot.records.count, 1)
            let bytes = try Data(contentsOf: root.appendingPathComponent("audio/\(id).wav"))
            XCTAssertEqual(Array(bytes.dropFirst(44)), [1, 0, 2, 0, 3, 0, 4, 0])
        }
    }
    func testPermissionDenialHasNoSuccessfulRecord() async throws {
        try await fixture { store, source, capture, _ in
            store.send(.startCaptureMode(mode: .quickNote, stayOnPage: true))
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
            store.send(.startCaptureMode(mode: .quickNote, stayOnPage: true))
            source.permission?(true)
            await self.awaitRecording(store)
            let id = try XCTUnwrap(store.snapshot.microphone?.recordId)
            source.receive?([1, 2]); capture.apply()
            let metadata = root.appendingPathComponent("product-workspace.json")
            try FileManager.default.removeItem(at: metadata)
            try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: false)
            store.send(.requestQuit); capture.apply()
            XCTAssertEqual(store.snapshot.lifecycle?.quitPhase, "blocked")
            XCTAssertEqual(store.snapshot.records.map(\.id), [id])
            store.send(.cancelQuit)
            XCTAssertEqual(store.snapshot.lifecycle?.quitPhase, "running")
            try FileManager.default.removeItem(at: metadata)
            store.pollTimers(elapsedMs: 250)
            XCTAssertEqual(store.snapshot.microphone?.recordId, id)
            XCTAssertFalse(FileManager.default.fileExists(atPath: metadata.path))
            store.send(.captureAction(action: .retrySave))
            XCTAssertNil(store.snapshot.microphone)
            XCTAssertEqual(store.snapshot.records.map(\.id), [id])
            let saved = try SavedCapture.read(root)
            XCTAssertEqual(saved.captureLanes.first?.timeline.first?.sampleCount, 2)
            let bytes = try Data(contentsOf: root.appendingPathComponent("audio/\(id).wav"))
            XCTAssertEqual(Array(bytes.dropFirst(44)), [1, 0, 2, 0])
        }
    }
}

extension NativeCaptureIntegrationTests {
    func testSpoolCreationFailureCanRetryBufferedStartAudio() async throws {
        try await fixture { store, source, capture, root in
            let audio = root.appendingPathComponent("audio")
            try Data([0]).write(to: audio)
            source.startSamples = [7, 8]
            store.send(.startCaptureMode(mode: .quickNote, stayOnPage: true))
            source.permission?(true)
            await self.awaitState { capture.apply(); return store.snapshot.microphone?.error != nil }
            XCTAssertNotNil(store.snapshot.microphone?.error)
            XCTAssertTrue(store.snapshot.records.isEmpty)
            let id = try XCTUnwrap(store.snapshot.microphone?.recordId)
            try FileManager.default.removeItem(at: audio)
            store.send(.captureAction(action: .retrySave))
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

    func testConcurrentCloseAndWaitBothUnblockWhenLeaveFinishes() {
        let fence = AudioCallbackFence()
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let firstWaiting = DispatchSemaphore(value: 0)
        let secondWaiting = DispatchSemaphore(value: 0)
        let firstDone = DispatchSemaphore(value: 0)
        let secondDone = DispatchSemaphore(value: 0)

        DispatchQueue.global().async {
            guard fence.enter() else { return }
            entered.signal()
            release.wait()
            fence.leave()
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)

        DispatchQueue.global().async {
            firstWaiting.signal()
            fence.closeAndWait()
            firstDone.signal()
        }
        DispatchQueue.global().async {
            secondWaiting.signal()
            fence.closeAndWait()
            secondDone.signal()
        }

        XCTAssertEqual(firstWaiting.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(secondWaiting.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(firstDone.wait(timeout: .now() + 0.02), .timedOut)
        XCTAssertEqual(secondDone.wait(timeout: .now() + 0.02), .timedOut)

        release.signal()
        XCTAssertEqual(firstDone.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(secondDone.wait(timeout: .now() + 2), .success)
    }
}


extension NativeCaptureIntegrationTests {
    func testStartFailureAfterCallbackDoesNotStrandQuit() async throws {
        try await fixture { store, source, capture, _ in
            source.startSamples = [7, 8]
            source.tail = [9, 10]
            source.throwAfterStartSamples = true
            store.send(.startCaptureMode(mode: .quickNote, stayOnPage: true))
            source.permission?(true)
            await self.awaitState { capture.apply(); return store.snapshot.microphone == nil }
            store.send(.requestQuit)
            XCTAssertEqual(source.starts, 1)
            XCTAssertTrue(store.snapshot.records.isEmpty)
            XCTAssertEqual(store.snapshot.lifecycle?.quitPhase, "ready")
            XCTAssertNil(store.snapshot.microphone)
        }
    }
}

/// Deterministic system audio lane: never touches Core Audio taps or TCC.
final class FakeSystemAudio: SystemAudioSource {
    var authorization: (@Sendable (SystemAudioAuthResult) -> Void)?
    var shouldAbort: (@Sendable () -> Bool)?
    var emit: (@Sendable (CapturedPCM) -> Void)?
    var failure: (@Sendable (String) -> Void)?
    var clock: () -> UInt64 = { 1_000_000_000 }
    var firstOffsetNs: UInt64 = 0
    var nextSampleNs: UInt64 = 0
    var sampleRate: UInt32 = 48_000
    var authorizations = 0
    var starts = 0
    var stops = 0
    var tail: [Int16] = []
    func authorize(shouldAbort: @escaping @Sendable () -> Bool,
                   _ completion: @escaping @Sendable (SystemAudioAuthResult) -> Void) {
        authorizations += 1
        self.shouldAbort = shouldAbort
        authorization = completion
    }
    func start(expectedSampleRate: UInt32?, receive: @escaping @Sendable (CapturedPCM) -> Void,
               failed: @escaping @Sendable (String) -> Void) throws -> UInt32 {
        starts += 1
        emit = receive
        failure = failed
        nextSampleNs = clock() + firstOffsetNs
        return sampleRate
    }
    func receive(_ samples: [Int16]) {
        emit?(CapturedPCM(samples: samples, capturedStartNs: nextSampleNs))
        nextSampleNs += UInt64(samples.count) * 1_000_000_000 / UInt64(sampleRate)
    }
    func stop() {
        stops += 1
        if !tail.isEmpty { let samples = tail; tail = []; receive(samples) }
    }
}

extension NativeCaptureIntegrationTests {
    nonisolated func pcm(_ root: URL, _ asset: String) throws -> [UInt8] {
        Array(try Data(contentsOf: root.appendingPathComponent("audio/\(asset).wav")).dropFirst(44))
    }

    func testSingleLaneDenialKeepsTheOtherLaneRecordingInBothDirections() async throws {
        for denied in ["system", "microphone"] {
            try await dualFixture { store, microphone, system, capture, root in
                store.send(.setCaptureSystemAudio(enabled: true)); store.send(.startCaptureMode(mode: .quickNote, stayOnPage: true))
                XCTAssertEqual(store.snapshot.microphone?.lanes.keys.sorted(), ["microphone", "system"])
                microphone.permission?(denied != "microphone")
                system.authorization?(denied == "system" ? .denied(SystemAudioCanaryEvaluator.deniedMessage) : .authorized)
                await self.awaitState { store.snapshot.microphone?.lanes[denied]?.stopped == true
                    && store.snapshot.microphone?.phase == "recording" }
                XCTAssertEqual(microphone.starts, denied == "microphone" ? 0 : 1)
                XCTAssertEqual(system.starts, denied == "system" ? 0 : 1)
                XCTAssertNotNil(store.snapshot.activeCapture?.error, "incomplete capture must stay visible")
                let id = try XCTUnwrap(store.snapshot.microphone?.recordId)
                if denied == "system" { microphone.receive?([1, 2]) } else { system.receive([3, 4]) }
                capture.apply()
                store.send(.captureAction(action: .end))
                XCTAssertNil(store.snapshot.microphone)
                let lanes = try SavedCapture.read(root).captureLanes
                XCTAssertEqual(lanes.count, 2)
                let healthyAsset = denied == "system" ? id : "\(id)-system"
                XCTAssertEqual(try self.pcm(root, healthyAsset), denied == "system" ? [1, 0, 2, 0] : [3, 0, 4, 0])
                XCTAssertEqual(lanes.filter { $0.interruption != nil }.count, 1)
                store.send(.selectRecord(recordId: id))
                XCTAssertEqual(store.snapshot.detail?.status, "采集不完整")
            }
        }
    }

    func testOutputSwitchStopsOnlySystemLaneWithoutLosingAcceptedAudio() async throws {
        try await dualFixture { store, microphone, system, capture, root in
            store.send(.setCaptureSystemAudio(enabled: true)); store.send(.startCaptureMode(mode: .quickNote, stayOnPage: true))
            microphone.permission?(true)
            system.authorization?(.authorized)
            await self.awaitRecording(store)
            let id = try XCTUnwrap(store.snapshot.microphone?.recordId)
            system.receive([2, 2]); microphone.receive?([1, 1]); capture.apply()
            system.receive([5, 5])
            system.failure?("系统音频输出设备发生变化，已停止系统音频采集并保留此前收到的音频。")
            capture.apply()
            XCTAssertEqual(store.snapshot.microphone?.phase, "recording")
            XCTAssertEqual(store.snapshot.microphone?.lanes["system"]?.stopped, true)
            XCTAssertEqual(store.snapshot.microphone?.lanes["system"]?.nextSequence, 2)
            XCTAssertGreaterThanOrEqual(system.stops, 1)
            microphone.receive?([3, 3]); capture.apply()
            store.send(.requestQuit)
            XCTAssertEqual(store.snapshot.lifecycle?.quitPhase, "ready")
            XCTAssertEqual(try self.pcm(root, id), [1, 0, 1, 0, 3, 0, 3, 0])
            XCTAssertEqual(try self.pcm(root, "\(id)-system"), [2, 0, 2, 0, 5, 0, 5, 0])
            let lanes = try SavedCapture.read(root).captureLanes
            XCTAssertNil(lanes[0].interruption)
            XCTAssertTrue(lanes[1].interruption?.contains("输出设备") == true)
        }
    }

    func testCancelAbortsPendingSystemAuthorizationAndLateGrantStartsNothing() async throws {
        try await dualFixture { store, microphone, system, _, _ in
            store.send(.setCaptureSystemAudio(enabled: true)); store.send(.startCaptureMode(mode: .quickNote, stayOnPage: true))
            microphone.permission?(true)
            await Task.yield()
            XCTAssertEqual(store.snapshot.microphone?.phase, "starting")
            XCTAssertEqual(system.shouldAbort?(), false)
            store.send(.captureAction(action: .cancel))
            XCTAssertNil(store.snapshot.microphone)
            XCTAssertEqual(system.shouldAbort?(), true)
            system.authorization?(.authorized)
            await Task.yield()
            XCTAssertEqual(microphone.starts + system.starts, 0)
            XCTAssertTrue(store.snapshot.records.isEmpty)
        }
    }
}
