import AVFoundation
import Combine
#if os(macOS)
import CoreAudio
#endif
import Foundation
import Speech
import SwiftUI

@MainActor
public final class BeanSidebarModel: ObservableObject {
  @Published public private(set) var connectionPhase: KoeConnectionPhase = .disconnected(reason: nil)
  @Published public private(set) var catalog: [KoeOfflineFileItem] = []
  @Published public private(set) var activeTransfer: KoeActiveTransfer = .idle
  @Published public private(set) var wifiEndpoint: KoeWifiEndpointModel?
  @Published public private(set) var wifiBatchProgress: KoeWifiBatchProgressModel?

  private let transport: any BeanTransporting
  private let exportDirectory: URL
  private let onRecordingSaved: (KoeSavedRecording) -> Void
  private let onLiveCaption: (KoeLiveCaptionSegment) -> Void

  public init(
    transport: any BeanTransporting,
    exportDirectory: URL = BeanTransportActor.defaultExportDirectory(),
    onRecordingSaved: @escaping (KoeSavedRecording) -> Void = { _ in },
    onLiveCaption: @escaping (KoeLiveCaptionSegment) -> Void = { _ in }
  ) {
    self.transport = transport
    self.exportDirectory = exportDirectory
    self.onRecordingSaved = onRecordingSaved
    self.onLiveCaption = onLiveCaption
  }

  public func observeEvents() async {
    for await event in transport.events() {
      handle(event)
    }
  }

  public func handle(_ event: BeanEvent) {
    switch event {
    case .connectionChanged(let phase):
      connectionPhase = phase
    case .catalogUpdated(let items):
      catalog = items
    case .transferChanged(let transfer):
      activeTransfer = transfer
    case .wifiEndpointUpdated(let ep):
      wifiEndpoint = ep
    case .wifiBatchProgressChanged(let progress):
      wifiBatchProgress = progress.phase == 0 ? nil : progress
    case .liveSliceUnpacked:
      break
    case .liveCaptionProduced(let seg):
      onLiveCaption(seg)
    case .recordingSaved(let rec):
      onRecordingSaved(rec)
    }
  }

  public func connectBean() {
    Task { await transport.startScanAndConnect() }
  }

  public func disconnectBean() {
    Task { await transport.disconnect() }
  }

  public func refreshCatalog() {
    Task { await transport.requestCatalog() }
  }

  public func pullFile(_ item: KoeOfflineFileItem) {
    Task { await transport.pullOfflineFile(item, destinationDirectory: exportDirectory) }
  }

  public func startWifiBatch(fileIds: [UInt32]? = nil) {
    let ids = fileIds ?? catalog.map(\.fileId)
    Task {
      _ = await transport.beginWifiBatch(fileIds: ids)
      let prog = await transport.currentWifiBatchProgress()
      wifiBatchProgress = prog.phase == 0 ? nil : prog
    }
  }

  public func ingestWifiChunk(_ chunk: Data) {
    Task {
      let saved = await transport.ingestWifiChunk(chunk, destinationDirectory: exportDirectory)
      for rec in saved {
        onRecordingSaved(rec)
      }
      let prog = await transport.currentWifiBatchProgress()
      wifiBatchProgress = prog.phase == 0 ? nil : prog
    }
  }

  public func onWifiInterrupted() {
    Task {
      let saved = await transport.onWifiInterrupted(destinationDirectory: exportDirectory)
      for rec in saved {
        onRecordingSaved(rec)
      }
      let prog = await transport.currentWifiBatchProgress()
      wifiBatchProgress = prog.phase == 0 ? nil : prog
    }
  }

  public func resumeWifiBatch() {
    Task {
      _ = await transport.resumeWifiBatch()
      let prog = await transport.currentWifiBatchProgress()
      wifiBatchProgress = prog.phase == 0 ? nil : prog
    }
  }

  public func cancelWifiBatch() {
    Task {
      await transport.cancelWifiBatch()
      wifiBatchProgress = nil
    }
  }

  public func runSimulatedRealtimeSession() {
    Task {
      _ = await transport.simulateBeanRealtimePipeline(destinationDirectory: exportDirectory)
    }
  }
}

public struct KoeAudioDeviceItem: Equatable, Sendable, Identifiable {
  public var id: String { uid }
  public let uid: String
  public let name: String
  public let isPhysicalInput: Bool
  public let isBlackHole2ch: Bool

  public init(uid: String, name: String, isPhysicalInput: Bool, isBlackHole2ch: Bool) {
    self.uid = uid
    self.name = name
    self.isPhysicalInput = isPhysicalInput
    self.isBlackHole2ch = isBlackHole2ch
  }
}

public final class KoeInputDeviceLease: @unchecked Sendable {
  public let fileURL: URL

  public init(directory: URL = BeanTransportActor.defaultExportDirectory()) {
    self.fileURL = directory.appendingPathComponent("interpreting-input.json")
  }

