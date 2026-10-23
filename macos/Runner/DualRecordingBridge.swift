import AVFoundation
import FlutterMacOS
import Speech

/// Main-thread lifecycle; WAV writes are serialized on a separate queue.
/// The queue is drained before closing either file or replying to stop.
final class DualRecordingBridge: NSObject, FlutterStreamHandler {
    static let shared = DualRecordingBridge()
    private var sink: FlutterEventSink?
    private var mic: MicrophoneSource?
    private var system: AudioSource?
    private let queue = DispatchQueue(label: "com.semanticcraft.koe.dual-writer")
    private var writers: [String: DualRecordingWriter] = [:] // queue only
    private var started = 0.0
    private var pauseStarted: Double?
    private var pausedSeconds = 0.0
    private var active = false
    private var transcribe = true
    private var generation = 0
    private var lastLevel: [String: Double] = [:]
    private var lastData: [String: Double] = [:]
    private var lastSound: [String: Double] = [:]
    private var lastRestart: [String: Double] = [:]
    private var notices: [String: String] = [:]
    private var timer: Timer?
    private var speech: [String: DualLiveSpeech] = [:]
    private var drainingSpeech: [DualLiveSpeech] = []

    func configure(_ messenger: FlutterBinaryMessenger) {
        FlutterEventChannel(name: "com.semanticcraft.koe/dual_recording/events", binaryMessenger: messenger).setStreamHandler(self)
        FlutterMethodChannel(name: "com.semanticcraft.koe/dual_recording", binaryMessenger: messenger).setMethodCallHandler { [weak self] call, result in
            guard let self else { return result(nil) }
            do {
                switch call.method {
                case "supported":
                    if #available(macOS 14.2, *) { result(true) } else { result(false) }
                case "start":
                    guard let args = call.arguments as? [String: Any], let path = args["path"] as? String else {
                        throw CocoaError(.fileWriteInvalidFileName)
                    }
                    try self.start(path: path, input: args["input"] as? String ?? "", transcribe: args["transcribe"] as? Bool ?? true)
                    result(nil)
                case "pause": self.pause(); result(nil)
                case "resume": self.resume(); result(nil)
                case "stop": self.stop { error in
                    if let error { result(FlutterError(code: "dual_recording", message: error.localizedDescription, details: nil)) }
                    else { result(nil) }
                }
                default: result(FlutterMethodNotImplemented)
                }
            } catch { result(FlutterError(code: "dual_recording", message: error.localizedDescription, details: nil)) }
        }
    }

    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? { sink = events; return nil }
    func onCancel(withArguments arguments: Any?) -> FlutterError? { sink = nil; return nil }

