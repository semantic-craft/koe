import AVFoundation
import CoreAudio
import Foundation

struct MicrophoneInput {
    let id: String
    let name: String
}

final class NativeAudioSource: MicrophoneSource {
    private var engine: AVAudioEngine?
    private var fence: AudioCallbackFence?
    private var observer: NSObjectProtocol?
    func requestPermission(_ completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: completion(true)
        case .notDetermined: AVCaptureDevice.requestAccess(for: .audio, completionHandler: completion)
        default: completion(false)
        }
    }
    func start(inputID: String, expectedSampleRate: UInt32?, receive: @escaping (CapturedPCM) -> Void, failed: @escaping (String) -> Void) throws -> UInt32 {
        let engine = AVAudioEngine()
        let node = engine.inputNode
        if !inputID.isEmpty {
            guard let device = Self.deviceIDs().first(where: { Self.uid($0) == inputID }) else {
                throw CaptureError("所选输入设备已不可用，请重新选择。")
            }
            try node.auAudioUnit.setDeviceID(device)
        }
        let format = node.outputFormat(forBus: 0)
        guard format.sampleRate >= 8_000, format.sampleRate <= 96_000,
              format.sampleRate.rounded() == format.sampleRate, format.channelCount > 0,
              format.commonFormat == .pcmFormatFloat32, !format.isInterleaved else {
            throw CaptureError("麦克风没有可用的 PCM 输入格式。")
        }
        let rate = UInt32(format.sampleRate)
        guard expectedSampleRate == nil || expectedSampleRate == rate else {
            throw CaptureError("麦克风采样率发生变化，已保留此前收到的音频。")
        }
        let fence = AudioCallbackFence()
        self.fence = fence
        node.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, when in
            guard fence.enter() else { return }
            defer { fence.leave() }
            do { receive(try Self.capture(buffer, when: when, expectedSampleRate: rate)) }
            catch { failed(error.localizedDescription) }
        }
        observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { _ in
            guard fence.enter() else { return }
            defer { fence.leave() }
            failed("输入设备发生变化，已停止采集。请检查设备后重新开始。")
        }
        self.engine = engine
        do { try engine.start() } catch { stop(); throw error }
        return UInt32(format.sampleRate)
    }
    static func capture(_ buffer: AVAudioPCMBuffer, when: AVAudioTime,
                        expectedSampleRate: UInt32) throws -> CapturedPCM {
        guard when.isHostTimeValid else { throw CaptureError("音频缺少有效采样时钟。") }
        guard buffer.format.sampleRate == Double(expectedSampleRate),
              buffer.format.channelCount > 0, buffer.format.commonFormat == .pcmFormatFloat32,
              !buffer.format.isInterleaved, let channels = buffer.floatChannelData else {
            throw CaptureError("麦克风输入格式已改变。")
        }
        let count = Int(buffer.frameLength)
        guard count > 0, count <= 8192 else { throw CaptureError("麦克风音频块超过接收上限。") }
        let channelCount = Int(buffer.format.channelCount)
        var samples = [Int16](repeating: 0, count: count)
        for frame in 0..<count {
            var value: Float = 0
            for channel in 0..<channelCount { value += channels[channel][frame] / Float(channelCount) }
            samples[frame] = value.isFinite ? Int16(max(-1, min(1, value)) * 32767) : 0
        }
        return CapturedPCM(samples: samples, capturedStartNs: try HostAudioClock.nanoseconds(when.hostTime))
    }
    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        guard let engine else { return }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        fence?.closeAndWait()
        fence = nil
        self.engine = nil
    }
    static func inputs() -> [MicrophoneInput] {
        deviceIDs().compactMap { device in
            var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration, mScope: kAudioDevicePropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
            var size: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0 else { return nil }
            let memory = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
            defer { memory.deallocate() }
            guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, memory) == noErr else { return nil }
            let buffers = UnsafeMutableAudioBufferListPointer(memory.assumingMemoryBound(to: AudioBufferList.self))
            guard buffers.contains(where: { $0.mNumberChannels > 0 }), let id = uid(device) else { return nil }
            return MicrophoneInput(id: id, name: stringProperty(device, kAudioObjectPropertyName) ?? id)
        }
    }
    private static func deviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &devices) == noErr else { return [] }
        return devices
    }
    private static func uid(_ device: AudioDeviceID) -> String? { stringProperty(device, kAudioDevicePropertyDeviceUID) }
    private static func stringProperty(_ device: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(device, &address, 0, nil, &size, pointer)
        }
        guard status == noErr else { return nil }
        return value as String
    }
}
struct CaptureError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