  @discardableResult
  public func acquire(
    session: String,
    target: String,
    currentDefaultInput: () -> String? = KoeInputDeviceLease.systemDefaultInputUID,
    setDefaultInput: (String) -> Bool = KoeInputDeviceLease.setSystemDefaultInputUID
  ) -> Bool {
    guard let current = currentDefaultInput(), !current.isEmpty else {
      return false
    }
    var original = current
    if let existingData = try? Data(contentsOf: fileURL),
       let existing = (try? JSONSerialization.jsonObject(with: existingData)) as? [String: String],
       let prevOriginal = existing["original"],
       !prevOriginal.isEmpty
    {
      original = prevOriginal
    }
    let payload: [String: String] = [
      "session": session,
      "original": original,
      "target": target,
    ]
    guard let encoded = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else {
      return false
    }
    do {
      try FileManager.default.createDirectory(
        at: fileURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try encoded.write(to: fileURL, options: .atomic)
    } catch {
      return false
    }
    if current == target {
      return true
    }
    if setDefaultInput(target) {
      return true
    }
    try? FileManager.default.removeItem(at: fileURL)
    return false
  }

  @discardableResult
  public func release(
    currentDefaultInput: () -> String? = KoeInputDeviceLease.systemDefaultInputUID,
    setDefaultInput: (String) -> Bool = KoeInputDeviceLease.setSystemDefaultInputUID
  ) -> String {
    guard let data = try? Data(contentsOf: fileURL),
          let lease = (try? JSONSerialization.jsonObject(with: data)) as? [String: String],
          let original = lease["original"],
          let target = lease["target"]
    else {
      return "kept"
    }
    let current = currentDefaultInput()
    if current != nil && current != target && current != original {
      try? FileManager.default.removeItem(at: fileURL)
      return "kept"
    }
    if current == original || setDefaultInput(original) {
      try? FileManager.default.removeItem(at: fileURL)
      return "restored"
    }
    return "failed"
  }

  public func relinquish() {
    try? FileManager.default.removeItem(at: fileURL)
  }

  public static func systemDefaultInputUID() -> String? {
    #if os(macOS)
    return KoeCoreAudioRoute.currentDefaultInputUID()
    #else
    return nil
    #endif
  }

  public static func setSystemDefaultInputUID(_ uid: String) -> Bool {
    #if os(macOS)
    return KoeCoreAudioRoute.setDefaultInputUID(uid)
    #else
    return false
    #endif
  }
}

#if os(macOS)
public enum KoeCoreAudioRoute {
  public static let blackHoleUID = "BlackHole2ch_UID"

  public static func physicalInputs() -> [KoeAudioDeviceItem] {
    allDeviceIDs().compactMap { id in
      guard let uid = deviceUID(id),
            let name = deviceName(id),
            channelCount(id, scope: kAudioDevicePropertyScopeInput) > 0,
            isPhysicalTransport(id),
            !name.localizedCaseInsensitiveContains("BlackHole"),
            uid != blackHoleUID
      else {
        return nil
      }
      return KoeAudioDeviceItem(
        uid: uid,
        name: name,
        isPhysicalInput: true,
        isBlackHole2ch: false
      )
    }
  }

  public static func blackHoleOutputs() -> [KoeAudioDeviceItem] {
    allDeviceIDs().compactMap { id in
      guard let uid = deviceUID(id),
            let name = deviceName(id),
            uid == blackHoleUID,
            channelCount(id, scope: kAudioDevicePropertyScopeOutput) == 2
      else {
        return nil
      }
      return KoeAudioDeviceItem(
        uid: uid,
        name: name,
        isPhysicalInput: false,
        isBlackHole2ch: true
      )
    }
  }

  public static func isPhysicalInput(_ uid: String) -> Bool {
    physicalInputs().contains { $0.uid == uid }
  }

  public static func isBlackHole2ch(_ uid: String) -> Bool {
    blackHoleOutputs().contains { $0.uid == uid }
  }

  public static func currentDefaultInputUID() -> String? {
    var addr = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDefaultInputDevice,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var deviceID = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(
      AudioObjectID(kAudioObjectSystemObject),
      &addr,
      0,
      nil,
      &size,
      &deviceID
    ) == noErr, deviceID != 0 else {
      return nil
    }
    return deviceUID(deviceID)
  }

  @discardableResult
  public static func setDefaultInputUID(_ uid: String) -> Bool {
    guard let targetID = allDeviceIDs().first(where: { deviceUID($0) == uid }) else {
      return false
    }
    var deviceID = targetID
    var addr = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDefaultInputDevice,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    let size = UInt32(MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectSetPropertyData(
      AudioObjectID(kAudioObjectSystemObject),
      &addr,
      0,
      nil,
      size,
      &deviceID
    ) == noErr else {
      return false
    }
    return currentDefaultInputUID() == uid
  }

  private static func allDeviceIDs() -> [AudioDeviceID] {
    var addr = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDevices,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(
      AudioObjectID(kAudioObjectSystemObject),
      &addr,
      0,
      nil,
      &size
    ) == noErr, size > 0 else {
      return []
    }
    let count = Int(size) / MemoryLayout<AudioDeviceID>.size
    var ids = [AudioDeviceID](repeating: 0, count: count)
    guard AudioObjectGetPropertyData(
      AudioObjectID(kAudioObjectSystemObject),
      &addr,
      0,
      nil,
      &size,
      &ids
    ) == noErr else {
      return []
    }
    return ids
  }

  private static func deviceUID(_ id: AudioDeviceID) -> String? {
    stringProperty(id, selector: kAudioDevicePropertyDeviceUID)
  }

  private static func deviceName(_ id: AudioDeviceID) -> String? {
    stringProperty(id, selector: kAudioObjectPropertyName)
  }

  private static func stringProperty(
    _ id: AudioDeviceID,
    selector: AudioObjectPropertySelector
  ) -> String? {
    var addr = AudioObjectPropertyAddress(
      mSelector: selector,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr,
          let unwrapped = value?.takeUnretainedValue()
    else {
      return nil
    }
    return unwrapped as String
  }

  private static func isPhysicalTransport(_ id: AudioDeviceID) -> Bool {
    var addr = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyTransportType,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var transport: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &transport) == noErr else {
      return true
    }
    return transport != kAudioDeviceTransportTypeVirtual
      && transport != kAudioDeviceTransportTypeAggregate
  }

  private static func channelCount(_ id: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int {
    var addr = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyStreamConfiguration,
      mScope: scope,
      mElement: kAudioObjectPropertyElementMain
    )
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr,
          size >= UInt32(MemoryLayout<AudioBufferList>.size)
    else {
      return 0
    }
    let raw = UnsafeMutableRawPointer.allocate(
      byteCount: Int(size),
      alignment: MemoryLayout<AudioBufferList>.alignment
    )
    defer { raw.deallocate() }
    guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else {
      return 0
    }
    let listPtr = raw.assumingMemoryBound(to: AudioBufferList.self)
    return UnsafeMutableAudioBufferListPointer(listPtr).reduce(0) { $0 + Int($1.mNumberChannels) }
  }
}
#endif

@MainActor
public final class LiveInterpretingModel: ObservableObject {
  @Published public private(set) var segments: [KoeLiveCaptionSegment] = []
  @Published public private(set) var isListeningMicrophone = false
  @Published public var ttsEnabled = true
  @Published public private(set) var ttsState: KoeTTSState = .idle
  @Published public var sourceLanguage = "zh-CN"
  @Published public var targetLanguage = "en-US"
  @Published public private(set) var statusBanner = "等待录音豆实时流或麦克风输入"
  @Published public private(set) var physicalInputs: [KoeAudioDeviceItem] = []
  @Published public private(set) var blackHoleOutputs: [KoeAudioDeviceItem] = []
  @Published public var selectedInputUID: String = ""
  @Published public var selectedOutputUID: String = "BlackHole2ch_UID"
  @Published public private(set) var isHoldingToInterpret: Bool = false
  @Published public private(set) var silenceElapsedMs: UInt64 = 0
  @Published public private(set) var rollingMinutesJson: String?

