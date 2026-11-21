import AVFoundation
import KoeAppleCore
import XCTest
@testable import Koe

@MainActor
final class NativeLocalTranscriptionRealTests: XCTestCase {
    func testInstalledChineseRecognizerStreamsSyntheticWAVBeforeFinish() async throws {
        guard let path = ProcessInfo.processInfo.environment["KOE_LOCAL_ASR_WAV"] else {
            throw XCTSkip("Set KOE_LOCAL_ASR_WAV to a Mandarin PCM16 16 kHz mono WAV for real local recognition")
        }
        guard #available(macOS 26, *) else { throw XCTSkip("SpeechAnalyzer requires macOS 26") }
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path), commonFormat: .pcmFormatInt16, interleaved: false)
        XCTAssertEqual(file.processingFormat.sampleRate, 16_000)
        XCTAssertEqual(file.processingFormat.channelCount, 1)
        let recognizer = AppleLocalSpeechRecognizer()
        try await recognizer.prepare()
        try await recognizer.prepare()
        var results: [LocalSpeechResult] = []
        var failures: [Error] = []
        let session = try await recognizer.start(locale: "zh-CN") { event in
            switch event {
            case let .success(result): results.append(result)
            case let .failure(error): failures.append(error)
            }
        }
        do {
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 1600))
            while file.framePosition < file.length {
                try file.read(into: buffer, frameCount: 1600)
                let samples = try XCTUnwrap(buffer.int16ChannelData?[0])
                try session.append(Array(UnsafeBufferPointer(start: samples, count: Int(buffer.frameLength))))
                try await Task.sleep(for: .milliseconds(100))
            }
            let deadline = ContinuousClock.now.advanced(by: .seconds(10))
            while !results.contains(where: { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }), ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(100))
            }
            XCTAssertTrue(results.contains { !$0.text.isEmpty && !$0.isFinal }, "Expected a live partial before closing the audio stream")
            print("LOCAL_ASR_BEFORE_FINISH \(results.map(\.text).joined(separator: " | "))")
            try await session.finish()
            XCTAssertTrue(failures.isEmpty, "Unexpected local recognition failure: \(failures)")
            let final = results.filter(\.isFinal)
            XCTAssertFalse(final.isEmpty, "Expected a final local result after closing input")
            XCTAssertTrue(final.allSatisfy { $0.endMs >= $0.startMs })
            let text = final.map(\.text).joined(separator: " ")
            let expected = ProcessInfo.processInfo.environment["KOE_LOCAL_ASR_EXPECTED"] ?? "离线"
            XCTAssertFalse(expected.isEmpty, "KOE_LOCAL_ASR_EXPECTED must be nonempty")
            XCTAssertTrue(text.contains(expected), "Expected \(expected) in the local transcript, received \(text)")
            print("LOCAL_ASR_FINAL \(text)")
        } catch {
            await session.cancel()
            throw error
        }
    }
}
