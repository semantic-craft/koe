import Foundation

@main
struct DualWriterCheck {
    static func main() throws {
        let directory = CommandLine.arguments[1]
        let mic = try DualRecordingWriter(path: directory + "/mic.wav")
        let system = try DualRecordingWriter(path: directory + "/system.wav")
        let samples = [Float](repeating: 0.25, count: 1600)
        try mic.append(samples, endingAt: 0.1)
        try system.append(samples, endingAt: 0.1)
        // Delivery order and duplicates cannot shift or lengthen the timeline.
        try mic.append(samples, endingAt: 0.1)
        try mic.append(samples, endingAt: 0.2)
        try system.append(samples, endingAt: 0.2)
        precondition(mic.frames == 3200 && system.frames == 3200)
        // A real 100 ms capture gap is silence on that lane only.
        try mic.append(samples, endingAt: 0.4)
        try system.append(samples, endingAt: 0.3)
        try system.append(samples, endingAt: 0.4)
        try mic.finish(at: 0.4); try system.finish(at: 0.4)
        let a = try Data(contentsOf: URL(fileURLWithPath: directory + "/mic.wav"))
        let b = try Data(contentsOf: URL(fileURLWithPath: directory + "/system.wav"))
        precondition(a.count == 12844 && b.count == a.count)
        precondition(a[6444..<9644].allSatisfy { $0 == 0 })
        precondition(b[6444..<9644].contains { $0 != 0 })
        // Simulate termination before finish: raw PCM is already on disk and
        // the zero data size is recoverable by repairWavSizes.
        do {
            let interrupted = try DualRecordingWriter(path: directory + "/crash.wav")
            try interrupted.append(samples, endingAt: 0.1)
        }
        let crash = try Data(contentsOf: URL(fileURLWithPath: directory + "/crash.wav"))
        precondition(crash.count == 3244)
        print("PASS dual timelines, duplicate callback, dropout, and interrupted PCM write")
    }
}