  public let rollingScheduler = KoeCicadaRollingScheduler(sessionId: "live-interpreting")
  public let inputLease: KoeInputDeviceLease

  private let synthesizer = AVSpeechSynthesizer()
  private var audioEngine: AVAudioEngine?
  private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
  private var recognitionTask: SFSpeechRecognitionTask?
  private var holdToken: String?
  private var holdTimeoutTask: Task<Void, Never>?
  private var autoStoppedBySilence: Bool = false

  public init(leaseDirectory: URL = BeanTransportActor.defaultExportDirectory()) {
    self.inputLease = KoeInputDeviceLease(directory: leaseDirectory)
    refreshAudioDevices()
  }

  public func refreshAudioDevices() {
    #if os(macOS)
    physicalInputs = KoeCoreAudioRoute.physicalInputs()
    blackHoleOutputs = KoeCoreAudioRoute.blackHoleOutputs()
    if selectedInputUID.isEmpty, let first = physicalInputs.first {
      selectedInputUID = first.uid
    }
    #else
    physicalInputs = []
    blackHoleOutputs = []
    #endif
  }

  public func beginHoldToInterpret(session: String = "live", token: String = "hold") {
    holdTimeoutTask?.cancel()
    holdToken = token
    isHoldingToInterpret = true
    silenceElapsedMs = 0
    autoStoppedBySilence = false
    #if os(macOS)
    if !selectedInputUID.isEmpty {
      _ = inputLease.acquire(session: session, target: selectedInputUID)
    }
    if KoeCoreAudioRoute.isBlackHole2ch(selectedOutputUID) || !blackHoleOutputs.isEmpty {
      statusBanner = "正在按住同传 (\(sourceLanguage) → \(targetLanguage) · BlackHole 2ch)"
    } else {
      statusBanner = "正在按住同传 (\(sourceLanguage) → \(targetLanguage))"
    }
    #else
    statusBanner = "正在按住同传 (\(sourceLanguage) → \(targetLanguage))"
    #endif
    holdTimeoutTask = Task { @MainActor [weak self] in
      try? await Task.sleep(nanoseconds: 30_000_000_000)
      guard let self, !Task.isCancelled else { return }
      if self.isHoldingToInterpret && self.holdToken == token {
        _ = self.finishHoldToInterpret(token: token)
      }
    }
  }

  @discardableResult
  public func finishHoldToInterpret(token: String = "hold") -> String {
    guard isHoldingToInterpret else { return "noop" }
    if let active = holdToken, active != token {
      return "noop"
    }
    holdTimeoutTask?.cancel()
    holdTimeoutTask = nil
    isHoldingToInterpret = false
    holdToken = nil
    if isListeningMicrophone {
      stopMicrophoneCapture()
    }
    let releaseResult = inputLease.release()
    statusBanner = "已结束按住同传 (\(releaseResult))"
    return releaseResult
  }

  @discardableResult
  public func recordAudioActivity(elapsedMs: UInt64, speechDetected: Bool) -> Bool {
    let res = KoeCore.reduceSilenceAutoStop(
      silenceElapsedMs: silenceElapsedMs,
      deltaMs: elapsedMs,
      speechDetected: speechDetected,
      alreadyAutoStopped: autoStoppedBySilence
    )
    silenceElapsedMs = res.nextElapsedMs
    autoStoppedBySilence = res.autoStopped
    if res.triggered {
      if isListeningMicrophone {
        stopMicrophoneCapture()
      }
      if isHoldingToInterpret {
        _ = finishHoldToInterpret(token: holdToken ?? "hold")
      }
      statusBanner = "静音满 30 秒，已自动停止同传拾音"
      return true
    }
    return false
  }

  public func ingestSegment(_ segment: KoeLiveCaptionSegment) {
    if let idx = segments.firstIndex(where: { $0.id == segment.id }) {
      segments[idx] = segment
    } else {
      segments.append(segment)
    }
    if segment.isFinal && !segment.sourceText.isEmpty {
      _ = rollingScheduler.addSegment(
        id: segment.id.uuidString,
        text: segment.sourceText,
        nowMs: segment.endMs
      )
      rollingMinutesJson = rollingScheduler.activeJson()
    }
    statusBanner = "已接收 \(segments.count) 条双语同传字幕"
    if ttsEnabled && segment.isFinal {
      let textToSpeak = segment.translatedText.isEmpty ? segment.sourceText : segment.translatedText
      speak(segmentId: segment.id, text: textToSpeak, language: targetLanguage)
    }
  }

