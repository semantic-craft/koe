import CoreBluetooth
import CryptoKit
import Foundation

public struct BeanFileID: Hashable, Codable, Sendable, RawRepresentable {
  public let rawValue: UInt32
  public init(rawValue: UInt32) { self.rawValue = rawValue }
}

public struct RecordingID: Hashable, Codable, Sendable, RawRepresentable {
  public let rawValue: String
  public init(rawValue: String) { self.rawValue = rawValue }
}

public struct MarkTimestampMs: Comparable, Hashable, Codable, Sendable, Identifiable {
  public var id: UInt32 { sequence }
  public let sequence: UInt32
  public let rawValue: UInt64

  public init(sequence: UInt32) {
    self.sequence = sequence
    self.rawValue = KoeCore.sliceMarkPositionMs(sequence)
  }

  public init(sequence: UInt32, rawValue: UInt64) {
    self.sequence = sequence
    self.rawValue = rawValue
  }

  public var seconds: TimeInterval {
    TimeInterval(rawValue) / 1000.0
  }

  public var formattedClock: String {
    let totalSeconds = Int(rawValue / 1000)
    let tenths = Int((rawValue % 1000) / 100)
    return String(format: "%02d:%02d.%d", totalSeconds / 60, totalSeconds % 60, tenths)
  }

  public static func < (lhs: Self, rhs: Self) -> Bool {
    lhs.rawValue < rhs.rawValue
  }
}

public enum KoeConnectionPhase: Equatable, Sendable {
  case disconnected(reason: String?)
  case scanning
  case connecting(name: String)
  case handshaking
  case connected(KoeDeviceTelemetry)

  public var isConnected: Bool {
    if case .connected = self { return true }
    return false
  }
}

public enum KoeActiveTransfer: Equatable, Sendable {
  case idle
  case queryingCatalog
  case pullingOffline(fileId: BeanFileID, receivedBytes: Int, totalBytes: Int, markCount: Int)
  case streamingRealtime(fileId: BeanFileID, receivedBytes: Int, markCount: Int)
  case failed(reason: String)

  public var progressFraction: Double {
    switch self {
    case .pullingOffline(_, let received, let total, _):
      guard total > 0 else { return 0 }
      return min(1.0, max(0.0, Double(received) / Double(total)))
    default:
      return 0
    }
  }
}

public enum KoePlaybackState: Equatable, Sendable {
  case stopped
  case playing(recordingId: RecordingID, positionMs: UInt64, durationMs: UInt64)
  case paused(recordingId: RecordingID, positionMs: UInt64, durationMs: UInt64)

  public var isPlaying: Bool {
    if case .playing = self { return true }
    return false
  }

  public var positionMs: UInt64 {
    switch self {
    case .playing(_, let pos, _), .paused(_, let pos, _):
      return pos
    case .stopped:
      return 0
    }
  }
}

public enum KoeTTSState: Equatable, Sendable {
  case idle
  case speaking(segmentId: UUID, text: String)
}

public struct KoeLiveCaptionSegment: Identifiable, Equatable, Codable, Sendable {
  public let id: UUID
  public var startMs: UInt64
  public var endMs: UInt64
  public var sourceText: String
  public var translatedText: String
  public var isFinal: Bool
  public var hasDoubleTapMark: Bool

  public init(
    id: UUID = UUID(),
    startMs: UInt64,
    endMs: UInt64,
    sourceText: String,
    translatedText: String = "",
    isFinal: Bool = false,
    hasDoubleTapMark: Bool = false
  ) {
    self.id = id
    self.startMs = startMs
    self.endMs = endMs
    self.sourceText = sourceText
    self.translatedText = translatedText
    self.isFinal = isFinal
    self.hasDoubleTapMark = hasDoubleTapMark
  }
}

public struct KoeSavedRecording: Identifiable, Equatable, Codable, Sendable {
  public let id: RecordingID
  public let beanFileId: BeanFileID?
  public var title: String
  public let createdAt: Date
  public let durationMs: UInt64
  public let byteCount: Int
  public let opusFileURL: URL
  public let playableWAVURL: URL?
  public var marks: [MarkTimestampMs]
  public var transcriptSegments: [KoeLiveCaptionSegment]

  public var formattedDuration: String {
    let totalSeconds = Int(durationMs / 1000)
    return String(format: "%02d:%02d", totalSeconds / 60, totalSeconds % 60)
  }
}

public enum BeanEvent: Equatable, Sendable {
  case connectionChanged(KoeConnectionPhase)
  case catalogUpdated([KoeOfflineFileItem])
  case transferChanged(KoeActiveTransfer)
  case liveSliceUnpacked(fileId: BeanFileID, sliceCount: Int, marks: [MarkTimestampMs])
  case liveCaptionProduced(KoeLiveCaptionSegment)
  case recordingSaved(KoeSavedRecording)
}

