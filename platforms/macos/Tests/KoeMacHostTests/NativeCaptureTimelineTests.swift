import Foundation
import KoeAppleShared
import XCTest
@testable import Koe

struct SavedCapture: Decodable {
    struct Record: Decodable {
        struct Lane: Decodable {
            struct Span: Decodable {
                let epoch: UInt64
                let startNs: UInt64
                let sampleCount: UInt64
            }
            let sampleRate: UInt32
            let interruption: String?
            let timeline: [Span]
        }
        let durationMs: UInt64
        let captureLanes: [Lane]
    }
    let records: [Record]
    static func read(_ root: URL) throws -> Record {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let saved = try decoder.decode(Self.self, from: Data(contentsOf: root.appendingPathComponent("product-workspace.json")))
        return try XCTUnwrap(saved.records.first)
    }
}

extension NativeCaptureIntegrationTests {
    func testAuthorizationDelayAndDeliveryDelayDoNotMoveCapturedSamples() async throws {
        try await fixture { store, source, capture, root in
            store.send("start_microphone", ["inputId": "fixture"])
            XCTAssertEqual(store.snapshot.microphone?.phase, "starting")
            XCTAssertNil(store.snapshot.microphone?.clockNs)
            source.clockNs = 30_000_000_000
            source.firstOffsetNs = 10_000_000
            source.permission?(true)
            await self.awaitRecording(store)
            XCTAssertEqual(store.snapshot.microphone?.clockNs, 30_000_000_000)
            source.receive?(Array(repeating: 5, count: 1600))
            source.clockNs = 90_000_000_000
            capture.apply()
            store.send("stop_microphone")
            XCTAssertNil(store.snapshot.microphone)
            let record = try SavedCapture.read(root)
            XCTAssertEqual(record.durationMs, 110)
            XCTAssertEqual(record.captureLanes[0].timeline[0].startNs, 10_000_000)
            XCTAssertEqual(record.captureLanes[0].timeline[0].sampleCount, 1600)
        }
    }

    func testResumeWaitsForPermissionAndKeepsSequenceWhileIgnoringOldCallbacks() async throws {
        try await fixture { store, source, capture, root in
            store.send("start_microphone", ["inputId": "fixture"])
            source.permission?(true)
            await self.awaitRecording(store)
            let oldReceive = source.emit
            let oldFailure = source.failure
            source.receive?(Array(repeating: 1, count: 160))
            source.tail = Array(repeating: 2, count: 160)
            store.send("pause_microphone")
            XCTAssertEqual(store.snapshot.microphone?.phase, "paused")
            XCTAssertEqual(store.snapshot.microphone?.nextSequence, 2)
            capture.resume()
            capture.resume()
            XCTAssertEqual(source.permissionRequests, 2)
            source.clockNs = 60_000_000_000
            XCTAssertEqual(store.snapshot.microphone?.phase, "paused")
            XCTAssertEqual(source.starts, 1)
            source.permission?(true)
            await self.awaitState { store.snapshot.microphone?.epoch == 1 && source.starts == 2 }
            oldReceive?(CapturedPCM(samples: [99], capturedStartNs: 60_000_000_000))
            oldFailure?("late source failure")
            source.receive?(Array(repeating: 3, count: 320))
            capture.apply()
            XCTAssertEqual(store.snapshot.microphone?.phase, "recording")
            XCTAssertEqual(store.snapshot.microphone?.nextSequence, 3)
            store.send("stop_microphone")
            let record = try SavedCapture.read(root)
            XCTAssertEqual(record.durationMs, 40)
            XCTAssertNil(record.captureLanes[0].interruption)
            XCTAssertEqual(record.captureLanes[0].timeline.map(\.epoch), [0, 1])
            XCTAssertEqual(record.captureLanes[0].timeline.map(\.startNs), [0, 20_000_000])
            XCTAssertEqual(record.captureLanes[0].timeline.map(\.sampleCount), [320, 320])
        }
    }

    func testResumePermissionDenialPreservesAudioAndEndsQuit() async throws {
        try await fixture { store, source, capture, root in
            store.send("start_microphone", ["inputId": "fixture"])
            source.permission?(true)
            await self.awaitRecording(store)
            source.receive?([1, 2])
            store.send("pause_microphone")
            capture.resume()
            source.permission?(false)
            await self.awaitState { store.snapshot.microphone == nil }
            XCTAssertEqual(source.starts, 1)
            XCTAssertNotNil(try SavedCapture.read(root).captureLanes[0].interruption)
            store.send("request_quit")
            XCTAssertEqual(store.snapshot.lifecycle?.quitPhase, "ready")
        }
    }

    func testResumeStartFailureAfterCallbacksDiscardsOnlyTheNewEpoch() async throws {
        try await resumeFailure(changedRate: false)
    }

    func testResumeChangedRateCannotMixSamplesIntoExistingWav() async throws {
        try await resumeFailure(changedRate: true)
    }

    private func resumeFailure(changedRate: Bool) async throws {
        try await fixture { store, source, capture, root in
            store.send("start_microphone", ["inputId": "fixture"])
            source.permission?(true)
            await self.awaitRecording(store)
            let id = try XCTUnwrap(store.snapshot.microphone?.recordId)
            source.receive?([1, 2])
            store.send("pause_microphone")
            source.clockNs = 30_000_000_000
            source.startSamples = [7, 8]
            source.tail = [9, 10]
            source.sampleRate = changedRate ? 48_000 : 16_000
            source.throwAfterStartSamples = !changedRate
            capture.resume()
            source.permission?(true)
            await self.awaitState { store.snapshot.microphone == nil }
            XCTAssertEqual(source.starts, 2)
            store.send("request_quit")
            XCTAssertEqual(store.snapshot.lifecycle?.quitPhase, "ready")
            let data = try Data(contentsOf: root.appendingPathComponent("audio/\(id).wav"))
            XCTAssertEqual(Array(data.dropFirst(44)), [1, 0, 2, 0])
            let lane = try SavedCapture.read(root).captureLanes[0]
            XCTAssertEqual(lane.sampleRate, 16000)
            XCTAssertNotNil(lane.interruption)
            XCTAssertEqual(lane.timeline.map(\.epoch), [0])
        }
    }

