import AVFoundation
import KoeMacUI
import XCTest
@testable import Koe

@MainActor
private final class ControlledSpeechSession: LocalSpeechSession {
    var samples: [Int16] = []
    var result: ((Result<LocalSpeechResult, Error>) -> Void)?
    var finishStarted = false
    var holdFinish = false
    var finishWaiter: CheckedContinuation<Void, Never>?
    var cancelled = false
    var appendError: Error?
    var reader: Task<Void, Never>?

    func append(_ samples: [Int16]) throws {
        if let appendError { throw appendError }
        self.samples.append(contentsOf: samples)
    }

    func finish() async throws {
        finishStarted = true
        if holdFinish { await withCheckedContinuation { finishWaiter = $0 } }
        if cancelled { throw CancellationError() }
        result?(.success(LocalSpeechResult(text: "最后一句", startMs: 0, endMs: 800, isFinal: true)))
    }

    func failReader() {
        reader = Task { @MainActor in
            do { throw LocalSpeechError("系统识别任务已中断") }
            catch { result?(.failure(error)) }
        }
    }

    func cancel() async {
        cancelled = true
        finishWaiter?.resume()
        finishWaiter = nil
        await reader?.value
    }
}

@MainActor
private final class ControlledSpeechRecognizer: LocalSpeechRecognizer {
    var sessions: [ControlledSpeechSession] = []
    var configure: ((ControlledSpeechSession) -> Void)?
    var holdPreparation = false
    var prepareWaiter: CheckedContinuation<Void, Never>?
    var prepared = false
    func prepare() async throws {
        if holdPreparation { await withCheckedContinuation { prepareWaiter = $0 } }
        prepared = true
    }
    func start(locale: String, result: @escaping @MainActor (Result<LocalSpeechResult, Error>) -> Void) async throws -> any LocalSpeechSession {
        let session = ControlledSpeechSession()
        session.result = result
        configure?(session)
        sessions.append(session)
        return session
    }
}

@MainActor
final class NativeLocalTranscriptionTests: XCTestCase {
    private func data(_ effects: [[String: Any]]) -> Data {
        var out = Data()
        for effect in effects {
            let kind = effect["kind"] as? String ?? ""
            let opId = UInt64((effect["operationId"] as? NSNumber)?.uint64Value ?? 0)
            var opLe = opId.littleEndian
            let opBytes = Data(bytes: &opLe, count: 8)
            let tag: UInt8
            var payload = Data()
            switch kind {
            case "start":
                tag = 1
                payload = Data((effect["locale"] as? String ?? "zh-CN").utf8)
            case "audio":
                tag = 2
                for sample in (effect["pcm16"] as? [Int]) ?? [] {
                    var s = Int16(sample).littleEndian
                    payload.append(Data(bytes: &s, count: 2))
                }
            case "finish":
                tag = 3
            case "cancel":
                tag = 4
            default:
                fatalError("unknown effect kind \(kind)")
            }
            var lenLe = UInt32(payload.count).littleEndian
            out.append(tag)
            out.append(opBytes)
            out.append(Data(bytes: &lenLe, count: 4))
            out.append(payload)
        }
        return out
    }

    func testStartWaitsForReadinessAndKeepsQueuedAudio() async throws {
        let recognizer = ControlledSpeechRecognizer()
        recognizer.holdPreparation = true
        let effects = data([
            ["kind": "start", "operationId": 5, "locale": "zh-CN"],
            ["kind": "audio", "operationId": 5, "pcm16": [4, 5]]
        ])
        var states: [String] = []
        let adapter = NativeLocalTranscription(recognizer: recognizer, drain: { effects }, send: { event in
            if case let .localAsrReadiness(state, _) = event { states.append(state) }
        })
        adapter.prepare()
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while recognizer.prepareWaiter == nil, ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertNotNil(recognizer.prepareWaiter)
        adapter.apply()
        await Task.yield()
        XCTAssertTrue(recognizer.sessions.isEmpty)
        recognizer.prepareWaiter?.resume()
        recognizer.prepareWaiter = nil
        await adapter.waitUntilIdle()
        XCTAssertEqual(states, ["preparing", "ready"])
        XCTAssertEqual(recognizer.sessions.first?.samples, [4, 5])
        adapter.shutdown()
        await adapter.waitUntilIdle()
    }

