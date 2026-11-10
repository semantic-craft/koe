import AVFoundation
import KoeAppleShared
import XCTest
@testable import Koe

@MainActor
final class NativePlaybackTests: XCTestCase {
    private func fixture(_ body: @MainActor (URL, PlaybackAssetSnapshot) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("koe-playback-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("sparse.wav")
        var data = Data()
        func ascii(_ s: String) { data.append(contentsOf: s.utf8) }
        func u32(_ n: UInt32) { var n = n.littleEndian; withUnsafeBytes(of: &n) { data.append(contentsOf: $0) } }
        func u16(_ n: UInt16) { var n = n.littleEndian; withUnsafeBytes(of: &n) { data.append(contentsOf: $0) } }
        ascii("RIFF"); u32(676); ascii("WAVEfmt "); u32(16); u16(1); u16(1)
        u32(16000); u32(32000); u16(2); u16(16); ascii("data"); u32(640)
        for n in [Int16](repeating: 8192, count: 160) + [Int16](repeating: 16384, count: 160) { u16(UInt16(bitPattern: n)) }
        try data.write(to: url)
        let json: [String: Any] = ["audioPath": url.path, "sampleRate": 16000, "durationNs": 150_000_000,
            "segments": [
                ["sourceStartSample": 0, "sampleCount": 160, "timelineStartNs": 20_000_000],
                ["sourceStartSample": 160, "sampleCount": 160, "timelineStartNs": 100_000_000]
            ]]
        let plan = try JSONDecoder().decode(PlaybackAssetSnapshot.self, from: JSONSerialization.data(withJSONObject: json))
        try await body(url, plan)
    }

    func testSparseCompositionHasLeadingInternalTrailingSilenceAndOriginalSamples() async throws {
        try await fixture { url, plan in
            let original = try Data(contentsOf: url)
            let item = try await NativePlaybackItem.make(plan)
            let asset = item.asset
            let duration = try await asset.load(.duration)
            XCTAssertEqual(duration.seconds, 0.15, accuracy: 0.000001)
            let tracks = try await asset.loadTracks(withMediaType: .audio)
            XCTAssertFalse(tracks.isEmpty)
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000,
                AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false
            ])
            output.audioMix = item.audioMix
            reader.add(output)
            XCTAssertTrue(reader.startReading())
            var samples = [Int16](repeating: 0, count: 2400)
            var covered = Set<Int>()
            while let buffer = output.copyNextSampleBuffer() {
                let start = Int((CMSampleBufferGetPresentationTimeStamp(buffer).seconds * 16000).rounded())
                guard let block = CMSampleBufferGetDataBuffer(buffer) else { XCTFail("missing PCM"); break }
                let count = CMBlockBufferGetDataLength(block) / 2
                var bytes = [Int16](repeating: 0, count: count)
                let status = bytes.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: count * 2, destination: $0.baseAddress!) }
                XCTAssertEqual(status, kCMBlockBufferNoErr)
                for (index, sample) in bytes.enumerated() where start + index >= 0 && start + index < samples.count {
                    samples[start + index] = sample
                    covered.insert(start + index)
                }
            }
            XCTAssertEqual(reader.status, .completed, "\(String(describing: reader.error))")
            XCTAssertEqual(covered.count, 2400)
            XCTAssertEqual(Array(samples[0..<320]), [Int16](repeating: 0, count: 320))
            XCTAssertEqual(Array(samples[320..<480]), [Int16](repeating: 8192, count: 160))
            XCTAssertEqual(Array(samples[480..<1600]), [Int16](repeating: 0, count: 1120))
            XCTAssertEqual(Array(samples[1600..<1760]), [Int16](repeating: 16384, count: 160))
            XCTAssertEqual(Array(samples[1760..<2400]), [Int16](repeating: 0, count: 640))
            XCTAssertEqual(try Data(contentsOf: url), original)
        }
    }

    func testUntimedCaptureKeepsFullAssetAndCommonTail() async throws {
        try await fixture { _, plan in
            var fields = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(plan)) as? [String: Any])
            fields["segments"] = []
            let untimed = try JSONDecoder().decode(PlaybackAssetSnapshot.self, from: JSONSerialization.data(withJSONObject: fields))
            let item = try await NativePlaybackItem.make(untimed)
            let duration = try await item.asset.load(.duration)
            XCTAssertEqual(duration.seconds, 0.15, accuracy: 0.000001)
            let tracks = try await item.asset.loadTracks(withMediaType: .audio)
            let track = try XCTUnwrap(tracks.first as? AVCompositionTrack)
            let ranges = track.segments.filter { !$0.isEmpty }.map { $0.timeMapping.source }
            XCTAssertEqual(ranges.count, 1)
            XCTAssertEqual(try XCTUnwrap(ranges.first).duration.seconds, 0.02, accuracy: 0.000001)
        }
    }
}