    private func start(path: String, input: String, transcribe: Bool) throws {
        guard !active else { throw CocoaError(.fileWriteFileExists) }
        guard #available(macOS 14.2, *) else { throw CaptureError.unsupportedFormat }
        let micWriter = try DualRecordingWriter(path: path)
        let systemWriter = try DualRecordingWriter(path: path + ".system.wav")
        queue.sync { writers = ["microphone": micWriter, "system": systemWriter] }
        self.transcribe = transcribe
        active = true; generation += 1
        started = ProcessInfo.processInfo.systemUptime
        pausedSeconds = 0; pauseStarted = nil
        lastData = [:]; lastSound = [:]; lastRestart = [:]; notices = [:]
        let mic = MicrophoneSource(deviceUID: input), system = SystemAudioSource()
        self.mic = mic; self.system = system
        configureSource(mic, lane: "microphone")
        configureSource(system, lane: "system")
        do { try mic.start(); try system.start() }
        catch { stop { _ in }; throw error }
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.watch() }
        guard transcribe else { return }
        let token = generation
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            DispatchQueue.main.async {
                guard let self, self.active, self.generation == token else { return }
                guard status == .authorized else {
                    self.emit(["speechNotice": "未允许语音识别；双路原件仍会保存"]); return
                }
                for lane in ["microphone", "system"] {
                    let live = DualLiveSpeech { [weak self] text, offset, final in
                        self?.emit(["lane": lane, "text": text, "offset": offset, "final": final])
                    }
                    if live.start(at: self.elapsed) { self.speech[lane] = live }
                    else { self.emit(["speechNotice": "此设备暂不支持本机实时识别；双路原件仍会保存"]) }
                }
            }
        }
    }

    private var elapsed: Double {
        max(0, (pauseStarted ?? ProcessInfo.processInfo.systemUptime) - started - pausedSeconds)
    }

    private func configureSource(_ source: AudioSource, lane: String) {
        let token = generation
        source.onSamples = { [weak self] samples, capturedEnd in
            let received = ProcessInfo.processInfo.systemUptime
            DispatchQueue.main.async {
                guard let self, self.active, self.generation == token, self.pauseStarted == nil else { return }
                self.lastData[lane] = received
                let peak = samples.reduce(Float(0)) { max($0, abs($1)) }
                if peak > 0.00001 { self.lastSound[lane] = received }
                if received - (self.lastLevel[lane] ?? 0) >= 0.1 {
                    self.lastLevel[lane] = received
                    self.emit(["lane": lane, "level": peak > 0 ? max(-160, 20 * log10(Double(peak))) : -160])
                }
                let ending = max(0, capturedEnd - self.started - self.pausedSeconds)
                self.queue.async { [weak self] in
                    guard let self else { return }
                    do { try self.writers[lane]?.append(samples, endingAt: ending) }
                    catch { DispatchQueue.main.async { self.failWrite(error, token: token) } }
                }
                self.speech[lane]?.append(samples, at: ending)
            }
        }
        source.onInterruption = { [weak self] in
            DispatchQueue.main.async { self?.restart(lane, token: token) }
        }
    }

    private func restart(_ lane: String, token: Int) {
        guard active, generation == token, pauseStarted == nil else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - (lastRestart[lane] ?? 0) >= 3 else { return }
        lastRestart[lane] = now
        do {
            if lane == "microphone" { try mic?.restart() } else { try system?.restart() }
        } catch { notice(lane, "音源重连失败，将继续重试；已录部分保留") }
    }

    private func notice(_ lane: String, _ text: String) {
        if notices[lane] == text { return }
        notices[lane] = text; emit(["lane": lane, "notice": text])
    }

    private func watch() {
        guard active, pauseStarted == nil else { return }
        let now = ProcessInfo.processInfo.systemUptime
        for lane in ["microphone", "system"] {
            if now - (lastData[lane] ?? started) > 3 {
                notice(lane, "音源已超过 3 秒没有数据，正在重连")
                restart(lane, token: generation)
            } else if lane == "system" && now - (lastSound[lane] ?? started) > 5 {
                notice(lane, "系统声音为静音；若正在播放，请检查系统设置中的屏幕与系统音频录制权限")
            } else { notice(lane, "") }
        }
    }

    private func pause() {
        guard active, pauseStarted == nil else { return }
        pauseStarted = ProcessInfo.processInfo.systemUptime
        generation += 1
        mic?.stop(); system?.stop()
        for live in speech.values {
            drainingSpeech.append(live)
            live.finish { [weak self, weak live] in self?.drainingSpeech.removeAll { $0 === live } }
        }
        speech.removeAll()
    }
    private func resume() {
        guard active, let paused = pauseStarted else { return }
        pausedSeconds += ProcessInfo.processInfo.systemUptime - paused; pauseStarted = nil
        lastData = ["microphone": ProcessInfo.processInfo.systemUptime, "system": ProcessInfo.processInfo.systemUptime]
        if let mic { configureSource(mic, lane: "microphone") }
        if let system { configureSource(system, lane: "system") }
        lastRestart = [:]
        restart("microphone", token: generation); restart("system", token: generation)
        if transcribe && SFSpeechRecognizer.authorizationStatus() == .authorized {
            for lane in ["microphone", "system"] {
                let live = DualLiveSpeech { [weak self] text, offset, final in self?.emit(["lane": lane, "text": text, "offset": offset, "final": final]) }
                if live.start(at: elapsed) { speech[lane] = live }
            }
        }
    }
    private func stop(completion: @escaping (Error?) -> Void) {
        guard active else { completion(nil); return }
        let duration = elapsed
        active = false; generation += 1; timer?.invalidate(); timer = nil
        mic?.stop(); system?.stop(); mic = nil; system = nil
        var writeError: Error?
        queue.sync {
            defer { writers.removeAll() }
            let end = max(duration, Double(writers.values.map { $0.frames }.max() ?? 0) / 16_000)
            for writer in writers.values {
                do { try writer.finish(at: end) } catch { writeError = error }
            }
        }
        let group = DispatchGroup()
        for live in Array(speech.values) + drainingSpeech { group.enter(); live.finish { group.leave() } }
        speech.removeAll()
        group.notify(queue: .main) { completion(writeError) }
    }

    private func failWrite(_ error: Error, token: Int) {
        guard active, token == generation else { return }
        stop { [weak self] _ in self?.emit(["error": "写入录音失败：\(error.localizedDescription)", "stopped": true]) }
    }
    private func emit(_ value: [String: Any]) { sink?(value) }
}

