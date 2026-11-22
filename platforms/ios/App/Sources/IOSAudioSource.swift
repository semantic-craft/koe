import AVFoundation
import KoeAppleCore
import os

final class IOSAudioSource: MicrophoneSource {
    static let logger = Logger(subsystem: "com.semanticcraft.koe.ios", category: "capture")
    private let session = AVAudioSession.sharedInstance()
    private let audioSession: IOSAudioSession
    private let reportError: (String) -> Void
    private var engine: AVAudioEngine?
    private var fence: AudioCallbackFence?
    private var routeObserver: IOSCaptureRouteObserver?

    init(audioSession: IOSAudioSession, reportError: @escaping (String) -> Void) {
        self.audioSession = audioSession
        self.reportError = reportError
    }

    func requestPermission(_ completion: @escaping @Sendable (Bool) -> Void) {
        AVAudioApplication.requestRecordPermission(completionHandler: completion)
    }

    func start(inputID: String, expectedSampleRate: UInt32?, receive: @escaping @Sendable (CapturedPCM) -> Void,
               failed: @escaping @Sendable (String) -> Void) throws -> UInt32 {
        stop()
        try audioSession.setActive(true, for: .microphone)
        do {
            let preferred = session.availableInputs?.first { $0.uid == inputID }
            guard inputID.isEmpty || preferred != nil else {
                throw CaptureError("所选输入设备已不可用，请重新选择。")
            }
            try session.setPreferredInput(preferred)
            guard let inputUID = session.currentRoute.inputs.first?.uid,
                  inputID.isEmpty || inputUID == inputID else {
                throw CaptureError("所选输入设备未接通，请检查麦克风。")
            }

            let engine = AVAudioEngine()
            let node = engine.inputNode
            let format = node.inputFormat(forBus: 0)
            let rate = try CapturedPCM.sampleRate(for: format, expectedSampleRate: expectedSampleRate)
            let fence = AudioCallbackFence()
            self.fence = fence
            routeObserver = IOSCaptureRouteObserver(
                fence: fence, initialInputUID: inputUID,
                currentInputUID: { [session] in session.currentRoute.inputs.first?.uid }, failed: failed
            )
            node.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, when in
                guard fence.enter() else { return }
                defer { fence.leave() }
                do {
                    receive(try CapturedPCM.capture(buffer, when: when, expectedSampleRate: rate))
                } catch {
                    failed(error.localizedDescription)
                }
            }
            self.engine = engine
            try engine.start()
            routeObserver?.observeConfiguration(of: engine)
            guard engine.isRunning else { throw CaptureError("麦克风采集引擎未能保持运行。") }
            return rate
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        routeObserver?.stop()
        routeObserver = nil
        fence?.closeAndWait()
        engine?.stop()
        engine?.inputNode.removeTap(onBus: 0)
        engine = nil
        fence = nil
        do {
            try audioSession.setActive(false, for: .microphone)
        } catch {
            let message = "停用麦克风音频会话失败：\(error.localizedDescription)"
            Self.logger.error("\(message, privacy: .public)")
            reportError(message)
        }
    }

    deinit { stop() }
}

final class IOSCaptureRouteObserver {
    private let center: NotificationCenter
    private var tokens: [NSObjectProtocol] = []
    private let listening = OSAllocatedUnfairLock(initialState: true)
    private let end: @Sendable (String) -> Void

    init(center: NotificationCenter = .default, fence: AudioCallbackFence, initialInputUID: String,
         currentInputUID: @escaping @Sendable () -> String?, failed: @escaping @Sendable (String) -> Void) {
        self.center = center
        end = { [listening] message in
            let shouldEnd = listening.withLock { active in
                guard active else { return false }
                active = false
                return true
            }
            guard shouldEnd else { return }
            fence.closeAndWait()
            failed(message)
        }
        let session = AVAudioSession.sharedInstance()
        tokens.append(center.addObserver(forName: AVAudioSession.interruptionNotification,
                                         object: session, queue: nil) { [end] notification in
            let type = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            if type == AVAudioSession.InterruptionType.began.rawValue {
                end("麦克风采集被系统中断，已停止并保留此前收到的音频。")
            }
        })
        tokens.append(center.addObserver(forName: AVAudioSession.routeChangeNotification,
                                         object: session, queue: nil) { [end] _ in
            if currentInputUID() != initialInputUID {
                end("麦克风输入设备发生变化，已停止并保留此前收到的音频。")
            }
        })
    }

    func observeConfiguration(of engine: AVAudioEngine) {
        tokens.append(center.addObserver(forName: .AVAudioEngineConfigurationChange,
                                         object: engine, queue: nil) { [end] _ in
            if !engine.isRunning { end("音频硬件配置改变，已停止采集并保留此前收到的音频。") }
        })
    }

    func stop() {
        listening.withLock { $0 = false }
        tokens.forEach(center.removeObserver)
        tokens.removeAll()
    }

    deinit { stop() }
}
