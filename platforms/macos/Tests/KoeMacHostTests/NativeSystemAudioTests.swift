import CoreAudio
import CoreGraphics
import KoeAppleShared
import XCTest
@testable import Koe

final class NativeSystemAudioTests: XCTestCase {
    private func observe(_ evaluator: inout SystemAudioCanaryEvaluator, from start: Double, seconds: Double,
                         prompt: Bool, rendered: inout Int, tap: inout Int, maxTap: Int = .max,
                         signal: Bool = false) -> SystemAudioAuthResult? {
        var elapsed = start
        while elapsed < start + seconds {
            elapsed += 0.05
            rendered += 5
            tap = min(maxTap, tap + 5)
            let result = evaluator.evaluate(SystemAudioCanaryObservation(elapsed: elapsed,
                renderedOutputCallbacks: rendered, tapCallbacks: tap, detectedNonZeroSignal: signal, promptVisible: prompt))
            if let result { return result }
        }
        return nil
    }

    func testThreeHundredSeventeenZeroTapBuffersNeverAuthorizeAndDenyOnlyAfterCanaryRendered() {
        var evaluator = SystemAudioCanaryEvaluator()
        var decisions: [SystemAudioAuthResult] = []
        var rendered = 0
        for tap in stride(from: 5, through: 317, by: 5) {
            rendered += 5
            let elapsed = Double(tap) / 100
            if let result = evaluator.evaluate(SystemAudioCanaryObservation(elapsed: elapsed,
                renderedOutputCallbacks: rendered, tapCallbacks: tap, detectedNonZeroSignal: false, promptVisible: false)) {
                decisions.append(result)
                XCTAssertGreaterThanOrEqual(elapsed, evaluator.settleSeconds)
                break
            }
        }
        XCTAssertEqual(decisions, [.denied(SystemAudioCanaryEvaluator.deniedMessage)])
        XCTAssertFalse(evaluator.shouldRetry(after: decisions[0]))
    }

    func testStartedTapWithSilenceButNoRenderedCanaryTimesOutAsUnavailable() {
        var evaluator = SystemAudioCanaryEvaluator(timeoutSeconds: 5)
        var tap = 0
        var result: SystemAudioAuthResult?
        var elapsed = 0.0
        while result == nil, elapsed < 10 {
            elapsed += 0.05
            tap += 5
            result = evaluator.evaluate(SystemAudioCanaryObservation(elapsed: elapsed, renderedOutputCallbacks: 0,
                tapCallbacks: tap, detectedNonZeroSignal: false, promptVisible: false))
        }
        guard case .unavailable = result else { return XCTFail("silent tap without canary must stay unknown: \(String(describing: result))") }
        XCTAssertGreaterThanOrEqual(elapsed, 5)
    }

    func testPromptLongerThanTenSecondsWaitsAndAuthorizesOnCanarySignal() {
        var evaluator = SystemAudioCanaryEvaluator()
        var rendered = 0
        var tap = 0
        XCTAssertNil(observe(&evaluator, from: 0, seconds: 12, prompt: true, rendered: &rendered, tap: &tap))
        XCTAssertTrue(evaluator.sawPrompt)
        let result = evaluator.evaluate(SystemAudioCanaryObservation(elapsed: 12.1, renderedOutputCallbacks: rendered + 5,
            tapCallbacks: tap + 5, detectedNonZeroSignal: true, promptVisible: false))
        XCTAssertEqual(result, .authorized)
    }

    func testDismissedPromptWithContinuedSilenceDeniesAfterSettleAndRequestsFreshTap() {
        var evaluator = SystemAudioCanaryEvaluator()
        var rendered = 0
        var tap = 0
        XCTAssertNil(observe(&evaluator, from: 0, seconds: 11, prompt: true, rendered: &rendered, tap: &tap))
        let beforeSettle = observe(&evaluator, from: 11, seconds: 0.5, prompt: false, rendered: &rendered, tap: &tap)
        XCTAssertNil(beforeSettle, "a decision right after the prompt closes is too early")
        let result = observe(&evaluator, from: 11.5, seconds: 2, prompt: false, rendered: &rendered, tap: &tap)
        XCTAssertEqual(result, .denied(SystemAudioCanaryEvaluator.deniedMessage))
        XCTAssertTrue(evaluator.shouldRetry(after: result!))
    }

