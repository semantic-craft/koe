import Cocoa
import AVFoundation
import Speech
import CoreAudio
import CryptoKit
import FlutterMacOS

/// Press-to-talk: explicit physical input -> local speech -> Dart translation -> pinned PCM output.
final class InterpretingBridge: NSObject, FlutterStreamHandler {
    private var sink: FlutterEventSink?
    private var session = "", token = "", inputUID = "", outputUID = ""
    private var enabled = false, held = false, finishing = false, automatic = false
    private var generation = 0
    private var source: MicrophoneSource?
    private var speech: DualLiveSpeech?
    private var text = ""
    private var pendingBegin: FlutterResult?, pendingFinish: FlutterResult?, pendingSpeak: FlutterResult?
    private var synthesizer: AVSpeechSynthesizer?
    private var buffers: [AVAudioPCMBuffer] = []
    private var bytes = 0
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var timer: Timer?, deadline: Timer?
    private var sleepObserver: NSObjectProtocol?
    private var defaultListener: AudioObjectPropertyListenerBlock?
    private var expectedInput: String?
    private var recoveryError: String?
    private var download: URLSessionDownloadTask?
    private var installResult: FlutterResult?
    private var installGeneration = 0
    private lazy var lease = InputDeviceLease(read: {
        let url = try Self.leaseURL()
        return FileManager.default.fileExists(atPath: url.path) ? try Data(contentsOf: url) : nil
    }, write: { data in
        let url = try Self.leaseURL()
        if let data { try data.write(to: url, options: .atomic) }
        else if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }, current: { try Self.defaultInput() }, physical: { Self.isPhysical($0) }, set: { [weak self] uid in
        self?.expectedInput = uid
        try Self.setInput(uid)
    })
    private static func leaseURL() throws -> URL {
        let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("AnkerRecorder", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.appendingPathComponent("interpreting-input.json")
    }
    func configure(_ messenger: FlutterBinaryMessenger) {
        FlutterMethodChannel(name: "com.semanticcraft.koe/interpreting", binaryMessenger: messenger)
            .setMethodCallHandler { [weak self] call, result in self?.handle(call, result) }
        FlutterEventChannel(name: "com.semanticcraft.koe/interpreting/events", binaryMessenger: messenger).setStreamHandler(self)
        do { try lease.release() } catch { recoveryError = error.localizedDescription }
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in self?.fault("Mac即将睡眠，同传已停止") }
    }
    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? { sink = events; return nil }
    func onCancel(withArguments arguments: Any?) -> FlutterError? { sink = nil; shutdown(); return nil }
    private func emit(_ type: String, _ message: String? = nil) {
        var event: [String: Any] = ["type": type, "session": session, "token": token]
        if let message { event["message"] = message }
        sink?(event)
    }
    private func failure(_ message: String) -> NSError { NSError(domain: "KoeInterpreting", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    private func flutterError(_ error: Error) -> FlutterError { FlutterError(code: "interpreting", message: error.localizedDescription, details: nil) }
    private var cancelled: FlutterError { FlutterError(code: "cancelled", message: "本句已取消", details: nil) }
    private func valid(_ g: Int) -> Bool { enabled && generation == g }
    private func handle(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
        let a = call.arguments as? [String: Any] ?? [:]
        do {
            switch call.method {
            case "devices":
                if !enabled { do { try lease.release(); recoveryError = nil } catch { recoveryError = error.localizedDescription } }
                let devices = AudioDevices.inputDevices()
                result(["inputs": devices.filter { Self.isPhysical($0.uid) }.map { ["uid": $0.uid, "name": $0.name] },
                        "outputs": devices.filter { Self.isBlackHole($0.uid) }.map { ["uid": $0.uid, "name": $0.name] },
                        "defaultInput": (try? Self.defaultInput()) ?? "", "error": recoveryError ?? ""])
            case "enable":
                try disable()
                guard #available(macOS 14.2, *) else { throw failure("Mac同传需要macOS 14.2或更新版本") }
                guard AudioDevices.processObject(pid: ProcessInfo.processInfo.processIdentifier) != nil else { throw failure("无法确认本应用声音排除，同传未开启") }
                guard let input = a["inputUID"] as? String, Self.isPhysical(input), let output = a["outputUID"] as? String, Self.isBlackHole(output), let id = a["session"] as? String else { throw failure("请选择真实麦克风和BlackHole 2ch") }
                session = id; inputUID = input; outputUID = output
                if a["autoInput"] as? Bool == true {
                    try lease.acquire(session: session, target: outputUID)
                    automatic = true
                    do { try watchDefaultInput() } catch { try? lease.release(); automatic = false; throw error }
                }
                enabled = true
                timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.checkDevices() }
                result(nil)
            case "prepareCapture":
                if automatic { try disable() } else { try lease.release(); recoveryError = nil }
                result(nil)
            case "disable": try disable(); result(nil)
            case "cancel": cancel(); result(nil)
            case "begin":
                guard enabled, a["session"] as? String == session, let id = a["token"] as? String else { throw failure("请先启用同传") }
                cancel(); token = id; held = true; text = ""; pendingBegin = result
                let g = generation
                AVCaptureDevice.requestAccess(for: .audio) { [weak self] allowed in
                    DispatchQueue.main.async {
                        guard let self, self.valid(g), self.held else { return }
                        guard allowed else { self.fault("没有麦克风权限"); return }
                        SFSpeechRecognizer.requestAuthorization { status in
                            DispatchQueue.main.async {
                                guard self.valid(g), self.held else { return }
                                guard status == .authorized else { self.fault("没有语音识别权限"); return }
                                self.startCapture(g, locale: a["locale"] as? String ?? "zh-CN")
                            }
                        }
                    }
                }
            case "finish":
                guard enabled, a["session"] as? String == session, a["token"] as? String == token, !finishing else { result(cancelled); return }
                guard pendingBegin == nil else { cancel(); result(cancelled); return }
                finishing = true; held = false; deadline?.invalidate(); source?.stop(); source = nil
                guard let speech else { throw failure("尚未开始识别") }
                pendingFinish = result; let g = generation
                speech.finish { [weak self] in
                    guard let self, self.valid(g) else { return }
                    self.speech = nil; self.finishing = false
                    let done = self.pendingFinish; self.pendingFinish = nil; done?(self.text)
                }
            case "speak":
                guard enabled, a["session"] as? String == session, a["token"] as? String == token, pendingSpeak == nil,
                      let value = a["text"] as? String, !value.isEmpty, value.count <= 12000 else { result(cancelled); return }
                try validateDevices()
                guard let voice = AVSpeechSynthesisVoice(language: a["language"] as? String ?? "en") else { throw failure("系统没有此语种的声音") }
                pendingSpeak = result; buffers = []; bytes = 0
                let g = generation
                deadline?.invalidate()
                deadline = Timer.scheduledTimer(withTimeInterval: 120, repeats: false) { [weak self] _ in self?.fault("合成或播放超时，已停止") }
                let synth = AVSpeechSynthesizer(); synthesizer = synth
                let utterance = AVSpeechUtterance(string: value); utterance.voice = voice
                synth.write(utterance) { [weak self] buffer in
                    guard let pcm = buffer as? AVAudioPCMBuffer else { return }
                    let length = pcm.frameLength
                    let copy = length > 0 ? Self.copy(pcm) : nil
                    DispatchQueue.main.async {
                        guard let self, self.valid(g), self.pendingSpeak != nil else { return }
                        guard length > 0 else {
                            do { try self.play(g) } catch { self.fault(error.localizedDescription) }; return
                        }
                        guard let copy else { self.fault("无法复制合成音频"); return }
                        self.bytes += Int(copy.frameLength) * Int(copy.format.streamDescription.pointee.mBytesPerFrame) * Int(copy.format.isInterleaved ? 1 : copy.format.channelCount)
                        guard self.bytes <= 16 * 1024 * 1024 else { self.fault("译音过长，已停止"); return }
                        self.buffers.append(copy)
                    }
                }
            case "install": install(result)
            case "cancelInstall": cancelInstall(); result(nil)
            default: result(FlutterMethodNotImplemented)
            }
        } catch { result(flutterError(error)) }
    }
    private func startCapture(_ g: Int, locale: String) {
        do {
            try validateDevices()
            let recognizer = DualLiveSpeech(locale: locale, onEnded: { [weak self] in
                guard let self, self.valid(g), self.held else { return }
                self.requestFinish()
            }, onFailure: { [weak self] error in
                guard let self, self.valid(g) else { return }; self.fault(error.localizedDescription)
            }, update: { [weak self] text, _, _, _, _ in
                guard let self, self.valid(g) else { return }; self.text = text
            })
            guard recognizer.start(at: 0) else { throw failure("此语种的本机识别资源不可用，请在系统设置中准备语音资源") }
            speech = recognizer
            let mic = MicrophoneSource(deviceUID: inputUID, strictDevice: true)
            source = mic
            mic.onSamples = { [weak self] samples, _ in DispatchQueue.main.async {
                guard let self, self.valid(g), self.held else { return }; self.speech?.appendBuffer(samples)
            } }
            mic.onInterruption = { [weak self] in DispatchQueue.main.async { guard let self, self.valid(g) else { return }; self.fault("麦克风配置已改变，请重新启用") } }
            try mic.start()
            let done = pendingBegin; pendingBegin = nil; done?(nil)
            deadline = Timer.scheduledTimer(withTimeInterval: 30, repeats: false) { [weak self] _ in self?.requestFinish() }
        } catch { fault(error.localizedDescription) }
    }
    private func requestFinish() {
        guard held else { return }
        source?.stop(); source = nil; deadline?.invalidate()
        emit("finishRequested")
    }
    private func play(_ g: Int) throws {
        guard player == nil, !buffers.isEmpty else { throw failure("系统没有生成可播放译音") }
        try validateDevices()
        let engine = AVAudioEngine(), player = AVAudioPlayerNode()
        self.engine = engine; self.player = player
        guard let id = AudioDevices.deviceID(forUID: outputUID) else { throw failure("输出设备已断开") }
        try engine.outputNode.auAudioUnit.setDeviceID(id)
        guard engine.outputNode.auAudioUnit.deviceID == id else { throw failure("无法确认译音输出设备") }
        engine.attach(player)
        let format = buffers[0].format
        guard buffers.allSatisfy({ $0.format == format }) else { throw failure("合成音频格式发生变化") }
        engine.connect(player, to: engine.mainMixerNode, format: format)
        try engine.start()
        guard engine.outputNode.auAudioUnit.deviceID == id else { throw failure("译音路由已改变") }
        let lastIndex = buffers.count - 1
        for (index, buffer) in buffers.enumerated() {
            player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                guard index == lastIndex else { return }
                DispatchQueue.main.async {
                    guard let self, self.valid(g), self.pendingSpeak != nil else { return }
                    let done = self.pendingSpeak; self.pendingSpeak = nil
                    self.stopOutput(); done?(nil)
                }
            }
        }
        player.play(); emit("playbackStarted")
    }
    private static func copy(_ value: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: value.format, frameCapacity: value.frameLength) else { return nil }
        copy.frameLength = value.frameLength
        let src = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: value.audioBufferList))
        let dst = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for i in 0..<src.count {
            guard let from = src[i].mData, let to = dst[i].mData else { return nil }
            memcpy(to, from, Int(src[i].mDataByteSize))
        }
        return copy
    }
    private func stopOutput() {
        deadline?.invalidate(); deadline = nil
        synthesizer?.stopSpeaking(at: .immediate); synthesizer = nil
        player?.stop(); engine?.stop(); player = nil; engine = nil; buffers = []; bytes = 0
    }
    private func cancel() {
        generation += 1; held = false; finishing = false
        source?.stop(); source = nil
        speech?.finish {}; speech = nil
        stopOutput()
        let callbacks = [pendingBegin, pendingFinish, pendingSpeak]
        pendingBegin = nil; pendingFinish = nil; pendingSpeak = nil
        for done in callbacks { done?(cancelled) }
    }
    private func disable() throws {
        enabled = false; cancel(); timer?.invalidate(); timer = nil
        unwatchDefaultInput()
        try lease.release(); automatic = false; recoveryError = nil
    }
    func shutdown() { cancelInstall(); do { try disable() } catch { recoveryError = error.localizedDescription } }
    private func fault(_ message: String) {
        emit("error", message)
        do { try disable() } catch { recoveryError = error.localizedDescription }
    }
    private func validateDevices() throws {
        guard Self.isPhysical(inputUID), Self.isBlackHole(outputUID) else { throw failure("音频设备已断开或改变，请重新选择") }
        guard #available(macOS 14.2, *), AudioDevices.processObject(pid: ProcessInfo.processInfo.processIdentifier) != nil else { throw failure("无法确认本应用声音排除") }
    }
    private func checkDevices() {
        guard enabled else { return }
        do {
            try validateDevices()
            if let engine, engine.outputNode.auAudioUnit.deviceID != AudioDevices.deviceID(forUID: outputUID) { throw failure("译音路由已改变") }
            if automatic, try Self.defaultInput() != outputUID { try lease.relinquish(); throw failure("默认输入已由用户改变") }
        } catch { fault(error.localizedDescription) }
    }
    private static var defaultAddress: AudioObjectPropertyAddress { AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain) }
    private func watchDefaultInput() throws {
        var address = Self.defaultAddress
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self, self.automatic else { return }
            guard let uid = try? Self.defaultInput() else { self.fault("无法读取默认输入"); return }
            if uid == self.expectedInput { self.expectedInput = nil; return }
            // Notifications to the owned target can include our initial delayed write.
            if uid == self.outputUID { return }
            do { try self.lease.relinquish() } catch { self.recoveryError = error.localizedDescription }
            self.fault("默认输入已改变，同传已停止")
        }
        guard AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, listener) == noErr else { throw failure("无法监测默认输入，同传未开启") }
        defaultListener = listener
    }
    private func unwatchDefaultInput() {
        if let listener = defaultListener { var a = Self.defaultAddress; AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &a, .main, listener) }
        defaultListener = nil; expectedInput = nil
    }
    private static func defaultInput() throws -> String {
        var address = defaultAddress, id: AudioDeviceID = 0, size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr,
              let uid = AudioDevices.string(id, kAudioDevicePropertyDeviceUID) else { throw NSError(domain: "KoeInterpreting", code: 1, userInfo: [NSLocalizedDescriptionKey: "无法读取默认输入"]) }
        return uid
    }
    private static func setInput(_ uid: String) throws {
        guard var id = AudioDevices.deviceID(forUID: uid) else { throw CaptureError.noInput }
        var address = defaultAddress
        guard AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, UInt32(MemoryLayout<AudioDeviceID>.size), &id) == noErr else { throw CaptureError.noInput }
    }
    private static func transport(_ uid: String) -> UInt32? {
        guard let id = AudioDevices.deviceID(forUID: uid) else { return nil }
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0, size: UInt32 = 4
        return AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr ? value : nil
    }
    private static func isPhysical(_ uid: String) -> Bool {
        guard let type = transport(uid), AudioDevices.inputDevices().contains(where: { $0.uid == uid }) else { return false }
        return [kAudioDeviceTransportTypeBuiltIn, kAudioDeviceTransportTypeUSB, kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE, kAudioDeviceTransportTypePCI, kAudioDeviceTransportTypeFireWire, kAudioDeviceTransportTypeThunderbolt].contains(type)
    }
    private static func channels(_ id: AudioDeviceID, _ scope: AudioObjectPropertyScope) -> Int {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size >= MemoryLayout<AudioBufferList>.size else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }
        return UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self)).reduce(0) { $0 + Int($1.mNumberChannels) }
    }
    private static func isBlackHole(_ uid: String) -> Bool {
        guard uid == "BlackHole2ch_UID", transport(uid) == kAudioDeviceTransportTypeVirtual, let id = AudioDevices.deviceID(forUID: uid) else { return false }
        return channels(id, kAudioDevicePropertyScopeInput) == 2 && channels(id, kAudioDevicePropertyScopeOutput) == 2
    }
    private func cancelInstall() {
        installGeneration += 1; download?.cancel(); download = nil
        let done = installResult; installResult = nil; done?(cancelled)
    }
    private func install(_ result: @escaping FlutterResult) {
        guard !enabled, installResult == nil else { result(cancelled); return }
        installResult = result; installGeneration += 1; let g = installGeneration
        let url = URL(string: "https://existential.audio/downloads/BlackHole2ch-0.7.1.pkg")!
        var request = URLRequest(url: url); request.timeoutInterval = 60
        download = URLSession.shared.downloadTask(with: request) { [weak self] temporary, response, error in
            var outcome: Result<URL, Error>
            do {
                guard error == nil, let temporary, (response as? HTTPURLResponse)?.statusCode == 200 else { throw error ?? URLError(.badServerResponse) }
                let attributes = try FileManager.default.attributesOfItem(atPath: temporary.path)
                guard (attributes[.size] as? NSNumber)?.intValue ?? Int.max <= 32 * 1024 * 1024 else { throw URLError(.dataLengthExceedsMaximum) }
                let data = try Data(contentsOf: temporary)
                let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                guard digest == "57b540f27a3e29c37e310e01bee0fdfab76733087e47f997ef9dccf851400dcf" else { throw URLError(.cannotDecodeContentData) }
                let root = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("KoeInterpreting", isDirectory: true)
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                let package = root.appendingPathComponent("BlackHole2ch.pkg")
                try data.write(to: package, options: .atomic); outcome = .success(package)
            } catch { outcome = .failure(error) }
            DispatchQueue.main.async {
                guard let self, self.installGeneration == g else { return }
                let done = self.installResult; self.installResult = nil; self.download = nil
                switch outcome {
                case .success(let package): done?(NSWorkspace.shared.open(package) ? nil : self.flutterError(self.failure("无法打开系统安装器")))
                case .failure(let error): done?(self.flutterError(error))
                }
            }
        }
        download?.resume()
    }
}