/// Separate on-device recognition requests for the two sources. Rollover keeps
/// Apple's bounded request lifetime out of a long recording's capture lifecycle.
private final class DualLiveSpeech {
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
    private var current: DualSpeechRequest?
    private var finishing: [DualSpeechRequest] = []
    private let update: (String, Double, Bool) -> Void
    init(update: @escaping (String, Double, Bool) -> Void) { self.update = update }
    func start(at time: Double) -> Bool {
        if let current {
            finishing.append(current)
            current.finish { [self, weak current] in finishing.removeAll { $0 === current } }
        }
        current = nil
        guard let recognizer, recognizer.supportsOnDeviceRecognition, recognizer.isAvailable else { return false }
        current = DualSpeechRequest(recognizer: recognizer, offset: time, update: update)
        return true
    }
    func append(_ samples: [Float], at time: Double) {
        if current == nil || current!.ended || time - current!.offset > 50 {
            guard start(at: time) else { return }
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: CaptureFormat.mono, frameCapacity: AVAudioFrameCount(samples.count)), let data = buffer.floatChannelData else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { if let base = $0.baseAddress { data[0].update(from: base, count: samples.count) } }
        current?.request.append(buffer)
    }
    func finish(_ completion: @escaping () -> Void) {
        if let current { finishing.append(current) }
        current = nil
        let pending = finishing
        let group = DispatchGroup()
        for request in pending { group.enter(); request.finish { group.leave() } }
        group.notify(queue: .main) { [self] in
            finishing.removeAll { $0.ended }
            completion()
        }
    }
}

private final class DualSpeechRequest {
    let request = SFSpeechAudioBufferRecognitionRequest()
    let offset: Double
    private var task: SFSpeechRecognitionTask?
    private var completions: [() -> Void] = []
    private var closing = false
    private(set) var ended = false
    init(recognizer: SFSpeechRecognizer, offset: Double, update: @escaping (String, Double, Bool) -> Void) {
        self.offset = offset
        request.requiresOnDeviceRecognition = true; request.shouldReportPartialResults = true
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self, !self.ended else { return }
                if let result { update(result.bestTranscription.formattedString, offset, result.isFinal) }
                if error != nil || result?.isFinal == true { self.complete() }
            }
        }
    }
    func finish(_ completion: @escaping () -> Void) {
        if ended { completion(); return }
        completions.append(completion)
        guard !closing else { return }
        closing = true; request.endAudio()
        // Keep the request alive through its final result, but never hang Save
        // on a recognizer that has stopped responding.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [self] in complete() }
    }
    private func complete() {
        guard !ended else { return }
        ended = true; task?.cancel(); task = nil
        let pending = completions; completions = []; pending.forEach { $0() }
    }
}