public struct D3200DecodedFrame: Equatable, Sendable {
  public let cmdType: UInt8
  public let cmdId: UInt8
  public let payload: Data
  public let raw: Data
}

public struct D3200FrameReassembler: Sendable {
  private let inner = KoeFrameReassembler()

  public init() {}

  public mutating func ingest(_ chunk: Data) -> [D3200DecodedFrame] {
    inner.ingest(chunk).map { pkt in
      D3200DecodedFrame(cmdType: pkt.cmdType, cmdId: pkt.cmdId, payload: pkt.payload, raw: pkt.raw)
    }
  }
}

public protocol BeanTransporting: Actor {
  nonisolated func events() -> AsyncStream<BeanEvent>
  func startScanAndConnect() async
  func disconnect() async
  func requestCatalog() async
  func startBeanRecording() async
  func stopBeanRecording() async
  func pullOfflineFile(_ item: KoeOfflineFileItem, destinationDirectory: URL) async
  func simulateBeanRealtimePipeline(destinationDirectory: URL) async -> KoeSavedRecording?
  func ingestRawBleChunk(_ chunk: Data, destinationDirectory: URL) async
}

public actor BeanTransportActor: BeanTransporting {
  private var continuation: AsyncStream<BeanEvent>.Continuation?
  private let eventStream: AsyncStream<BeanEvent>
  private let session = KoeTransportSession()
  private var ecdhReassembler = KoeFrameReassembler()
  private var appPrivateKey = P256.KeyAgreement.PrivateKey()
  private var bleCentralBridge: D3200CoreBluetoothBridge?

  public init() {
    var captured: AsyncStream<BeanEvent>.Continuation?
    self.eventStream = AsyncStream<BeanEvent> { cont in
      captured = cont
    }
    self.continuation = captured
  }

  public nonisolated func events() -> AsyncStream<BeanEvent> {
    eventStream
  }

  public func startScanAndConnect() async {
    continuation?.yield(.connectionChanged(.scanning))
    if bleCentralBridge == nil {
      let bridge = D3200CoreBluetoothBridge { [weak self] chunk in
        guard let self else { return }
        let dir = Self.defaultExportDirectory()
        await self.ingestRawBleChunk(chunk, destinationDirectory: dir)
      } onReady: { [weak self] peripheralName in
        guard let self else { return }
        await self.onGattLinkReady(peripheralName: peripheralName)
      } onDisconnected: { [weak self] reason in
        guard let self else { return }
        await self.onGattDisconnected(reason: reason)
      }
      bleCentralBridge = bridge
    }
    bleCentralBridge?.startScan()
  }

  public func disconnect() async {
    bleCentralBridge?.disconnect()
    session.onDisconnected()
    ecdhReassembler.reset()
    continuation?.yield(.transferChanged(.idle))
    continuation?.yield(.connectionChanged(.disconnected(reason: nil)))
  }

  public func finishStream() {
    continuation?.finish()
  }

  public func requestCatalog() async {
    continuation?.yield(.transferChanged(.queryingCatalog))
    bleCentralBridge?.send(KoeCore.encodeGetFileList(pageIndex: 0))
  }

  public func startBeanRecording() async {
    bleCentralBridge?.send(KoeCore.encodeStartRecord())
  }

  public func stopBeanRecording() async {
    bleCentralBridge?.send(KoeCore.encodeStopRecord())
  }

  public func pullOfflineFile(_ item: KoeOfflineFileItem, destinationDirectory: URL) async {
    let fid = BeanFileID(rawValue: item.fileId)
    let txFrame = session.beginOfflinePull(fileId: item.fileId, durationMs: item.durationMs)
    let estimatedWireBytes = max(166, Int(item.durationMs / 20) * 166)
    continuation?.yield(
      .transferChanged(
        .pullingOffline(fileId: fid, receivedBytes: 0, totalBytes: estimatedWireBytes, markCount: 0)
      )
    )
    bleCentralBridge?.send(txFrame)
  }

  private func onGattLinkReady(peripheralName: String) async {
    continuation?.yield(.connectionChanged(.handshaking))
    let privateKey = P256.KeyAgreement.PrivateKey()
    appPrivateKey = privateKey
    let pubKey65 = privateKey.publicKey.x963Representation
    bleCentralBridge?.send(KoeCore.encodeHandshakeKey(pubKey65))
    bleCentralBridge?.send(KoeCore.encodeGetDeviceInfo())
  }

  private func onGattDisconnected(reason: String?) async {
    session.onDisconnected()
    ecdhReassembler.reset()
    continuation?.yield(.transferChanged(.idle))
    continuation?.yield(.connectionChanged(.disconnected(reason: reason)))
  }

  public func ingestRawBleChunk(_ chunk: Data, destinationDirectory: URL) async {
    for pkt in ecdhReassembler.ingest(chunk) where pkt.cmdType == 0x2E && pkt.cmdId == 0x01 {
      let payload = pkt.payload
      if payload.count >= 97,
         let peerKey = try? P256.KeyAgreement.PublicKey(x963Representation: payload.prefix(65)),
         let shared = try? appPrivateKey.sharedSecretFromKeyAgreement(with: peerKey)
      {
        let sharedBytes = shared.withUnsafeBytes { Data($0) }
        _ = session.acceptEcdhReply(replyPayload: payload, sharedSecret: sharedBytes)
      }
    }

    let nowSec = UInt64(Date().timeIntervalSince1970)
    let step = session.ingestBleChunk(chunk, nowEpochSec: nowSec)
    for tx in step.outboundTxFrames {
      bleCentralBridge?.send(tx)
    }
    if step.telemetryUpdated, let tel = session.currentTelemetry() {
      continuation?.yield(.connectionChanged(.connected(tel)))
    }
    if step.catalogUpdated {
      continuation?.yield(.catalogUpdated(session.currentCatalog()))
    }
    if step.transferUpdated {
      emitTransferProgress(step)
    }
    if step.hasFinalizedRecording {
      _ = persistFinalizedFromSession(destinationDirectory: destinationDirectory, segments: [])
    }
  }

  public func finalizeActiveRecording(
    destinationDirectory: URL,
    segments: [KoeLiveCaptionSegment]
  ) async -> KoeSavedRecording? {
    let nowSec = UInt64(Date().timeIntervalSince1970)
    guard session.finalizeActiveTransfer(nowEpochSec: nowSec) else {
      session.resetActiveTransfer()
      continuation?.yield(.transferChanged(.idle))
      return nil
    }
    return persistFinalizedFromSession(destinationDirectory: destinationDirectory, segments: segments)
  }

  public func simulateBeanRealtimePipeline(destinationDirectory: URL) async -> KoeSavedRecording? {
    let nowSec = UInt64(Date().timeIntervalSince1970)
    let step = session.simulateRealtimePipeline(nowEpochSec: nowSec)
    if step.telemetryUpdated, let tel = session.currentTelemetry() {
      continuation?.yield(.connectionChanged(.connected(tel)))
    }
    let seg1 = KoeLiveCaptionSegment(
      startMs: 0,
      endMs: 600,
      sourceText: "今天我们把录音豆的实时切片和解密管线全部迁到了 Rust 内核。",
      translatedText: "Today we migrated the bean's live slice and decryption pipeline into the Rust kernel.",
      isFinal: true,
      hasDoubleTapMark: true
    )
    let seg2 = KoeLiveCaptionSegment(
      startMs: 600,
      endMs: 1200,
      sourceText: "现在 SwiftUI 原生宿主可以直接完成连接、同传播报与双击标记跳转。",
      translatedText: "Now the native SwiftUI host directly handles connection, live interpreting read-aloud, and double-tap mark jumping.",
      isFinal: true,
      hasDoubleTapMark: true
    )
    continuation?.yield(.liveCaptionProduced(seg1))
    continuation?.yield(.liveCaptionProduced(seg2))
    return persistFinalizedFromSession(
      destinationDirectory: destinationDirectory,
      segments: [seg1, seg2]
    )
  }

  private func emitTransferProgress(_ step: KoeSessionStepOutcome) {
    let fid = BeanFileID(rawValue: step.transferFileId)
    switch step.transferPhase {
    case 1:
      continuation?.yield(.transferChanged(.queryingCatalog))
    case 2:
      continuation?.yield(
        .transferChanged(
          .pullingOffline(
            fileId: fid,
            receivedBytes: Int(step.receivedWireBytes),
            totalBytes: max(Int(step.expectedWireBytes), Int(step.receivedWireBytes)),
            markCount: Int(step.transferMarkCount)
          )
        )
      )
    case 3:
      continuation?.yield(
        .transferChanged(
          .streamingRealtime(
            fileId: fid,
            receivedBytes: Int(step.receivedWireBytes),
            markCount: Int(step.transferMarkCount)
          )
        )
      )
    default:
      continuation?.yield(.transferChanged(.idle))
    }
  }

  private func persistFinalizedFromSession(
    destinationDirectory: URL,
    segments: [KoeLiveCaptionSegment]
  ) -> KoeSavedRecording? {
    guard let fin = session.takeFinalized() else { return nil }
    try? FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
    let fid = BeanFileID(rawValue: fin.entry.beanFileId)
    let opusURL = destinationDirectory.appendingPathComponent("\(fin.entry.id).opus")
    try? fin.oggOpusBytes.write(to: opusURL, options: .atomic)
    let wavURL = destinationDirectory.appendingPathComponent("\(fin.entry.id).wav")
    try? fin.previewWavBytes.write(to: wavURL, options: .atomic)
    let marks = fin.entry.marksMs.map { ms in
      MarkTimestampMs(sequence: UInt32(ms / 20), rawValue: ms)
    }
    let saved = KoeSavedRecording(
      id: RecordingID(rawValue: "\(fin.entry.id)"),
      beanFileId: fid,
      title: "录音豆 #\(fin.entry.id)",
      createdAt: Date(timeIntervalSince1970: TimeInterval(fin.entry.createdAtEpochSec)),
      durationMs: fin.entry.durationMs,
      byteCount: Int(fin.entry.byteCount),
      opusFileURL: opusURL,
      playableWAVURL: wavURL,
      marks: marks,
      transcriptSegments: segments
    )
    continuation?.yield(.transferChanged(.idle))
    continuation?.yield(.recordingSaved(saved))
    return saved
  }

  public static func defaultExportDirectory() -> URL {
    if let custom = ProcessInfo.processInfo.environment["KOE_EXPORT_DIR"], !custom.isEmpty {
      return URL(fileURLWithPath: custom, isDirectory: true)
    }
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? FileManager.default.temporaryDirectory
    return base
      .appendingPathComponent("AnkerRecorder", isDirectory: true)
      .appendingPathComponent("exports", isDirectory: true)
  }
}