    func testPromptStillVisibleAtTimeoutIsUnavailable() {
        var evaluator = SystemAudioCanaryEvaluator(timeoutSeconds: 3)
        var rendered = 0
        var tap = 0
        let result = observe(&evaluator, from: 0, seconds: 4, prompt: true, rendered: &rendered, tap: &tap)
        guard case .unavailable = result else { return XCTFail("\(String(describing: result))") }
    }

    func testAbortCancelsEvenWhenSignalArrives() {
        var evaluator = SystemAudioCanaryEvaluator()
        let result = evaluator.evaluate(SystemAudioCanaryObservation(elapsed: 0.05, renderedOutputCallbacks: 1,
            tapCallbacks: 1, detectedNonZeroSignal: true, promptVisible: true, aborted: true))
        XCTAssertEqual(result, .cancelled)
    }

    func testCanaryToneIsInaudibleAndAboveDetectionThreshold() {
        let samples = (0..<(SystemAudioCanaryTone.chipFrames * 13)).map(SystemAudioCanaryTone.sample(at:))
        XCTAssertTrue(samples.allSatisfy { abs($0) == SystemAudioCanaryTone.amplitude })
        XCTAssertGreaterThanOrEqual(SystemAudioCanaryTone.amplitude, SystemAudioCanaryEvaluator.signalThreshold)
        XCTAssertLessThanOrEqual(20 * log10(SystemAudioCanaryTone.amplitude), -99.9)
        XCTAssertEqual(Set(samples).count, 2)
    }

