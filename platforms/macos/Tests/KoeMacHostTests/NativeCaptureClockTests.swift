import AVFoundation
import Darwin
import XCTest
@testable import Koe

final class NativeCaptureClockTests: XCTestCase {
    func testRealPcmConversionPreservesFirstSampleHostTime() throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 2))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160))
        buffer.frameLength = 160
        let channels = try XCTUnwrap(buffer.floatChannelData)
        for index in 0..<160 { channels[0][index] = 1; channels[1][index] = 0 }
        let ticks = mach_absolute_time()
        var timebase = mach_timebase_info_data_t()
        XCTAssertEqual(mach_timebase_info(&timebase), KERN_SUCCESS)
        let expected = ticks * UInt64(timebase.numer) / UInt64(timebase.denom)
        let when = AVAudioTime(hostTime: ticks)
        let before = try HostAudioClock.nowNanoseconds()
        let pcm = try NativeAudioSource.capture(buffer, when: when, expectedSampleRate: 16000)
        let after = try HostAudioClock.nowNanoseconds()
        XCTAssertEqual(pcm.capturedStartNs, expected)
        XCTAssertLessThanOrEqual(expected, before)
        XCTAssertLessThanOrEqual(before, after)
        XCTAssertEqual(pcm.samples, Array(repeating: 16383, count: 160))
        buffer.frameLength = 80
        XCTAssertEqual(try NativeAudioSource.capture(buffer, when: when, expectedSampleRate: 16000).capturedStartNs, expected)
    }

    func testInvalidClockAndChangedBufferFormatFailBeforeReceivingAudio() throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32))
        buffer.frameLength = 32
        XCTAssertThrowsError(try NativeAudioSource.capture(buffer, when: AVAudioTime(sampleTime: 0, atRate: 48000), expectedSampleRate: 48000))
        XCTAssertThrowsError(try NativeAudioSource.capture(buffer, when: AVAudioTime(hostTime: 1), expectedSampleRate: 16000))
    }

    func testRationalClockHandlesFullWidthProductAndRejectsInvalidValues() throws {
        XCTAssertEqual(try HostAudioClock.nanoseconds(UInt64.max, numerator: 125, denominator: 125), UInt64.max)
        XCTAssertThrowsError(try HostAudioClock.nanoseconds(UInt64.max, numerator: 125, denominator: 3))
        XCTAssertThrowsError(try HostAudioClock.nanoseconds(1, numerator: 1, denominator: 0))
    }
}