final class D3200CoreBluetoothBridge: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
  static let serviceUUID = CBUUID(string: "020CF5DA-0000-1000-8000-00805F9B34FB")
  static let writeUUID = CBUUID(string: "00007777-0000-1000-8000-00805F9B34FB")
  static let notifyUUID = CBUUID(string: "00008888-0000-1000-8000-00805F9B34FB")

  private let onChunk: @Sendable (Data) async -> Void
  private let onReady: @Sendable (String) async -> Void
  private let onDisconnected: @Sendable (String?) async -> Void
  private var central: CBCentralManager?
  private var peripheral: CBPeripheral?
  private var writeChar: CBCharacteristic?

  init(
    onChunk: @escaping @Sendable (Data) async -> Void,
    onReady: @escaping @Sendable (String) async -> Void,
    onDisconnected: @escaping @Sendable (String?) async -> Void
  ) {
    self.onChunk = onChunk
    self.onReady = onReady
    self.onDisconnected = onDisconnected
    super.init()
  }

  func startScan() {
    if central == nil {
      central = CBCentralManager(delegate: self, queue: nil)
    } else if central?.state == .poweredOn {
      central?.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
    }
  }

  func disconnect() {
    central?.stopScan()
    if let p = peripheral {
      central?.cancelPeripheralConnection(p)
    }
    peripheral = nil
    writeChar = nil
  }

  func send(_ frame: Data) {
    guard let p = peripheral, let c = writeChar else { return }
    p.writeValue(frame, for: c, type: .withoutResponse)
  }

  func centralManagerDidUpdateState(_ central: CBCentralManager) {
    if central.state == .poweredOn {
      central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
    } else if central.state == .unauthorized || central.state == .poweredOff {
      let msg = central.state == .unauthorized ? "蓝牙权限未开启" : "系统蓝牙已关闭"
      Task { await onDisconnected(msg) }
    }
  }

  func centralManager(
    _ central: CBCentralManager,
    didDiscover peripheral: CBPeripheral,
    advertisementData: [String: Any],
    rssi RSSI: NSNumber
  ) {
    let advName = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name ?? ""
    let uuids = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []
    let matchesService = uuids.contains { $0.uuidString.uppercased().contains("F5DA") }
    let matchesName = advName.lowercased().contains("soundcore") || advName.lowercased().contains("work") || advName.lowercased().contains("d3200")
    guard matchesService || matchesName else { return }
    central.stopScan()
    self.peripheral = peripheral
    peripheral.delegate = self
    central.connect(peripheral, options: nil)
  }

  func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
    peripheral.discoverServices(nil)
  }

  func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
    self.writeChar = nil
    Task { await onDisconnected(error?.localizedDescription) }
  }

  func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
    guard let services = peripheral.services else { return }
    for svc in services {
      peripheral.discoverCharacteristics([Self.writeUUID, Self.notifyUUID], for: svc)
    }
  }

  func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
    guard let chars = service.characteristics else { return }
    var notifyReady = false
    for c in chars {
      let id = c.uuid.uuidString.uppercased()
      if id.contains("7777") {
        writeChar = c
      } else if id.contains("8888") {
        peripheral.setNotifyValue(true, for: c)
        notifyReady = true
      }
    }
    if writeChar != nil && notifyReady {
      let name = peripheral.name ?? "soundcore Work"
      Task { await onReady(name) }
    }
  }

  func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
    guard let data = characteristic.value, !data.isEmpty else { return }
    Task { await onChunk(data) }
  }
}
