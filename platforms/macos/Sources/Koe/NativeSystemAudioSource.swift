import CoreAudio
import Foundation
import KoeAppleShared

enum SystemAudioHAL {
    static func check(_ status: OSStatus, _ message: String) throws {
        guard status == noErr else { throw CaptureError("\(message)（\(status)）。") }
    }
    static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }
    static func defaultOutputDevice() throws -> AudioObjectID {
        var address = address(kAudioHardwarePropertyDefaultOutputDevice)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        guard status == noErr, device != kAudioObjectUnknown else {
            throw CaptureError("没有可用的音频输出设备，无法录制系统音频。")
        }
        return device
    }
    static func deviceUID(_ device: AudioObjectID) throws -> String {
        var address = address(kAudioDevicePropertyDeviceUID)
        var value: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(device, &address, 0, nil, &size, $0) }
        guard status == noErr, !(value as String).isEmpty else { throw CaptureError("无法读取音频输出设备。") }
        return value as String
    }
    static func processObject(pid: pid_t) -> AudioObjectID? {
        var address = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var pid = pid
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                                UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
        return status == noErr && object != kAudioObjectUnknown ? object : nil
    }
    static func tapFormat(_ tap: AudioObjectID) throws -> SystemAudioFormat {
        var address = address(kAudioTapPropertyFormat)
        var description = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &description), "无法读取系统音频格式")
        return try SystemAudioFormat(description)
    }
}

/// Validated tap stream format: 8–96 kHz linear PCM, Float32 or Int16.
struct SystemAudioFormat: Equatable, Sendable {
    let sampleRate: UInt32
    let channels: Int
    let isFloat: Bool
    let interleaved: Bool

    init(sampleRate: UInt32, channels: Int, isFloat: Bool, interleaved: Bool) {
        self.sampleRate = sampleRate
        self.channels = channels
        self.isFloat = isFloat
        self.interleaved = interleaved
    }

    init(_ d: AudioStreamBasicDescription) throws {
        let float = d.mFormatFlags & kAudioFormatFlagIsFloat != 0
        guard d.mFormatID == kAudioFormatLinearPCM, d.mSampleRate >= 8_000, d.mSampleRate <= 96_000,
              d.mSampleRate.rounded() == d.mSampleRate, d.mChannelsPerFrame > 0,
              (float && d.mBitsPerChannel == 32) || (!float && d.mBitsPerChannel == 16
                  && d.mFormatFlags & kAudioFormatFlagIsSignedInteger != 0) else {
            throw CaptureError("系统音频格式不受支持。")
        }
        self.init(sampleRate: UInt32(d.mSampleRate), channels: Int(d.mChannelsPerFrame), isFloat: float,
                  interleaved: d.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0)
    }
}

enum SystemAudioConversion {
    static let maxFrames = 4096

    /// Calls `body(channelIndex, frames, sampleAt)` per buffer, independent of interleaving.
    private static func forEachChannel(_ list: UnsafeMutableAudioBufferListPointer, format: SystemAudioFormat,
                                       _ body: (_ frames: Int, _ stride: Int, _ value: (Int) -> Float) -> Void) {
        let bytes = format.isFloat ? 4 : 2
        for buffer in list {
            guard let data = buffer.mData, buffer.mNumberChannels > 0 else { continue }
            let channelsInBuffer = Int(buffer.mNumberChannels)
            let frames = Int(buffer.mDataByteSize) / (bytes * channelsInBuffer)
            if format.isFloat {
                let samples = data.assumingMemoryBound(to: Float.self)
                for channel in 0..<channelsInBuffer {
                    body(frames, channelsInBuffer) { samples[$0 * channelsInBuffer + channel] }
                }
            } else {
                let samples = data.assumingMemoryBound(to: Int16.self)
                for channel in 0..<channelsInBuffer {
                    body(frames, channelsInBuffer) { Float(samples[$0 * channelsInBuffer + channel]) / 32768 }
                }
            }
        }
    }

    /// Largest finite absolute sample value; non-finite samples never count as signal.
    static func peak(_ input: UnsafePointer<AudioBufferList>, format: SystemAudioFormat) -> Float {
        var peak: Float = 0
        let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        forEachChannel(list, format: format) { frames, _, value in
            for frame in 0..<frames {
                let sample = value(frame)
                if sample.isFinite { peak = max(peak, abs(sample)) }
            }
        }
        return peak
    }

    /// Mixes every channel into `mixScratch` and returns `(frameCount, channelCount)`.
    private static func mixChannels(
        _ input: UnsafePointer<AudioBufferList>,
        format: SystemAudioFormat,
        mixScratch: inout [Float]
    ) throws -> (frames: Int, channels: Int) {
        let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        var frameCount: Int?
        var channels = 0
        var mismatch = false
        forEachChannel(list, format: format) { frames, _, value in
            if frameCount == nil {
                frameCount = frames
                if mixScratch.count < frames {
                    mixScratch = [Float](repeating: 0, count: frames)
                } else {
                    for index in 0..<frames { mixScratch[index] = 0 }
                }
            }
            guard frames == frameCount else { mismatch = true; return }
            channels += 1
            for frame in 0..<frames {
                let sample = value(frame)
                mixScratch[frame] += sample.isFinite ? sample : 0
            }
        }
        guard !mismatch, channels == format.channels else { throw CaptureError("系统音频缓冲格式已改变。") }
        return (frameCount ?? 0, channels)
    }