    func testHungFinishTimesOutCancelsAndAllowsNextOperation() async throws {
        let recognizer = ControlledSpeechRecognizer()
        recognizer.configure = { $0.holdFinish = true }
        var instant = ContinuousClock.now
        var batch = data([
            ["kind": "start", "operationId": 8, "locale": "zh-CN"],
            ["kind": "finish", "operationId": 8]
        ])
        var commands: [HostAdapterEvent] = []
        let adapter = NativeLocalTranscription(recognizer: recognizer, drain: { batch },
                                              send: { commands.append($0) }, now: { instant }, operationTimeout: .seconds(1))
        adapter.apply()
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while recognizer.sessions.first?.finishWaiter == nil, ContinuousClock.now < deadline { await Task.yield() }
        let first = try XCTUnwrap(recognizer.sessions.first)
        XCTAssertNotNil(first.finishWaiter)
        instant = instant.advanced(by: .seconds(2))
        adapter.apply()
        await adapter.waitUntilIdle()
        XCTAssertTrue(first.cancelled)
        XCTAssertEqual(commands.map(\.eventType), ["local_asr_failed"])
        recognizer.configure = nil
        batch = data([
            ["kind": "cancel", "operationId": 8],
            ["kind": "start", "operationId": 9, "locale": "zh-CN"],
            ["kind": "finish", "operationId": 9]
        ])
        adapter.apply()
        await adapter.waitUntilIdle()
        XCTAssertEqual(commands.map(\.eventType), ["local_asr_failed", "local_asr_result", "local_asr_finished"])
        XCTAssertEqual(commands.last, .localAsrFinished(operationId: 9))
    }

    func testFinishWaitsForTailResultBeforeCompletionAndPreservesPCMOrder() async throws {
        let recognizer = ControlledSpeechRecognizer()
        recognizer.configure = { $0.holdFinish = true }
        let effects = data([
            ["kind": "start", "operationId": 7, "locale": "zh-CN"],
            ["kind": "audio", "operationId": 7, "pcm16": [1, -2]],
            ["kind": "audio", "operationId": 7, "pcm16": [3]],
            ["kind": "finish", "operationId": 7]
        ])
        var commands: [HostAdapterEvent] = []
        var drains = 0
        let adapter = NativeLocalTranscription(recognizer: recognizer, drain: { drains += 1; return effects },
                                              send: { commands.append($0) })
        adapter.apply()
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while recognizer.sessions.first?.finishStarted != true, ContinuousClock.now < deadline {
            await Task.yield()
        }
        let session = try XCTUnwrap(recognizer.sessions.first)
        XCTAssertTrue(session.finishStarted)
        adapter.apply()
        XCTAssertEqual(drains, 1)
        XCTAssertTrue(commands.isEmpty)
        XCTAssertEqual(session.samples, [1, -2, 3])
        session.finishWaiter?.resume()
        await adapter.waitUntilIdle()
        XCTAssertEqual(commands, [
            .localAsrResult(operationId: 7, text: "最后一句", startMs: 0, endMs: 800, isFinal: true),
            .localAsrFinished(operationId: 7)
        ])
    }

    func testCancelledOperationCannotPublishIntoNextOperation() async throws {
        let recognizer = ControlledSpeechRecognizer()
        var batch = data([["kind": "start", "operationId": 1, "locale": "zh-CN"]])
        var commands: [HostAdapterEvent] = []
        let adapter = NativeLocalTranscription(recognizer: recognizer, drain: { batch },
                                              send: { commands.append($0) })
        adapter.apply()
        await adapter.waitUntilIdle()
        let first = try XCTUnwrap(recognizer.sessions.first)
        batch = data([
            ["kind": "cancel", "operationId": 1],
            ["kind": "start", "operationId": 2, "locale": "zh-CN"],
            ["kind": "audio", "operationId": 1, "pcm16": [99]],
            ["kind": "finish", "operationId": 1]
        ])
        adapter.apply()
        await adapter.waitUntilIdle()
        first.result?(.success(LocalSpeechResult(text: "过期", startMs: 0, endMs: 100, isFinal: true)))
        let second = try XCTUnwrap(recognizer.sessions.last)
        second.result?(.success(LocalSpeechResult(text: "当前", startMs: 0, endMs: 200, isFinal: false)))
        XCTAssertTrue(first.cancelled)
        XCTAssertEqual(second.samples, [])
        XCTAssertEqual(commands, [.localAsrResult(operationId: 2, text: "当前", startMs: 0, endMs: 200, isFinal: false)])
        adapter.shutdown()
        await adapter.waitUntilIdle()
        second.result?(.success(LocalSpeechResult(text: "退出后", startMs: 0, endMs: 300, isFinal: true)))
        XCTAssertEqual(commands.count, 1)
        XCTAssertTrue(second.cancelled)
    }