  public func speak(segmentId: UUID, text: String, language: String) {
    guard !text.isEmpty else { return }
    synthesizer.stopSpeaking(at: .immediate)
    ttsState = .speaking(segmentId: segmentId, text: text)
    let utterance = AVSpeechUtterance(string: text)
    utterance.voice = AVSpeechSynthesisVoice(language: language)
    synthesizer.speak(utterance)
  }

  public func stopSpeaking() {
    synthesizer.stopSpeaking(at: .immediate)
    ttsState = .idle
  }

  public func clearSegments() {
    segments.removeAll()
    statusBanner = "已清空同传字幕"
  }

  public func toggleMicrophoneLiveRecognition() {
    if isListeningMicrophone {
      stopMicrophoneCapture()
    } else {
      startMicrophoneCapture()
    }
  }

  private func startMicrophoneCapture() {
    SFSpeechRecognizer.requestAuthorization { [weak self] status in
      Task { @MainActor in
        guard let self else { return }
        guard status == .authorized else {
          self.statusBanner = "请先在系统设置中授予语音识别权限"
          return
        }
        do {
          try self.beginRecognizerEngine()
        } catch {
          self.statusBanner = "麦克风启动失败"
        }
      }
    }
  }

  private func beginRecognizerEngine() throws {
    stopMicrophoneCapture()
    let locale = Locale(identifier: sourceLanguage)
    guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
      statusBanner = "当前源语种识别器不可用"
      return
    }
    let engine = AVAudioEngine()
    let request = SFSpeechAudioBufferRecognitionRequest()
    request.shouldReportPartialResults = true
    let inputNode = engine.inputNode
    let format = inputNode.outputFormat(forBus: 0)
    guard format.channelCount > 0 else {
      statusBanner = "未检测到可用麦克风输入通道"
      return
    }
    let liveSegmentId = UUID()
    inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
      request.append(buffer)
    }
    engine.prepare()
    try engine.start()
    audioEngine = engine
    recognitionRequest = request
    isListeningMicrophone = true
    statusBanner = "正在通过麦克风实时识别 (\(sourceLanguage))"
    recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
      Task { @MainActor in
        guard let self else { return }
        if let result {
          let text = result.bestTranscription.formattedString
          let seg = KoeLiveCaptionSegment(
            id: liveSegmentId,
            startMs: 0,
            endMs: 1000,
            sourceText: text,
            translatedText: result.isFinal ? "[同传译文] \(text)" : "",
            isFinal: result.isFinal,
            hasDoubleTapMark: false
          )
          self.ingestSegment(seg)
        }
        if error != nil || (result?.isFinal == true) {
          self.stopMicrophoneCapture()
        }
      }
    }
  }

  private func stopMicrophoneCapture() {
    audioEngine?.stop()
    audioEngine?.inputNode.removeTap(onBus: 0)
    recognitionRequest?.endAudio()
    recognitionTask?.cancel()
    audioEngine = nil
    recognitionRequest = nil
    recognitionTask = nil
    isListeningMicrophone = false
  }
}

public enum MarkJumpDirection: Sendable {
  case previous
  case next
}

@MainActor
public final class RecordingPlaybackModel: ObservableObject {
  @Published public private(set) var recordings: [KoeSavedRecording] = []
  @Published public var selectedRecordingId: RecordingID?
  @Published public private(set) var playbackState: KoePlaybackState = .stopped
  @Published public var playbackRate: Float = 1.0
  @Published public private(set) var recentlyTrashed: KoeSavedRecording?

  private let rustLibrary = KoeRecordingLibrary()
  private var audioPlayer: AVAudioPlayer?
  private var progressTimer: Timer?

  public var selectedRecording: KoeSavedRecording? {
    if let id = selectedRecordingId {
      return recordings.first { $0.id == id }
    }
    return recordings.first
  }

  public init(initialRecordings: [KoeSavedRecording] = []) {
    for rec in initialRecordings.reversed() {
      ingestIntoRustLibrary(rec)
    }
    self.recordings = initialRecordings
    self.selectedRecordingId = initialRecordings.first?.id
  }

