import Foundation
import KoeMacUI
import XCTest
@testable import Koe

final class NativeAudioSourceDeviceTests: XCTestCase {
    func testSelectedHardwareInputDeliversPcmThroughStartupConfigurationChange() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let inputID = environment["KOE_TEST_MICROPHONE_INPUT_UID"] else {
            throw XCTSkip("Set KOE_TEST_MICROPHONE_INPUT_UID to run the physical input test.")
        }
        let expectedRate = try XCTUnwrap(UInt32(environment["KOE_TEST_MICROPHONE_SAMPLE_RATE"] ?? ""))
        let source = NativeAudioSource()
        let completed = expectation(description: "Selected microphone supplies half a second of PCM")
        let result = InputResult(minimumSamples: Int(expectedRate / 2), completed: completed)
        defer { source.stop() }

        let rate = try source.start(inputID: inputID, expectedSampleRate: nil,
            receive: { result.receive($0) }, failed: { result.fail($0) })
        XCTAssertEqual(rate, expectedRate)
        wait(for: [completed], timeout: 4)
        source.stop()
        let (samples, failure) = result.snapshot()
        XCTAssertNil(failure)
        XCTAssertGreaterThanOrEqual(samples, Int(expectedRate / 2))
    }
}

private final class InputResult: @unchecked Sendable {
    private let lock = NSLock()
    private let minimumSamples: Int
    private let completed: XCTestExpectation
    private var samples = 0
    private var failure: String?
    private var fulfilled = false

    init(minimumSamples: Int, completed: XCTestExpectation) {
        self.minimumSamples = minimumSamples
        self.completed = completed
    }

    func receive(_ pcm: CapturedPCM) {
        lock.lock()
        samples += pcm.samples.count
        let shouldFulfill = !fulfilled && samples >= minimumSamples
        fulfilled = fulfilled || shouldFulfill
        lock.unlock()
        if shouldFulfill { completed.fulfill() }
    }

    func fail(_ message: String) {
        lock.lock()
        failure = message
        let shouldFulfill = !fulfilled
        fulfilled = true
        lock.unlock()
        if shouldFulfill { completed.fulfill() }
    }

    func snapshot() -> (Int, String?) {
        lock.lock()
        defer { lock.unlock() }
        return (samples, failure)
    }
}
