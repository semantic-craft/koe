import AudioToolbox
import CoreAudio
import CoreGraphics
import Foundation
import KoeAppleShared
import os

protocol SystemAudioAuthorizer: Sendable {
    func authorize(shouldAbort: @escaping @Sendable () -> Bool) async -> SystemAudioAuthResult
}

/// One poll of the canary: only real non-zero tap samples prove authorization.
struct SystemAudioCanaryObservation: Equatable, Sendable {
    var elapsed: TimeInterval
    var renderedOutputCallbacks: Int
    var tapCallbacks: Int
    var detectedNonZeroSignal: Bool
    var promptVisible: Bool
    var aborted: Bool = false
}

/// Pure decision rules. `AudioDeviceStart == noErr` or silent buffers never authorize; zero buffers
/// deny only after the in-process canary demonstrably rendered and no permission prompt is on screen.
struct SystemAudioCanaryEvaluator: Sendable {
    static let deniedMessage = "系统音频权限未开启，请在系统设置中允许 Koe 录制系统音频"
    static let signalThreshold: Float = 5.0e-6
    var minimumCallbacks = 20
    var settleSeconds: TimeInterval = 1.0
    var timeoutSeconds: TimeInterval = 60
    private(set) var sawPrompt = false
    private var quietSince: TimeInterval = 0
    private var renderedBaseline = 0
    private var tapBaseline = 0

    init(timeoutSeconds: TimeInterval = 60) { self.timeoutSeconds = timeoutSeconds }

    mutating func evaluate(_ o: SystemAudioCanaryObservation) -> SystemAudioAuthResult? {
        if o.aborted { return .cancelled }
        if o.detectedNonZeroSignal { return .authorized }
        if o.promptVisible {
            sawPrompt = true
            quietSince = o.elapsed
            renderedBaseline = o.renderedOutputCallbacks
            tapBaseline = o.tapCallbacks
        } else if o.elapsed - quietSince >= settleSeconds,
                  o.renderedOutputCallbacks - renderedBaseline >= minimumCallbacks,
                  o.tapCallbacks - tapBaseline >= minimumCallbacks {
            return .denied(Self.deniedMessage)
        }
        guard o.elapsed >= timeoutSeconds else { return nil }
        if o.promptVisible { return .unavailable("等待系统音频授权超时，请重试。") }
        if o.renderedOutputCallbacks - renderedBaseline < minimumCallbacks {
            return .unavailable("无法播放系统音频检测信号，请检查输出设备。")
        }
        return .unavailable("系统音频采集没有返回数据，请检查输出设备。")
    }

    /// A decision made right after the user answered the prompt is re-checked on a fresh tap,
    /// because an already-running tap may keep delivering silence from before the answer.
    func shouldRetry(after result: SystemAudioAuthResult) -> Bool {
        if case .denied = result { return sawPrompt }
        return false
    }
}

/// Inaudible (-100 dBFS) Barker-13 canary rendered by this process into the default output.
enum SystemAudioCanaryTone {
    static let amplitude: Float = 1.0e-5
    static let chipFrames = 48
    static let barker: [Float] = [1, 1, 1, 1, 1, -1, -1, 1, 1, -1, 1, -1, 1]
    static func sample(at frame: Int) -> Float {
        amplitude * barker[(frame / chipFrames) % barker.count]
    }
}