  public func loadExistingExports(from directory: URL = BeanTransportActor.defaultExportDirectory()) {
    guard let items = try? FileManager.default.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: [.creationDateKey, .fileSizeKey],
      options: [.skipsHiddenFiles]
    ) else { return }
    let opusFiles = items.filter { $0.pathExtension.lowercased() == "opus" }
    for url in opusFiles {
      let stem = url.deletingPathExtension().lastPathComponent
      let recId = RecordingID(rawValue: stem)
      guard !recordings.contains(where: { $0.id == recId }) else { continue }
      let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
      let size = (attrs?[.size] as? Int) ?? 0
      let created = (attrs?[.creationDate] as? Date) ?? Date()
      guard let entry = rustLibrary.ingestDiskFile(
        filename: url.lastPathComponent,
        byteCount: UInt32(max(0, size)),
        createdAtEpochSec: UInt64(max(0, created.timeIntervalSince1970))
      ) else { continue }
      let wavCandidate = directory.appendingPathComponent("\(stem).wav")
      let wavURL = FileManager.default.fileExists(atPath: wavCandidate.path) ? wavCandidate : nil
      let rec = KoeSavedRecording(
        id: recId,
        beanFileId: BeanFileID(rawValue: entry.beanFileId),
        title: "录音豆 #\(stem)",
        createdAt: created,
        durationMs: entry.durationMs,
        byteCount: size,
        opusFileURL: url,
        playableWAVURL: wavURL,
        marks: entry.marksMs.map { MarkTimestampMs(sequence: UInt32($0 / 20), rawValue: $0) },
        transcriptSegments: []
      )
      recordings.append(rec)
    }
    recordings.sort { $0.createdAt > $1.createdAt }
    if selectedRecordingId == nil {
      selectedRecordingId = recordings.first?.id
    }
  }

  public func ingestRecording(_ recording: KoeSavedRecording) {
    ingestIntoRustLibrary(recording)
    recordings.removeAll { $0.id == recording.id }
    recordings.insert(recording, at: 0)
    selectedRecordingId = recording.id
  }

  public func selectRecording(_ id: RecordingID) {
    stopPlayback()
    _ = rustLibrary.select(numericRecordingId(id))
    selectedRecordingId = id
  }

  public func togglePlayPause() {
    guard let rec = selectedRecording else { return }
    if playbackState.isPlaying {
      audioPlayer?.pause()
      progressTimer?.invalidate()
      playbackState = .paused(
        recordingId: rec.id,
        positionMs: playbackState.positionMs,
        durationMs: rec.durationMs
      )
      return
    }
    let startMs = playbackState.positionMs >= rec.durationMs ? 0 : playbackState.positionMs
    if let wavURL = rec.playableWAVURL,
       let player = try? AVAudioPlayer(contentsOf: wavURL)
    {
      player.enableRate = true
      player.rate = playbackRate
      player.currentTime = TimeInterval(startMs) / 1000.0
      player.play()
      audioPlayer = player
    }
    playbackState = .playing(recordingId: rec.id, positionMs: startMs, durationMs: rec.durationMs)
    progressTimer?.invalidate()
    progressTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
      Task { @MainActor in
        self?.tickPlayback()
      }
    }
  }

  private func tickPlayback() {
    guard selectedRecording != nil, case .playing(let id, let pos, let dur) = playbackState else {
      return
    }
    let nextMs: UInt64
    if let player = audioPlayer, player.isPlaying {
      nextMs = UInt64(max(0, player.currentTime * 1000.0))
    } else {
      nextMs = pos + UInt64(50.0 * Double(playbackRate))
    }
    if nextMs >= dur {
      stopPlayback()
    } else {
      playbackState = .playing(recordingId: id, positionMs: nextMs, durationMs: dur)
    }
  }

  public func stopPlayback() {
    progressTimer?.invalidate()
    progressTimer = nil
    audioPlayer?.stop()
    audioPlayer = nil
    playbackState = .stopped
  }

  public func seek(toMs targetMs: UInt64) {
    guard let rec = selectedRecording else { return }
    let clamped = rustLibrary.seekMs(targetMs)
    audioPlayer?.currentTime = TimeInterval(clamped) / 1000.0
    if playbackState.isPlaying {
      playbackState = .playing(recordingId: rec.id, positionMs: clamped, durationMs: rec.durationMs)
    } else {
      playbackState = .paused(recordingId: rec.id, positionMs: clamped, durationMs: rec.durationMs)
    }
  }

  public func jumpToMark(_ mark: MarkTimestampMs) {
    seek(toMs: mark.rawValue)
  }

  public func jumpToMark(direction: MarkJumpDirection) {
    let dirCode = direction == .next ? 1 : -1
    guard let target = rustLibrary.jumpToMark(currentMs: playbackState.positionMs, direction: dirCode) else {
      return
    }
    seek(toMs: target)
  }

  public func moveToTrash(_ id: RecordingID) {
    guard rustLibrary.moveToTrash(numericRecordingId(id)) != nil,
          let idx = recordings.firstIndex(where: { $0.id == id })
    else { return }
    let removed = recordings.remove(at: idx)
    recentlyTrashed = removed
    if selectedRecordingId == id {
      selectedRecordingId = recordings.first?.id
    }
  }

  public func undoTrash() {
    guard rustLibrary.undoTrash() != nil, let restored = recentlyTrashed else { return }
    recentlyTrashed = nil
    recordings.removeAll { $0.id == restored.id }
    recordings.insert(restored, at: 0)
    selectedRecordingId = restored.id
  }

  private func ingestIntoRustLibrary(_ recording: KoeSavedRecording) {
    let numId = numericRecordingId(recording.id)
    let entry = KoeRecordingEntryModel(
      id: numId,
      beanFileId: recording.beanFileId?.rawValue ?? numId,
      createdAtEpochSec: UInt64(max(0, recording.createdAt.timeIntervalSince1970)),
      durationMs: recording.durationMs,
      byteCount: UInt32(max(0, recording.byteCount)),
      marksMs: recording.marks.map(\.rawValue)
    )
    rustLibrary.ingest(entry)
  }

  private func numericRecordingId(_ id: RecordingID) -> UInt32 {
    if let parsed = UInt32(id.rawValue) {
      return parsed
    }
    var h: UInt32 = 2_166_136_261
    for b in id.rawValue.utf8 {
      h ^= UInt32(b)
      h = h &* 16_777_619
    }
    return max(1, h)
  }
}

@MainActor
public final class KoeNativeHost: ObservableObject {
  public let transport: any BeanTransporting
  public let sidebar: BeanSidebarModel
  public let interpreting: LiveInterpretingModel
  public let playback: RecordingPlaybackModel
  private var eventObservationTask: Task<Void, Never>?

  public init(
    transport: any BeanTransporting = BeanTransportActor(),
    exportDirectory: URL = BeanTransportActor.defaultExportDirectory()
  ) {
    self.transport = transport
    let interpretingModel = LiveInterpretingModel()
    let playbackModel = RecordingPlaybackModel()
    self.interpreting = interpretingModel
    self.playback = playbackModel
    let sidebarModel = BeanSidebarModel(
      transport: transport,
      exportDirectory: exportDirectory,
      onRecordingSaved: { [weak playbackModel] saved in
        playbackModel?.ingestRecording(saved)
      },
      onLiveCaption: { [weak interpretingModel] segment in
        interpretingModel?.ingestSegment(segment)
      }
    )
    self.sidebar = sidebarModel
    playbackModel.loadExistingExports(from: exportDirectory)
    self.eventObservationTask = Task { [weak sidebarModel] in
      await sidebarModel?.observeEvents()
    }
  }

