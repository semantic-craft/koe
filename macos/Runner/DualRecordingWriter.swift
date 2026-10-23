import Foundation

/// A continuously repairable PCM16 WAV. Audio bytes are durable independently
/// of the header: Koe's existing recovery repairs RIFF sizes after a crash.
final class DualRecordingWriter {
    private let file: FileHandle
    private(set) var frames = 0
    private var closed = false

    init(path: String) throws {
        guard FileManager.default.createFile(atPath: path, contents: Self.header(frames: 0)) else {
            throw CocoaError(.fileWriteUnknown)
        }
        file = try FileHandle(forUpdating: URL(fileURLWithPath: path))
        try file.seekToEnd()
    }

    func append(_ samples: [Float], endingAt seconds: Double) throws {
        let targetStart = Int((seconds * 16_000).rounded()) - samples.count
        let skip = max(0, frames - targetStart)
        guard skip < samples.count else { return }
        if targetStart > frames { try pad(to: targetStart) }
        guard frames + samples.count - skip <= Int(UInt32.max - 36) / 2 else { throw CocoaError(.fileWriteOutOfSpace) }
        var data = Data(capacity: samples.count * 2)
        for value in samples.dropFirst(skip) {
            let finite = value.isFinite ? value : 0
            var pcm = Int16(max(-32768, min(32767, Int(max(-1, min(1, finite)) * 32768)))).littleEndian
            withUnsafeBytes(of: &pcm) { data.append(contentsOf: $0) }
        }
        try file.write(contentsOf: data)
        frames += samples.count - skip
    }

    func pad(to target: Int) throws {
        guard target <= Int(UInt32.max - 36) / 2 else { throw CocoaError(.fileWriteOutOfSpace) }
        while frames < target {
            let count = min(target - frames, 16_000)
            try file.write(contentsOf: Data(count: count * 2))
            frames += count
        }
    }

    func finish(at seconds: Double) throws {
        guard !closed else { return }
        try pad(to: max(frames, Int(seconds * 16_000)))
        try file.seek(toOffset: 0)
        try file.write(contentsOf: Self.header(frames: frames))
        try file.synchronize()
        try file.close()
        closed = true
    }

    deinit { try? file.close() }

    private static func header(frames: Int) -> Data {
        var data = Data()
        func text(_ value: String) { data.append(contentsOf: value.utf8) }
        func number<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        text("RIFF"); number(UInt32(36 + frames * 2)); text("WAVEfmt ")
        number(UInt32(16)); number(UInt16(1)); number(UInt16(1))
        number(UInt32(16000)); number(UInt32(32000)); number(UInt16(2)); number(UInt16(16))
        text("data"); number(UInt32(frames * 2))
        return data
    }
}