    func testAudioFailureReportsOperationAndNeverClaimsFinished() async {
        let recognizer = ControlledSpeechRecognizer()
        recognizer.configure = { $0.appendError = LocalSpeechError("音频队列已满") }
        let effects = data([
            ["kind": "start", "operationId": 3, "locale": "zh-CN"],
            ["kind": "audio", "operationId": 3, "pcm16": [1]],
            ["kind": "finish", "operationId": 3]
        ])
        var commands: [HostAdapterEvent] = []
        let adapter = NativeLocalTranscription(recognizer: recognizer, drain: { effects },
                                              send: { commands.append($0) })
        adapter.apply()
        await adapter.waitUntilIdle()
        XCTAssertEqual(commands.map(\.eventType), ["local_asr_failed"])
        XCTAssertEqual(commands.first, .localAsrFailed(operationId: 3, message: "音频队列已满"))
        XCTAssertTrue(recognizer.sessions.first?.cancelled == true)
    }

    func testReaderFailureDuringRecordingCancelsWithoutWaitingForMoreInput() async throws {
        let recognizer = ControlledSpeechRecognizer()
        var batch = data([["kind": "start", "operationId": 11, "locale": "zh-CN"]])
        var commands: [HostAdapterEvent] = []
        let adapter = NativeLocalTranscription(recognizer: recognizer, drain: { batch },
                                              send: { commands.append($0) })
        adapter.apply()
        await adapter.waitUntilIdle()
        let failed = try XCTUnwrap(recognizer.sessions.first)
        failed.failReader()
        await failed.reader?.value
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while !failed.cancelled, ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertEqual(commands.map(\.eventType), ["local_asr_failed"])
        if case let .localAsrFailed(opId, _) = commands.first {
            XCTAssertEqual(opId, 11)
        } else {
            XCTFail("expected localAsrFailed")
        }
        XCTAssertTrue(failed.cancelled)
        await adapter.waitUntilIdle()
        failed.result?(.failure(LocalSpeechError("重复错误")))
        failed.result?(.success(LocalSpeechResult(text: "失败后", startMs: 0, endMs: 100, isFinal: true)))
        batch = data([
            ["kind": "audio", "operationId": 11, "pcm16": [1]],
            ["kind": "finish", "operationId": 11],
            ["kind": "start", "operationId": 12, "locale": "zh-CN"]
        ])
        adapter.apply()
        await adapter.waitUntilIdle()
        failed.result?(.failure(LocalSpeechError("过期错误")))
        let current = try XCTUnwrap(recognizer.sessions.last)
        current.result?(.success(LocalSpeechResult(text: "当前", startMs: 0, endMs: 100, isFinal: false)))
        XCTAssertEqual(commands.map(\.eventType), ["local_asr_failed", "local_asr_result"])
        XCTAssertEqual(commands.last, .localAsrResult(operationId: 12, text: "当前", startMs: 0, endMs: 100, isFinal: false))
        XCTAssertEqual(failed.samples, [])
        XCTAssertFalse(current.cancelled)
        adapter.shutdown()
        await adapter.waitUntilIdle()
    }

    func testReaderFailureDuringFinishCancelsAndEmitsOnlyFailure() async throws {
        let recognizer = ControlledSpeechRecognizer()
        recognizer.configure = { $0.holdFinish = true }
        let effects = data([
            ["kind": "start", "operationId": 13, "locale": "zh-CN"],
            ["kind": "finish", "operationId": 13]
        ])
        var commands: [HostAdapterEvent] = []
        let adapter = NativeLocalTranscription(recognizer: recognizer, drain: { effects },
                                              send: { commands.append($0) })
        adapter.apply()
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while recognizer.sessions.first?.finishWaiter == nil, ContinuousClock.now < deadline { await Task.yield() }
        let session = try XCTUnwrap(recognizer.sessions.first)
        XCTAssertNotNil(session.finishWaiter)
        session.failReader()
        await session.reader?.value
        let cancelledBy = ContinuousClock.now.advanced(by: .seconds(1))
        while !session.cancelled, ContinuousClock.now < cancelledBy { await Task.yield() }
        XCTAssertTrue(session.cancelled)
        adapter.shutdown()
        await adapter.waitUntilIdle()
        XCTAssertEqual(commands.map(\.eventType), ["local_asr_failed"])
        if case let .localAsrFailed(opId, _) = commands.first {
            XCTAssertEqual(opId, 13)
        } else {
            XCTFail("expected localAsrFailed")
        }
    }