  deinit {
    eventObservationTask?.cancel()
  }
}

private enum KoeNativePalette {
  static let bambooGreen = Color(red: 0.18, green: 0.37, blue: 0.31)
  static let warmSurface = Color(red: 0.96, green: 0.957, blue: 0.941)
  static let cardBorder = Color.primary.opacity(0.08)
}

public struct KoeNativeHostView: View {
  @ObservedObject public var host: KoeNativeHost
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass

  public init(host: KoeNativeHost) {
    self.host = host
  }

  public var body: some View {
    #if os(iOS)
    if horizontalSizeClass == .compact {
      TabView {
        NavigationStack {
          BeanConnectionSidebarView(
            sidebar: host.sidebar,
            playback: host.playback
          )
          .navigationTitle("设备")
        }
        .tabItem {
          Label("设备", systemImage: "wave.3.right.circle")
        }

        NavigationStack {
          LiveInterpretingPanelView(
            interpreting: host.interpreting,
            sidebar: host.sidebar
          )
          .navigationTitle("同传")
        }
        .tabItem {
          Label("同传", systemImage: "captions.bubble")
        }

        NavigationStack {
          RecordingPlaybackDetailView(
            playback: host.playback,
            interpreting: host.interpreting
          )
          .navigationTitle("录音库")
        }
        .tabItem {
          Label("录音库", systemImage: "waveform")
        }
      }
      .tint(KoeNativePalette.bambooGreen)
    } else {
      splitViewLayout
    }
    #else
    splitViewLayout
    #endif
  }

  private var splitViewLayout: some View {
    NavigationSplitView {
      BeanConnectionSidebarView(
        sidebar: host.sidebar,
        playback: host.playback
      )
      .navigationSplitViewColumnWidth(min: 250, ideal: 280, max: 340)
    } content: {
      LiveInterpretingPanelView(
        interpreting: host.interpreting,
        sidebar: host.sidebar
      )
      .navigationSplitViewColumnWidth(min: 340, ideal: 420)
    } detail: {
      RecordingPlaybackDetailView(
        playback: host.playback,
        interpreting: host.interpreting
      )
    }
  }
}

public struct BeanConnectionSidebarView: View {
  @ObservedObject public var sidebar: BeanSidebarModel
  @ObservedObject public var playback: RecordingPlaybackModel

  public init(sidebar: BeanSidebarModel, playback: RecordingPlaybackModel) {
    self.sidebar = sidebar
    self.playback = playback
  }

  public var body: some View {
    List {
      Section("录音豆连接与状态") {
        connectionCard
        if case .connected(let tel) = sidebar.connectionPhase {
          telemetryView(tel)
        }
        if let progress = sidebar.wifiBatchProgress, progress.phase != 0 {
          wifiBatchCard(progress)
        }
        Button {
          sidebar.runSimulatedRealtimeSession()
        } label: {
          Label("运行 1A07/1A08 实时流闭环演示", systemImage: "bolt.horizontal.circle.fill")
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(KoeNativePalette.bambooGreen)
        }
      }

      Section("设备端离线文件 (\(sidebar.catalog.count))") {
        if sidebar.catalog.isEmpty {
          Text("连接录音豆后显示待同步录音")
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
        } else {
          Button {
            sidebar.startWifiBatch()
          } label: {
            Label("Wi-Fi 快传全部", systemImage: "wifi.circle.fill")
              .font(.system(size: 14, weight: .semibold))
              .foregroundStyle(KoeNativePalette.bambooGreen)
          }
          ForEach(sidebar.catalog, id: \.fileId) { item in
            HStack {
              VStack(alignment: .leading, spacing: 2) {
                Text("设备文件 #\(item.fileId)")
                  .font(.system(size: 14, weight: .medium).monospacedDigit())
                Text("\(item.durationMs / 1000) 秒")
                  .font(.system(size: 12).monospacedDigit())
                  .foregroundStyle(.secondary)
              }
              Spacer()
              Button("同步") {
                sidebar.pullFile(item)
              }
              .font(.system(size: 12, weight: .semibold))
            }
          }
        }
      }

      Section("本机录音库 (\(playback.recordings.count))") {
        if let trashed = playback.recentlyTrashed {
          HStack {
            Text("已移入回收站 \(trashed.title)")
              .font(.system(size: 12))
            Spacer()
            Button("撤销") {
              playback.undoTrash()
            }
            .font(.system(size: 12, weight: .semibold))
          }
        }
        ForEach(playback.recordings) { rec in
          Button {
            playback.selectRecording(rec.id)
          } label: {
            HStack {
              VStack(alignment: .leading, spacing: 4) {
                Text(rec.title)
                  .font(.system(size: 14, weight: .semibold))
                HStack(spacing: 8) {
                  Text(rec.formattedDuration)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                  if !rec.marks.isEmpty {
                    Label("\(rec.marks.count) 标记", systemImage: "bookmark.fill")
                      .font(.system(size: 12))
                      .foregroundStyle(.orange)
                  }
                }
              }
              Spacer()
              if playback.selectedRecordingId == rec.id {
                Image(systemName: "checkmark.circle.fill")
                  .foregroundStyle(KoeNativePalette.bambooGreen)
              }
            }
          }
          .buttonStyle(.plain)
        }
      }
    }
    .listStyle(.sidebar)
  }