    func testLateResumePermissionAfterQuitCannotStartTheNextSession() async throws {
        try await fixture { store, source, capture, _ in
            store.send("start_microphone", ["inputId": "fixture"])
            source.permission?(true)
            await self.awaitRecording(store)
            source.receive?([1, 2])
            store.send("pause_microphone")
            capture.resume()
            let oldPermission = source.permission
            store.send("request_quit")
            XCTAssertEqual(store.snapshot.lifecycle?.quitPhase, "ready")
            store.send("cancel_quit")
            store.send("start_microphone", ["inputId": "fixture"])
            oldPermission?(true)
            source.permission?(true)
            await self.awaitRecording(store)
            XCTAssertEqual(source.starts, 2)
            XCTAssertEqual(store.snapshot.microphone?.epoch, 0)
        }
    }

    func testStartedWithoutAnyCallbackCanCancelOrQuit() async throws {
        for command in ["cancel_microphone", "request_quit"] {
            try await fixture { store, source, _, _ in
                store.send("start_microphone", ["inputId": "fixture"])
                source.permission?(true)
                await self.awaitRecording(store)
                store.send(command)
                XCTAssertNil(store.snapshot.microphone)
                XCTAssertTrue(store.snapshot.records.isEmpty)
                XCTAssertEqual(store.snapshot.lifecycle?.keepAwake, false)
                if command == "request_quit" { XCTAssertEqual(store.snapshot.lifecycle?.quitPhase, "ready") }
            }
        }
    }

    func testRejectedFirstSampleBeforeClockStopsAndDoesNotStrandQuit() async throws {
        try await fixture { store, source, capture, _ in
            store.send("start_microphone", ["inputId": "fixture"])
            source.permission?(true)
            await self.awaitRecording(store)
            source.emit?(CapturedPCM(samples: [7, 8], capturedStartNs: source.clockNs - 1))
            capture.apply()
            XCTAssertNil(store.snapshot.microphone)
            XCTAssertTrue(store.snapshot.records.isEmpty)
            XCTAssertTrue(store.snapshot.notice?.contains("时钟") == true)
            store.send("request_quit")
            XCTAssertEqual(store.snapshot.lifecycle?.quitPhase, "ready")
        }
    }

    func testExcessiveGapPreservesOnlyAcceptedAudioAndAllowsQuit() async throws {
        try await fixture { store, source, capture, root in
            store.send("start_microphone", ["inputId": "fixture"])
            source.permission?(true)
            await self.awaitRecording(store)
            let id = try XCTUnwrap(store.snapshot.microphone?.recordId)
            source.receive?([1, 2]); capture.apply()
            source.emit?(CapturedPCM(samples: [7, 8], capturedStartNs: 20_000_000_000))
            source.tail = [9, 10]
            store.send("request_quit")
            XCTAssertEqual(store.snapshot.lifecycle?.quitPhase, "ready")
            XCTAssertNil(store.snapshot.microphone)
            let data = try Data(contentsOf: root.appendingPathComponent("audio/\(id).wav"))
            XCTAssertEqual(Array(data.dropFirst(44)), [1, 0, 2, 0])
            XCTAssertNotNil(try SavedCapture.read(root).captureLanes[0].interruption)
        }
    }

    func testQueueOverflowSavesAllAcceptedBlocksWithInterruption() async throws {
        try await fixture { store, source, capture, root in
            store.send("start_microphone", ["inputId": "fixture"])
            source.permission?(true)
            await self.awaitRecording(store)
            let id = try XCTUnwrap(store.snapshot.microphone?.recordId)
            for value in 1...65 { source.receive?([Int16(value)]) }
            capture.apply()
            XCTAssertNil(store.snapshot.microphone)
            let data = try Data(contentsOf: root.appendingPathComponent("audio/\(id).wav"))
            XCTAssertEqual(Array(data.dropFirst(44)), (1...64).flatMap { [UInt8($0), 0] })
            XCTAssertNotNil(try SavedCapture.read(root).captureLanes[0].interruption)
            store.send("request_quit")
            XCTAssertEqual(store.snapshot.lifecycle?.quitPhase, "ready")
        }
    }
}

extension NativeCaptureIntegrationTests {
    func testFailureDuringPauseFenceSavesTailAndCannotBecomePaused() async throws {
        try await fixture { store, source, _, root in
            store.send("start_microphone", ["inputId": "fixture"])
            source.permission?(true)
            await self.awaitRecording(store)
            let id = try XCTUnwrap(store.snapshot.microphone?.recordId)
            source.receive?([1, 2])
            source.tail = [3, 4]
            source.stopFailure = "input changed during final callback"
            store.send("pause_microphone")
            XCTAssertNil(store.snapshot.microphone)
            let data = try Data(contentsOf: root.appendingPathComponent("audio/\(id).wav"))
            XCTAssertEqual(Array(data.dropFirst(44)), [1, 0, 2, 0, 3, 0, 4, 0])
            XCTAssertNotNil(try SavedCapture.read(root).captureLanes[0].interruption)
            store.send("request_quit")
            XCTAssertEqual(store.snapshot.lifecycle?.quitPhase, "ready")
        }
    }
}