    /// Averages every channel to mono PCM16.
    static func mono(_ input: UnsafePointer<AudioBufferList>, format: SystemAudioFormat) throws -> [Int16] {
        var mix: [Float] = []
        let (frameCount, channels) = try mixChannels(input, format: format, mixScratch: &mix)
        return [Int16](unsafeUninitializedCapacity: frameCount) { output, initializedCount in
            for index in 0..<frameCount {
                output[index] = Int16(max(-1, min(1, mix[index] / Float(channels))) * 32767)
            }
            initializedCount = frameCount
        }
    }

    /// Mixes to mono using a pre-allocated scratch buffer and emits `<= 4096`-frame blocks without intermediate array churn.
    static func emitMonoSlices(
        _ input: UnsafePointer<AudioBufferList>,
        format: SystemAudioFormat,
        startNs: UInt64,
        mixScratch: inout [Float],
        emit: (CapturedPCM) -> Void
    ) throws {
        let (frameCount, channels) = try mixChannels(input, format: format, mixScratch: &mixScratch)
        let divisor = Float(channels)
        for offset in stride(from: 0, to: frameCount, by: maxFrames) {
            let chunkCount = min(maxFrames, frameCount - offset)
            let samples = [Int16](unsafeUninitializedCapacity: chunkCount) { output, initializedCount in
                for index in 0..<chunkCount {
                    output[index] = Int16(max(-1, min(1, mixScratch[offset + index] / divisor)) * 32767)
                }
                initializedCount = chunkCount
            }
            let blockStartNs = startNs + UInt64(offset) * 1_000_000_000 / UInt64(format.sampleRate)
            emit(CapturedPCM(samples: samples, capturedStartNs: blockStartNs))
        }
    }

    /// Splits PCM into at most 4096-frame blocks, each stamped with its own first-sample time.
    static func slices(_ samples: [Int16], startNs: UInt64, sampleRate: UInt32) -> [CapturedPCM] {
        stride(from: 0, to: samples.count, by: maxFrames).map { offset in
            CapturedPCM(samples: Array(samples[offset..<min(offset + maxFrames, samples.count)]),
                        capturedStartNs: startNs + UInt64(offset) * 1_000_000_000 / UInt64(sampleRate))
        }
    }
}

/// Private process tap + private aggregate device + IOProc, torn down behind an `AudioCallbackFence`.
@available(macOS 14.2, *)
final class SystemAudioTapGraph {
    let tapID: AudioObjectID
    let aggregateID: AudioObjectID
    let outputDevice: AudioObjectID
    let format: SystemAudioFormat
    private var procID: AudioDeviceIOProcID?
    private let fence = AudioCallbackFence()
    private var destroyed = false

    init(excludingProcesses: [AudioObjectID], name: String) throws {
        outputDevice = try SystemAudioHAL.defaultOutputDevice()
        let outputUID = try SystemAudioHAL.deviceUID(outputDevice)
        let description = CATapDescription(monoGlobalTapButExcludeProcesses: excludingProcesses)
        description.isPrivate = true
        description.muteBehavior = .unmuted
        description.name = name
        description.uuid = UUID()
        var tap = AudioObjectID(kAudioObjectUnknown)
        try SystemAudioHAL.check(AudioHardwareCreateProcessTap(description, &tap), "无法创建系统音频采集")
        tapID = tap
        do {
            format = try SystemAudioHAL.tapFormat(tap)
            let configuration: [String: Any] = [
                kAudioAggregateDeviceNameKey: name,
                kAudioAggregateDeviceUIDKey: UUID().uuidString,
                kAudioAggregateDeviceMainSubDeviceKey: outputUID,
                kAudioAggregateDeviceClockDeviceKey: outputUID,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceTapAutoStartKey: false,
                kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
                kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: 1,
                                                   kAudioSubTapUIDKey: description.uuid.uuidString]],
            ]
            var aggregate = AudioObjectID(kAudioObjectUnknown)
            try SystemAudioHAL.check(AudioHardwareCreateAggregateDevice(configuration as CFDictionary, &aggregate),
                                     "无法创建系统音频聚合设备")
            aggregateID = aggregate
        } catch {
            AudioHardwareDestroyProcessTap(tap)
            throw error
        }
    }

    func start(_ handler: @escaping (UnsafePointer<AudioBufferList>, UnsafePointer<AudioTimeStamp>) -> Void) throws {
        let fence = self.fence
        var proc: AudioDeviceIOProcID?
        try SystemAudioHAL.check(AudioDeviceCreateIOProcIDWithBlock(&proc, aggregateID, nil) { _, input, inputTime, _, _ in
            guard fence.enter() else { return }
            defer { fence.leave() }
            handler(input, inputTime)
        }, "无法接收系统音频")
        procID = proc
        try SystemAudioHAL.check(AudioDeviceStart(aggregateID, proc), "无法启动系统音频采集")
    }

    func stop() {
        guard !destroyed else { return }
        destroyed = true
        if let procID { AudioDeviceStop(aggregateID, procID) }
        fence.closeAndWait()
        if let procID { AudioDeviceDestroyIOProcID(aggregateID, procID) }
        procID = nil
        AudioHardwareDestroyAggregateDevice(aggregateID)
        AudioHardwareDestroyProcessTap(tapID)
    }
}