    func testAnalyzerInputOverflowFailsInsteadOfSilentlyDroppingSpeech() throws {
        guard #available(macOS 26, *) else { throw XCTSkip("SpeechAnalyzer requires macOS 26") }
        let input = LocalSpeechAudioInput(capacity: 1)
        let converter = try LocalSpeechPCMConverter(outputFormat: LocalSpeechPCMConverter.inputFormat)
        let buffer = try XCTUnwrap(converter.convert([1, -1]))
        try input.append(buffer)
        XCTAssertThrowsError(try input.append(buffer))
        input.finish()
    }

    func testPersistentResamplerPreservesDurationAcrossChunkBoundariesAndFlush() throws {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false))
        let converter = try LocalSpeechPCMConverter(outputFormat: format)
        var output: [Float] = []
        func collect(_ buffer: AVAudioPCMBuffer) {
            if let samples = buffer.floatChannelData?[0] {
                output.append(contentsOf: UnsafeBufferPointer(start: samples, count: Int(buffer.frameLength)))
            }
        }
        for _ in 0..<100 {
            if let buffer = try converter.convert(Array(repeating: 8192, count: 160)) { collect(buffer) }
        }
        try converter.flush(collect)
        XCTAssertEqual(output.count, 48_000)
        XCTAssertEqual(output[24_000], 0.25, accuracy: 0.001)
    }

    func testDecodeBinaryHandlesDataSliceAndRealRustOwnedBytesRoundtrip() throws {
        let framed = Data([0xAA, 0xBB, 0xCC, 0xDD]) + data([
            ["kind": "start", "operationId": 41, "locale": "zh-CN"],
            ["kind": "audio", "operationId": 41, "pcm16": [12, -34]],
            ["kind": "finish", "operationId": 41],
            ["kind": "cancel", "operationId": 42]
        ])
        let sliced = framed.dropFirst(4)
        XCTAssertEqual(sliced.startIndex, 4)
        let decodedSlice = try LocalSpeechEffect.decodeBinary(sliced)
        XCTAssertEqual(decodedSlice, [
            .start(41, "zh-CN"),
            .audio(41, [12, -34]),
            .finish(41),
            .cancel(42)
        ])

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = HostSessionStore(workspacePath: directory.path)
        defer { store.shutdown() }

        store.send(.deviceEvent(event: "scanning", connectionId: "c-drain", deviceName: "D3200"))
        store.send(.deviceEvent(event: "connecting", connectionId: "c-drain", deviceName: "D3200"))
        store.send(.deviceEvent(event: "ready", connectionId: "c-drain", deviceName: "D3200"))
        let bleFrames = store.drainOutboundBleFrames()
        XCTAssertFalse(bleFrames.isEmpty)
        XCTAssertTrue(store.drainOutboundBleFrames().isEmpty)
        XCTAssertNil(store.nativeError)

        store.send(.localAsrReadiness(state: "ready", message: "就绪"))
        store.send(.configureSpeech(engine: "apple_speech", modelId: nil))
        store.send(.startCaptureMode(mode: .quickNote, stayOnPage: true))
        let mic = try XCTUnwrap(store.snapshot.microphone)
        store.send(.microphoneStarted(recordId: mic.recordId, sessionId: mic.sessionId, lane: "microphone", sampleRate: 16_000))
        let receipt = store.ingestMicrophonePCM(
            recordId: mic.recordId,
            sessionId: mic.sessionId,
            lane: "microphone",
            sequence: 0,
            epoch: mic.epoch,
            capturedStartNs: nil,
            samples: [100, -200, 300, -400]
        )
        XCTAssertEqual(receipt.status, .accepted)
        store.send(.captureAction(action: .end))
        store.send(.microphoneStopped(recordId: mic.recordId, sessionId: mic.sessionId, lane: "microphone", sequence: 1, epoch: mic.epoch))

        let rawEffects = store.drainLocalASREffectsData()
        XCTAssertFalse(rawEffects.isEmpty)
        let decodedRust = try LocalSpeechEffect.decodeBinary(rawEffects)
        XCTAssertTrue(decodedRust.contains { if case .start(_, "zh-CN") = $0 { return true }; return false })
        XCTAssertTrue(decodedRust.contains { if case let .audio(_, samples) = $0 { return samples == [100, -200, 300, -400] }; return false })
        XCTAssertTrue(decodedRust.contains { if case .finish = $0 { return true }; return false })
        XCTAssertTrue(store.drainLocalASREffectsData().isEmpty)
    }
}
