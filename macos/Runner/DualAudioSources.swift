// Audio source adapters adapted from Shiyin (MIT), commit 7ffd7d4.
// Copyright Shiyin contributors; see assets/licenses/shiyin.txt.
import AVFoundation
import CoreAudio
import Foundation

/// 所有音源輸出的統一格式：16 kHz、單聲道、Float32（design §5.1）
enum CaptureFormat {
    static let sampleRate: Double = 16_000
    static let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
}

/// 音源：把收到的音訊轉成 16 kHz 單聲道後交給 `onSamples`。callback 在音訊執行緒上，不能做重的事。
protocol AudioSource: AnyObject {
    var onSamples: (([Float], Double) -> Void)? { get set }
    /// 音源發現裝置變了（design §20.2），任何執行緒都可能呼叫；Recorder 收到後會 `restart()`
    var onInterruption: (() -> Void)? { get set }
    func start() throws
    func stop()
    func restart() throws
}

extension AudioSource {
    func restart() throws {
        stop()
        try start()
    }
}

/// 把任意格式的 buffer 持續轉成 16 kHz 單聲道（保留重取樣的狀態，適合串流）
final class StreamConverter {
    private let converter: AVAudioConverter

    init?(from format: AVAudioFormat) {
        guard let converter = AVAudioConverter(from: format, to: CaptureFormat.mono) else { return nil }
        converter.downmix = true
        self.converter = converter
    }

    func convert(_ buffer: AVAudioPCMBuffer) -> [Float] {
        let ratio = CaptureFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 64)
        guard let output = AVAudioPCMBuffer(pcmFormat: CaptureFormat.mono, frameCapacity: capacity) else { return [] }
        var fed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if fed {
                status.pointee = .noDataNow
                return nil
            }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let data = output.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: data[0], count: Int(output.frameLength)))
    }
}

/// 麥克風（AVAudioEngine）。可以指定輸入裝置的 UID，空字串表示系統預設。
final class MicrophoneSource: AudioSource {
    var onSamples: (([Float], Double) -> Void)?
    var onInterruption: (() -> Void)?
    private var engine = AVAudioEngine()
    private var observer: NSObjectProtocol?
    private let deviceUID: String

    init(deviceUID: String) {
        self.deviceUID = deviceUID
    }

    /// 每次開始都用新的 engine：重新開始時重讀輸入格式；指定的裝置不在了，新的 engine 就跟著系統預設（design §20.2）
    func start() throws {
        engine = AVAudioEngine()
        let input = engine.inputNode
        if !deviceUID.isEmpty, let id = AudioDevices.deviceID(forUID: deviceUID) {
            try input.auAudioUnit.setDeviceID(id)
        }
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, let converter = StreamConverter(from: format) else {
            throw CaptureError.noInput
        }
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, time in
            let samples = converter.convert(buffer)
            if !samples.isEmpty { self?.onSamples?(samples, (time.isHostTimeValid ? AVAudioTime.seconds(forHostTime: time.hostTime) : ProcessInfo.processInfo.systemUptime) + Double(samples.count) / CaptureFormat.sampleRate) }
        }
        // 接上或拔掉耳機、藍牙換協定、取樣率改變時，engine 會自己停下來並送出這個通知
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
            self?.onInterruption?()
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }
}