/// Public window-list lookup used only to avoid denying while a permission prompt is on screen.
enum SystemPermissionPrompt {
    static let owners: Set<String> = ["UserNotificationCenter", "CoreAuthUI", "SecurityAgent", "universalAccessAuthWarn"]
    static func visible(in windows: [[String: Any]]) -> Bool {
        windows.contains { window in
            guard let owner = window[kCGWindowOwnerName as String] as? String, owners.contains(owner) else { return false }
            return ((window[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0) > 0
        }
    }
    static func visibleOnScreen() -> Bool {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return false }
        return visible(in: windows)
    }
}

final class SystemAudioCanaryState: @unchecked Sendable {
    struct Counts { var rendered = 0; var tap = 0; var detected = false; var frame = 0 }
    private let lock = OSAllocatedUnfairLock(initialState: Counts())
    var counts: Counts { lock.withLock { $0 } }
    func recordTap(peak: Float) {
        lock.withLock {
            $0.tap += 1
            if peak.isFinite, peak >= SystemAudioCanaryEvaluator.signalThreshold { $0.detected = true }
        }
    }
    func render(frames: Int, into list: UnsafeMutableAudioBufferListPointer) {
        let start = lock.withLock { counts -> Int in
            let first = counts.frame
            counts.frame = (counts.frame + frames) % (SystemAudioCanaryTone.chipFrames * SystemAudioCanaryTone.barker.count)
            counts.rendered += 1
            return first
        }
        for buffer in list {
            guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let count = min(frames, Int(buffer.mDataByteSize) / MemoryLayout<Float>.size)
            for index in 0..<count { data[index] = SystemAudioCanaryTone.sample(at: start + index) }
        }
    }
}

private func renderCanary(_ refCon: UnsafeMutableRawPointer, _ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                          _ timeStamp: UnsafePointer<AudioTimeStamp>, _ bus: UInt32, _ frames: UInt32,
                          _ data: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus {
    guard let data else { return noErr }
    Unmanaged<SystemAudioCanaryState>.fromOpaque(refCon).takeUnretainedValue()
        .render(frames: Int(frames), into: UnsafeMutableAudioBufferListPointer(data))
    return noErr
}

/// Default-output AudioUnit that plays the canary. Retains its state for the unit's lifetime.
final class SystemAudioCanaryOutput {
    private let state: SystemAudioCanaryState
    private var unit: AudioUnit?
    init(state: SystemAudioCanaryState) { self.state = state }

    func start() throws {
        var description = AudioComponentDescription(componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_DefaultOutput, componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0, componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &description) else {
            throw CaptureError("无法打开默认音频输出。")
        }
        var created: AudioUnit?
        try SystemAudioHAL.check(AudioComponentInstanceNew(component, &created), "无法打开默认音频输出")
        guard let unit = created else { throw CaptureError("无法打开默认音频输出。") }
        self.unit = unit
        var format = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagsNativeFloatPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 1,
            mBitsPerChannel: 32, mReserved: 0)
        try SystemAudioHAL.check(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0,
            &format, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)), "无法设置检测信号格式")
        var callback = AURenderCallbackStruct(inputProc: renderCanary,
            inputProcRefCon: Unmanaged.passUnretained(state).toOpaque())
        try SystemAudioHAL.check(AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0,
            &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)), "无法设置检测信号")
        try SystemAudioHAL.check(AudioUnitInitialize(unit), "无法初始化默认音频输出")
        try SystemAudioHAL.check(AudioOutputUnitStart(unit), "无法播放检测信号")
    }

    func stop() {
        guard let unit else { return }
        self.unit = nil
        AudioOutputUnitStop(unit)
        AudioUnitUninitialize(unit)
        AudioComponentInstanceDispose(unit)
    }
}

/// Live canary: a private global mono tap (self included) on a private aggregate device listens for
/// this process's own inaudible canary through public Core Audio APIs only.
struct CoreAudioCanaryAuthorizer: SystemAudioAuthorizer {
    var promptVisible: @Sendable () -> Bool = { SystemPermissionPrompt.visibleOnScreen() }
    var pollInterval: Duration = .milliseconds(50)

    func authorize(shouldAbort: @escaping @Sendable () -> Bool) async -> SystemAudioAuthResult {
        guard #available(macOS 14.2, *) else {
            return .unavailable("录制系统音频需要 macOS 14.2 或更高版本。")
        }
        var evaluator = SystemAudioCanaryEvaluator()
        let first = await round(&evaluator, shouldAbort: shouldAbort)
        guard evaluator.shouldRetry(after: first) else { return first }
        var retry = SystemAudioCanaryEvaluator(timeoutSeconds: 15)
        return await round(&retry, shouldAbort: shouldAbort)
    }

    @available(macOS 14.2, *)
    private func round(_ evaluator: inout SystemAudioCanaryEvaluator,
                       shouldAbort: @escaping @Sendable () -> Bool) async -> SystemAudioAuthResult {
        let state = SystemAudioCanaryState()
        let graph: SystemAudioTapGraph
        do {
            graph = try SystemAudioTapGraph(excludingProcesses: [], name: "Koe 系统音频授权检测")
        } catch {
            return .unavailable(error.localizedDescription)
        }
        defer { graph.stop() }
        let format = graph.format
        do {
            try graph.start { input, _ in
                state.recordTap(peak: SystemAudioConversion.peak(input, format: format))
            }
        } catch {
            return .unavailable(error.localizedDescription)
        }
        let output = SystemAudioCanaryOutput(state: state)
        defer { output.stop() }
        do { try output.start() } catch { return .unavailable(error.localizedDescription) }
        let started = ContinuousClock.now
        while true {
            let counts = state.counts
            let elapsed = started.duration(to: .now)
            let observation = SystemAudioCanaryObservation(
                elapsed: Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18,
                renderedOutputCallbacks: counts.rendered, tapCallbacks: counts.tap,
                detectedNonZeroSignal: counts.detected, promptVisible: promptVisible(), aborted: shouldAbort())
            if let result = evaluator.evaluate(observation) { return result }
            try? await Task.sleep(for: pollInterval)
        }
    }
}