    private func bufferList(_ channels: [[Float]]) -> UnsafeMutableAudioBufferListPointer {
        let list = AudioBufferList.allocate(maximumBuffers: channels.count)
        for (index, channel) in channels.enumerated() {
            let data = UnsafeMutablePointer<Float>.allocate(capacity: channel.count)
            data.initialize(from: channel, count: channel.count)
            list[index] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(channel.count * 4), mData: data)
        }
        return list
    }

    private func release(_ list: UnsafeMutableAudioBufferListPointer) {
        for buffer in list { buffer.mData?.deallocate() }
        free(list.unsafeMutablePointer)
    }

    func testPeakDetectsCanaryAndIgnoresSilenceAndNonFiniteSamples() {
        let format = SystemAudioFormat(sampleRate: 48_000, channels: 1, isFloat: true, interleaved: false)
        let silent = bufferList([[0, 0, .nan, .infinity]])
        let canary = bufferList([[0, SystemAudioCanaryTone.amplitude, 0, 0]])
        defer { release(silent); release(canary) }
        XCTAssertLessThan(SystemAudioConversion.peak(silent.unsafePointer, format: format), SystemAudioCanaryEvaluator.signalThreshold)
        XCTAssertGreaterThanOrEqual(SystemAudioConversion.peak(canary.unsafePointer, format: format), SystemAudioCanaryEvaluator.signalThreshold)
    }

    func testMonoMixdownForNonInterleavedFloatAndInterleavedInt16() throws {
        let stereo = bufferList([[1, -1, 0.5], [0, -1, 0.5]])
        defer { release(stereo) }
        let floatFormat = SystemAudioFormat(sampleRate: 48_000, channels: 2, isFloat: true, interleaved: false)
        XCTAssertEqual(try SystemAudioConversion.mono(stereo.unsafePointer, format: floatFormat), [16383, -32767, 16383])

        let list = AudioBufferList.allocate(maximumBuffers: 1)
        let pcm: [Int16] = [1000, 3000, -2000, -4000]
        let data = UnsafeMutablePointer<Int16>.allocate(capacity: pcm.count)
        data.initialize(from: pcm, count: pcm.count)
        list[0] = AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(pcm.count * 2), mData: data)
        defer { data.deallocate(); free(list.unsafeMutablePointer) }
        let intFormat = SystemAudioFormat(sampleRate: 44_100, channels: 2, isFloat: false, interleaved: true)
        XCTAssertEqual(try SystemAudioConversion.mono(list.unsafePointer, format: intFormat), [1999, -2999])
        let mono = SystemAudioFormat(sampleRate: 44_100, channels: 1, isFloat: false, interleaved: true)
        XCTAssertThrowsError(try SystemAudioConversion.mono(list.unsafePointer, format: mono))
    }

    func testSlicesStayWithinFourKilobyteFramesWithSampleAccurateTimes() throws {
        let blocks = SystemAudioConversion.slices([Int16](repeating: 7, count: 9000), startNs: 1_000_000_000, sampleRate: 48_000)
        XCTAssertEqual(blocks.map(\.samples.count), [4096, 4096, 808])
        XCTAssertEqual(blocks.map(\.capturedStartNs), [1_000_000_000, 1_085_333_333, 1_170_666_666])

        let stereo = bufferList([[Float](repeating: 0.5, count: 4500), [Float](repeating: -0.25, count: 4500)])
        defer { release(stereo) }
        let format = SystemAudioFormat(sampleRate: 48_000, channels: 2, isFloat: true, interleaved: false)
        let expected = SystemAudioConversion.slices(try SystemAudioConversion.mono(stereo.unsafePointer, format: format), startNs: 5_000_000, sampleRate: 48_000)
        var scratch = [Float](repeating: 0, count: 4096)
        var actual: [CapturedPCM] = []
        try SystemAudioConversion.emitMonoSlices(stereo.unsafePointer, format: format, startNs: 5_000_000, mixScratch: &scratch) {
            actual.append($0)
        }
        XCTAssertEqual(actual.map(\.samples), expected.map(\.samples))
        XCTAssertEqual(actual.map(\.capturedStartNs), expected.map(\.capturedStartNs))
    }

    func testTapFormatAcceptsSupportedLinearPCMOnly() throws {
        func describe(_ rate: Double, bits: UInt32, flags: AudioFormatFlags) -> AudioStreamBasicDescription {
            AudioStreamBasicDescription(mSampleRate: rate, mFormatID: kAudioFormatLinearPCM, mFormatFlags: flags,
                mBytesPerPacket: bits / 8, mFramesPerPacket: 1, mBytesPerFrame: bits / 8, mChannelsPerFrame: 2,
                mBitsPerChannel: bits, mReserved: 0)
        }
        let float = try SystemAudioFormat(describe(48_000, bits: 32, flags: kAudioFormatFlagsNativeFloatPacked | kAudioFormatFlagIsNonInterleaved))
        XCTAssertEqual(float, SystemAudioFormat(sampleRate: 48_000, channels: 2, isFloat: true, interleaved: false))
        XCTAssertNoThrow(try SystemAudioFormat(describe(16_000, bits: 16, flags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked)))
        XCTAssertThrowsError(try SystemAudioFormat(describe(192_000, bits: 32, flags: kAudioFormatFlagsNativeFloatPacked)))
        XCTAssertThrowsError(try SystemAudioFormat(describe(44_100.5, bits: 32, flags: kAudioFormatFlagsNativeFloatPacked)))
        XCTAssertThrowsError(try SystemAudioFormat(describe(48_000, bits: 24, flags: kAudioFormatFlagIsSignedInteger)))
    }

    func testPermissionPromptDetectionRequiresKnownOwnerAboveNormalLayer() {
        let owner = kCGWindowOwnerName as String
        let layer = kCGWindowLayer as String
        XCTAssertTrue(SystemPermissionPrompt.visible(in: [[owner: "UserNotificationCenter", layer: NSNumber(value: 8)]]))
        XCTAssertFalse(SystemPermissionPrompt.visible(in: [[owner: "UserNotificationCenter", layer: NSNumber(value: 0)]]))
        XCTAssertFalse(SystemPermissionPrompt.visible(in: [[owner: "Safari", layer: NSNumber(value: 8)]]))
    }

    func testCoreAudioCFStringQueriesHandleRetainedOwnershipSafely() throws {
        XCTAssertThrowsError(try SystemAudioHAL.deviceUID(AudioObjectID(kAudioObjectUnknown)))
        for _ in 0..<8 {
            let inputs = NativeAudioSource.inputs()
            for input in inputs {
                XCTAssertFalse(input.id.isEmpty)
                XCTAssertFalse(input.name.isEmpty)
            }
        }
        if let output = try? SystemAudioHAL.defaultOutputDevice() {
            var uids: Set<String> = []
            for _ in 0..<8 {
                let uid = try SystemAudioHAL.deviceUID(output)
                XCTAssertFalse(uid.isEmpty)
                uids.insert(uid)
            }
            XCTAssertEqual(uids.count, 1)
        }
    }
}