/// 電腦播放的聲音（Core Audio process tap，macOS 14.4+，design §5.1）
@available(macOS 14.2, *)
final class SystemAudioSource: AudioSource {
    var onSamples: (([Float], Double) -> Void)?
    var onInterruption: (() -> Void)?
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var outputListener: AudioObjectPropertyListenerBlock?
    private let queue = DispatchQueue(label: "com.semanticcraft.koe.systemaudio", qos: .userInitiated)
    private static var defaultOutputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)

    func start() throws {
        // 排除自己（播放錄音時不要錄進去）
        let own = AudioDevices.processObject(pid: ProcessInfo.processInfo.processIdentifier)
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: own.map { [$0] } ?? [])
        description.uuid = UUID()
        description.muteBehavior = .unmuted
        description.isPrivate = true
        try check(AudioHardwareCreateProcessTap(description, &tapID), String(localized: "建立系統聲音擷取"))

        guard let outputUID = AudioDevices.defaultOutputUID() else { stop(); throw CaptureError.noOutputDevice }
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: String(localized: "Koe系統聲音"),
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true,
                                               kAudioSubTapUIDKey: description.uuid.uuidString]],
        ]
        try check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID), String(localized: "建立聚合裝置"))

        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        try check(AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &asbd), String(localized: "讀取系統聲音格式"))
        guard let format = AVAudioFormat(streamDescription: &asbd), let converter = StreamConverter(from: format) else {
            stop(); throw CaptureError.unsupportedFormat
        }
        try check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { [weak self] _, input, inputTime, _, _ in
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: input, deallocator: nil) else { return }
            let samples = converter.convert(buffer)
            if !samples.isEmpty { self?.onSamples?(samples, AVAudioTime.seconds(forHostTime: inputTime.pointee.mHostTime) + Double(samples.count) / CaptureFormat.sampleRate) }
        }, String(localized: "建立系統聲音的 IO"))
        try check(AudioDeviceStart(aggregateID, procID), String(localized: "開始擷取系統聲音"))
        // 預設輸出換了（接上耳機、換成藍牙喇叭）：聚合裝置還綁著舊的輸出，要用新的重建（design §20.2）
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.onInterruption?() }
        if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &Self.defaultOutputAddress, queue, listener) == noErr {
            outputListener = listener
        }
    }

    /// 一定要依序清乾淨，否則 HAL 可能卡住（design §5.1）
    func stop() {
        if let outputListener {
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &Self.defaultOutputAddress, queue, outputListener)
        }
        outputListener = nil
        if aggregateID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    private func check(_ status: OSStatus, _ step: String) throws {
        if status != noErr {
            stop()
            throw CaptureError.coreAudio(step, status)
        }
    }
}

enum CaptureError: LocalizedError {
    case noInput
    case noOutputDevice
    case unsupportedFormat
    case coreAudio(String, OSStatus)

    var errorDescription: String? {
        switch self {
        case .noInput: return String(localized: "找不到可以用的麥克風")
        case .noOutputDevice: return String(localized: "找不到輸出裝置，沒辦法擷取系統聲音")
        case .unsupportedFormat: return String(localized: "不支援這個音訊格式")
        case .coreAudio(let step, let status): return String(localized: "\(step)失敗（錯誤代碼 \(status)）。請確認已允許Koe「錄製系統音訊」")
        }
    }
}

/// Core Audio 裝置查詢
enum AudioDevices {
    struct Device: Identifiable, Hashable {
        var id: String { uid }
        var uid: String
        var name: String
    }

    static func inputDevices() -> [Device] {
        allDevices().compactMap { id in
            guard hasInputStreams(id), let uid = string(id, kAudioDevicePropertyDeviceUID),
                  let name = string(id, kAudioObjectPropertyName) else { return nil }
            return Device(uid: uid, name: name)
        }
    }

    static func deviceID(forUID uid: String) -> AudioDeviceID? {
        allDevices().first { string($0, kAudioDevicePropertyDeviceUID) == uid }
    }

    static func defaultOutputUID() -> String? {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr else { return nil }
        return string(id, kAudioDevicePropertyDeviceUID)
    }

    @available(macOS 14.2, *)
    static func processObject(pid: pid_t) -> AudioObjectID? {
        var pid = pid
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                                UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
        return status == noErr && object != kAudioObjectUnknown ? object : nil
    }

    private static func allDevices() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func hasInputStreams(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioDevicePropertyScopeInput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr && size > 0
    }

    private static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}