  private var connectionCard: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        switch sidebar.connectionPhase {
        case .disconnected(let reason):
          Label(reason ?? "未连接录音豆", systemImage: "antenna.radiowaves.left.and.right.slash")
            .font(.system(size: 14, weight: .medium))
          Spacer()
          Button("扫描连接") {
            sidebar.connectBean()
          }
          .font(.system(size: 12, weight: .semibold))
        case .scanning:
          ProgressView().controlSize(.small)
          Text("正在扫描 D3200...")
            .font(.system(size: 14))
          Spacer()
          Button("停止") {
            sidebar.disconnectBean()
          }
          .font(.system(size: 12))
        case .connecting(let name):
          ProgressView().controlSize(.small)
          Text("正在连接 \(name)...")
            .font(.system(size: 14))
        case .handshaking:
          ProgressView().controlSize(.small)
          Text("ECDH 密钥握手中...")
            .font(.system(size: 14))
        case .connected(let tel):
          Label("soundcore Work (\(tel.serialNumber.suffix(4).uppercased()))", systemImage: "wave.3.right.circle.fill")
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(KoeNativePalette.bambooGreen)
          Spacer()
          Button("断开") {
            sidebar.disconnectBean()
          }
          .font(.system(size: 12))
        }
      }
      transferStatusRow
    }
  }

  @ViewBuilder
  private var transferStatusRow: some View {
    switch sidebar.activeTransfer {
    case .idle:
      EmptyView()
    case .queryingCatalog:
      Text("正在读取录音豆目录...")
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
    case .pullingOffline(let fid, let received, let total, let marks):
      VStack(alignment: .leading, spacing: 4) {
        ProgressView(value: sidebar.activeTransfer.progressFraction)
        Text("同步 #\(fid.rawValue) (\(received / 1024) KB / \(max(1, total / 1024)) KB, 标记 \(marks))")
          .font(.system(size: 12))
          .foregroundStyle(.secondary)
      }
    case .streamingRealtime(let fid, let received, let marks):
      Text("实时接收 #\(fid.rawValue) (\(received) B, 双击标记 \(marks))")
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(KoeNativePalette.bambooGreen)
    case .failed(let reason):
      Text(reason)
        .font(.system(size: 12))
        .foregroundStyle(.red)
    }
  }

  private func telemetryView(_ tel: KoeDeviceTelemetry) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("麦克风电量 \(tel.battery ?? 0)% | 充电盒 \(tel.boxBattery ?? 0)%")
        .font(.system(size: 12).monospacedDigit())
        .foregroundStyle(.secondary)
      Text("固件 \(tel.firmwareVersion) | 剩余空间 \((tel.freeMemoryKb ?? 0) / 1024) MB")
        .font(.system(size: 12).monospacedDigit())
        .foregroundStyle(.secondary)
    }
  }

  private func wifiBatchCard(_ progress: KoeWifiBatchProgressModel) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Text("Wi-Fi 快传 \(progress.finalizedCount + progress.salvagedCount)/\(progress.totalFiles)")
          .font(.system(size: 14, weight: .semibold).monospacedDigit())
          .foregroundStyle(KoeNativePalette.bambooGreen)
        Spacer()
        if let ep = sidebar.wifiEndpoint {
          Text("\(ep.ipString):\(ep.port)")
            .font(.system(size: 12).monospacedDigit())
            .foregroundStyle(.secondary)
        }
      }
      if progress.expectedWireBytes > 0 {
        ProgressView(
          value: min(1.0, Double(progress.receivedWireBytes) / Double(max(1, progress.expectedWireBytes)))
        )
      }
      Text("当前 #\(progress.activeFileId) | 已完成 \(progress.finalizedCount) | 抢救 \(progress.salvagedCount) | 跳过 \(progress.skippedCount)")
        .font(.system(size: 12).monospacedDigit())
        .foregroundStyle(.secondary)
      if progress.phase == 3 {
        HStack(spacing: 12) {
          Button("继续快传") {
            sidebar.resumeWifiBatch()
          }
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(KoeNativePalette.bambooGreen)
          Button("取消") {
            sidebar.cancelWifiBatch()
          }
          .font(.system(size: 12))
          .foregroundStyle(.secondary)
        }
      }
    }
  }
}

public struct LiveInterpretingPanelView: View {
  @ObservedObject public var interpreting: LiveInterpretingModel
  @ObservedObject public var sidebar: BeanSidebarModel

  public init(interpreting: LiveInterpretingModel, sidebar: BeanSidebarModel) {
    self.interpreting = interpreting
    self.sidebar = sidebar
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      headerBar
      Divider()
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 12) {
          if interpreting.segments.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
              Text("实时双语同传字幕面板")
                .font(.system(size: 16, weight: .semibold))
              Text("点击左侧「运行 1A07/1A08 实时流闭环演示」或上方「麦克风同传」体验流式切片解密、中英双语字幕与自动语音播报。")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
            }
            .padding(16)
          } else {
            ForEach(interpreting.segments) { segment in
              captionCard(segment)
            }
          }
        }
        .padding(16)
      }
    }
    .background(KoeNativePalette.warmSurface)
  }

  private var headerBar: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Text("实时双语同传")
          .font(.system(size: 22, weight: .bold))
        Spacer()
        Toggle("同声传译语音播报", isOn: $interpreting.ttsEnabled)
          .font(.system(size: 14, weight: .medium))
      }
      HStack(spacing: 12) {
        Picker("源语言", selection: $interpreting.sourceLanguage) {
          Text("中文 (zh-CN)").tag("zh-CN")
          Text("English (en-US)").tag("en-US")
          Text("日本語 (ja-JP)").tag("ja-JP")
        }
        .font(.system(size: 12))

        Picker("目标语言", selection: $interpreting.targetLanguage) {
          Text("English (en-US)").tag("en-US")
          Text("中文 (zh-CN)").tag("zh-CN")
          Text("日本語 (ja-JP)").tag("ja-JP")
        }
        .font(.system(size: 12))

        Spacer()

        Button {
          interpreting.toggleMicrophoneLiveRecognition()
        } label: {
          Label(
            interpreting.isListeningMicrophone ? "停止麦克风" : "麦克风同传",
            systemImage: interpreting.isListeningMicrophone ? "stop.circle.fill" : "mic.circle.fill"
          )
          .font(.system(size: 14, weight: .semibold))
        }
      }
      Text(interpreting.statusBanner)
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
    }
    .padding(16)
  }

  private func captionCard(_ segment: KoeLiveCaptionSegment) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Text(segment.sourceText)
          .font(.system(size: 16, weight: .medium))
        Spacer()
        if segment.hasDoubleTapMark {
          Label("录音豆双击标记", systemImage: "bookmark.fill")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.orange)
        }
        Button {
          let text = segment.translatedText.isEmpty ? segment.sourceText : segment.translatedText
          interpreting.speak(segmentId: segment.id, text: text, language: interpreting.targetLanguage)
        } label: {
          Image(systemName: "speaker.wave.2.fill")
            .font(.system(size: 14))
            .foregroundStyle(KoeNativePalette.bambooGreen)
        }
        .buttonStyle(.plain)
      }
      if !segment.translatedText.isEmpty {
        Text(segment.translatedText)
          .font(.system(size: 14))
          .foregroundStyle(KoeNativePalette.bambooGreen)
      }
    }
    .padding(12)
    .background(Color.white)
    .overlay(
      RoundedRectangle(cornerRadius: 8)
        .stroke(KoeNativePalette.cardBorder, lineWidth: 1)
    )
    .clipShape(RoundedRectangle(cornerRadius: 8))
  }
}