/// Captures everything the Mac plays except Koe itself, clocked to the default output device.
final class NativeSystemAudioSource: SystemAudioSource {
    private let authorizer: SystemAudioAuthorizer
    private var session: AnyObject?
    private var stopSession: (() -> Void)?

    init(authorizer: SystemAudioAuthorizer = CoreAudioCanaryAuthorizer()) { self.authorizer = authorizer }

    func authorize(shouldAbort: @escaping @Sendable () -> Bool,
                   _ completion: @escaping @Sendable (SystemAudioAuthResult) -> Void) {
        let authorizer = self.authorizer
        Task.detached { completion(await authorizer.authorize(shouldAbort: shouldAbort)) }
    }

    func start(expectedSampleRate: UInt32?, receive: @escaping (CapturedPCM) -> Void,
               failed: @escaping (String) -> Void) throws -> UInt32 {
        guard #available(macOS 14.2, *) else { throw CaptureError("录制系统音频需要 macOS 14.2 或更高版本。") }
        stop()
        let capture = try SystemAudioCapture(failed: failed)
        session = capture
        stopSession = { capture.stop() }
        let rate = capture.graph.format.sampleRate
        guard expectedSampleRate == nil || expectedSampleRate == rate else {
            stop()
            throw CaptureError("系统音频采样率发生变化，已保留此前收到的音频。")
        }
        do { try capture.start(receive: receive) } catch { stop(); throw error }
        return rate
    }

    func stop() {
        stopSession?()
        stopSession = nil
        session = nil
    }
}

@available(macOS 14.2, *)
private final class SystemAudioCapture {
    let graph: SystemAudioTapGraph
    private let failed: (String) -> Void
    private let listenerFence = AudioCallbackFence()
    private let queue = DispatchQueue(label: "com.semanticcraft.koe.system-audio.listeners")
    private var listeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []

    init(failed: @escaping (String) -> Void) throws {
        let own = SystemAudioHAL.processObject(pid: ProcessInfo.processInfo.processIdentifier)
        graph = try SystemAudioTapGraph(excludingProcesses: own.map { [$0] } ?? [], name: "Koe 系统音频")
        self.failed = failed
    }

    func start(receive: @escaping (CapturedPCM) -> Void) throws {
        let changed = "系统音频输出设备发生变化，已停止系统音频采集并保留此前收到的音频。"
        listen(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, changed)
        listen(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyServiceRestarted,
               "系统音频服务已重启，已停止系统音频采集并保留此前收到的音频。")
        listen(graph.outputDevice, kAudioDevicePropertyDeviceIsAlive, changed)
        listen(graph.outputDevice, kAudioDevicePropertyNominalSampleRate, "系统音频采样率发生变化，已停止系统音频采集。")
        listen(graph.tapID, kAudioTapPropertyFormat, "系统音频格式发生变化，已停止系统音频采集。")
        let format = graph.format
        let failed = self.failed
        var mixScratch = [Float](repeating: 0, count: SystemAudioConversion.maxFrames)
        try graph.start { input, time in
            do {
                guard time.pointee.mFlags.contains(.hostTimeValid) else {
                    throw CaptureError("系统音频缺少有效采样时钟。")
                }
                let startNs = try HostAudioClock.nanoseconds(time.pointee.mHostTime)
                try SystemAudioConversion.emitMonoSlices(
                    input,
                    format: format,
                    startNs: startNs,
                    mixScratch: &mixScratch,
                    emit: receive
                )
            } catch {
                failed(error.localizedDescription)
            }
        }
    }

    private func listen(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ message: String) {
        var address = SystemAudioHAL.address(selector)
        let fence = listenerFence
        let failed = self.failed
        let block: AudioObjectPropertyListenerBlock = { _, _ in
            guard fence.enter() else { return }
            defer { fence.leave() }
            failed(message)
        }
        guard AudioObjectAddPropertyListenerBlock(object, &address, queue, block) == noErr else { return }
        listeners.append((object, address, block))
    }

    func stop() {
        for (object, address, block) in listeners {
            var address = address
            AudioObjectRemovePropertyListenerBlock(object, &address, queue, block)
        }
        listeners.removeAll()
        listenerFence.closeAndWait()
        graph.stop()
    }
}