public struct RecordingPlaybackDetailView: View {
  @ObservedObject public var playback: RecordingPlaybackModel
  @ObservedObject public var interpreting: LiveInterpretingModel

  public init(playback: RecordingPlaybackModel, interpreting: LiveInterpretingModel) {
    self.playback = playback
    self.interpreting = interpreting
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      if let rec = playback.selectedRecording {
        detailHeader(rec)
        Divider()
        scrubberAndMarksSection(rec)
        Divider()
        transcriptAndMarksList(rec)
      } else {
        VStack(spacing: 8) {
          Text("未选择录音")
            .font(.system(size: 16, weight: .semibold))
          Text("从左侧录音库选择一条录音，或点击「运行 1A07/1A08 实时流闭环演示」生成新录音。")
            .font(.system(size: 14))
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
  }

  private func detailHeader(_ rec: KoeSavedRecording) -> some View {
    HStack {
      VStack(alignment: .leading, spacing: 4) {
        Text(rec.title)
          .font(.system(size: 22, weight: .bold))
        Text("时长 \(rec.formattedDuration) | 大小 \(max(1, rec.byteCount / 1024)) KB | 双击标记 \(rec.marks.count) 处")
          .font(.system(size: 12))
          .foregroundStyle(.secondary)
      }
      Spacer()
      Button("移入回收站") {
        playback.moveToTrash(rec.id)
      }
      .font(.system(size: 12))
    }
    .padding(16)
  }

  private func scrubberAndMarksSection(_ rec: KoeSavedRecording) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 16) {
        Button {
          playback.togglePlayPause()
        } label: {
          Image(systemName: playback.playbackState.isPlaying ? "pause.circle.fill" : "play.circle.fill")
            .font(.system(size: 22))
            .foregroundStyle(KoeNativePalette.bambooGreen)
        }
        .buttonStyle(.plain)

        Button("上一标记") {
          playback.jumpToMark(direction: .previous)
        }
        .font(.system(size: 12, weight: .medium))
        .disabled(rec.marks.isEmpty)

        Button("下一标记") {
          playback.jumpToMark(direction: .next)
        }
        .font(.system(size: 12, weight: .medium))
        .disabled(rec.marks.isEmpty)

        Spacer()

        Picker("倍速", selection: $playback.playbackRate) {
          Text("1.0x").tag(Float(1.0))
          Text("1.25x").tag(Float(1.25))
          Text("1.5x").tag(Float(1.5))
          Text("2.0x").tag(Float(2.0))
        }
        .font(.system(size: 12))
        .frame(width: 110)
      }

      Slider(
        value: Binding(
          get: { Double(playback.playbackState.positionMs) },
          set: { playback.seek(toMs: UInt64($0)) }
        ),
        in: 0...Double(max(rec.durationMs, 1))
      )

      HStack {
        Text(MarkTimestampMs(sequence: 0, rawValue: playback.playbackState.positionMs).formattedClock)
          .font(.system(size: 12).monospacedDigit())
        Spacer()
        Text(rec.formattedDuration)
          .font(.system(size: 12).monospacedDigit())
      }
    }
    .padding(16)
  }

  private func transcriptAndMarksList(_ rec: KoeSavedRecording) -> some View {
    List {
      Section("录音豆双击重点标记 (点击直接跳转播放)") {
        if rec.marks.isEmpty {
          Text("本条录音无硬件双击标记")
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
        } else {
          ForEach(rec.marks) { mark in
            Button {
              playback.jumpToMark(mark)
            } label: {
              HStack {
                Image(systemName: "bookmark.fill")
                  .foregroundStyle(.orange)
                Text("重点标记 @ \(mark.formattedClock)")
                  .font(.system(size: 14, weight: .medium))
                Spacer()
                Text("切片序号 #\(mark.sequence) (\(mark.rawValue) ms)")
                  .font(.system(size: 12))
                  .foregroundStyle(.secondary)
              }
            }
            .buttonStyle(.plain)
          }
        }
      }

      Section("转写与同传记录") {
        let segments = rec.transcriptSegments.isEmpty ? interpreting.segments : rec.transcriptSegments
        if segments.isEmpty {
          Text("暂无逐句转写记录")
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
        } else {
          ForEach(segments) { seg in
            VStack(alignment: .leading, spacing: 4) {
              Text(seg.sourceText)
                .font(.system(size: 14, weight: .medium))
              if !seg.translatedText.isEmpty {
                Text(seg.translatedText)
                  .font(.system(size: 12))
                  .foregroundStyle(KoeNativePalette.bambooGreen)
              }
            }
            .padding(.vertical, 4)
          }
        }
      }
    }
  }
}
