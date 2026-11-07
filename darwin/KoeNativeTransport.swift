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
    return String(format: "%02d:%02d", totalSeconds / 60, totalSeconds % 60)
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
  private var buffer = Data()

  public init() {}

  public mutating func ingest(_ chunk: Data) -> [D3200DecodedFrame] {
    buffer.append(chunk)
    var frames = [D3200DecodedFrame]()
    while buffer.count >= 10 {
      let b0 = buffer[buffer.startIndex]
      let b1 = buffer[buffer.index(after: buffer.startIndex)]
      guard b0 == 0x09 && b1 == 0xFF else {
        buffer.removeFirst()
        continue
      }
      let lenIdx0 = buffer.index(buffer.startIndex, offsetBy: 7)
      let lenIdx1 = buffer.index(buffer.startIndex, offsetBy: 8)
      let length = Int(buffer[lenIdx0]) | (Int(buffer[lenIdx1]) << 8)
      guard length >= 10 && length <= 65535 else {
        buffer.removeFirst(2)
        continue
      }
      guard buffer.count >= length else { break }
      let frameData = Data(buffer.prefix(length))
      buffer.removeFirst(length)
      if KoeCore.verifyChecksum(frameData) {
        let cmdType = frameData[5]
        let cmdId = frameData[6]
        let payload = frameData.subdata(in: 9..<(length - 1))
        frames.append(D3200DecodedFrame(cmdType: cmdType, cmdId: cmdId, payload: payload, raw: frameData))
      }
    }
    return frames
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
  private var reassembler = D3200FrameReassembler()
  private var appPrivateKey = P256.KeyAgreement.PrivateKey()
  private var sessionKey: Data?
  private var activeFileId: BeanFileID?
  private var activeFileKey: Data?
  private var activeNonce: Data?
  private var activeExpectedBytes: Int = 0
  private var activeReceivedWireBytes: Int = 0
  private var activeOpusBuffer = Data()
  private var activeMarks = [MarkTimestampMs]()
  private var activeIsRealtime = false
  private var lastTelemetry: KoeDeviceTelemetry?
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

  public func setSessionKeyForTesting(_ key: Data) {
    self.sessionKey = key
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
    resetActiveTransfer()
    continuation?.yield(.transferChanged(.idle))
    continuation?.yield(.connectionChanged(.disconnected(reason: nil)))
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
    activeFileId = fid
    activeFileKey = nil
    activeNonce = nil
    let estimatedWireBytes = max(166, Int(item.durationMs / 20) * 166)
    activeExpectedBytes = estimatedWireBytes
    activeReceivedWireBytes = 0
    activeOpusBuffer.removeAll(keepingCapacity: true)
    activeMarks.removeAll()
    activeIsRealtime = false
    continuation?.yield(
      .transferChanged(
        .pullingOffline(fileId: fid, receivedBytes: 0, totalBytes: estimatedWireBytes, markCount: 0)
      )
    )
    let frame = KoeCore.encodeStartTransportAudioFile(
      fileId: item.fileId,
      alreadyTransferred: 0,
      realtimeFlag: 0
    )
    bleCentralBridge?.send(frame)
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
    resetActiveTransfer()
    continuation?.yield(.transferChanged(.idle))
    continuation?.yield(.connectionChanged(.disconnected(reason: reason)))
  }

  public func ingestRawBleChunk(_ chunk: Data, destinationDirectory: URL) async {
    let frames = reassembler.ingest(chunk)
    for frame in frames {
      await handleDecodedFrame(frame, destinationDirectory: destinationDirectory)
    }
  }

  private func handleDecodedFrame(_ frame: D3200DecodedFrame, destinationDirectory: URL) async {
    switch (frame.cmdType, frame.cmdId) {
    case (0x01, 0x01):
      let telemetry = KoeCore.parseDeviceInfoPacket(frame.raw)
      lastTelemetry = telemetry
      continuation?.yield(.connectionChanged(.connected(telemetry)))
      bleCentralBridge?.send(KoeCore.encodeGetFileList(pageIndex: 0))

    case (0x2E, 0x01):
      guard frame.payload.count >= 97 else { return }
      let devPub = frame.payload.subdata(in: 0..<65)
      let devShared = frame.payload.subdata(in: 65..<97)
      if let peerKey = try? P256.KeyAgreement.PublicKey(x963Representation: devPub),
         let shared = try? appPrivateKey.sharedSecretFromKeyAgreement(with: peerKey)
      {
        let sharedBytes = shared.withUnsafeBytes { Data($0) }
        if sharedBytes == devShared {
          sessionKey = KoeCore.hkdfSha256(ikm: sharedBytes)
        }
      }

    case (0x1A, 0x01), (0x1A, 0x0D), (0x1B, 0x0E):
      let withEndTime = (frame.cmdId == 0x0D || frame.cmdId == 0x0E)
      let page = KoeCore.parseOfflineFileList(frame.payload, withEndTime: withEndTime)
      continuation?.yield(.catalogUpdated(page.files))
      if case .none = activeFileId {
        continuation?.yield(.transferChanged(.idle))
      }

    case (0x1A, 0x07), (0x1B, 0x07):
      guard let head = KoeCore.parseFileHead(frame.raw, sessionKey: sessionKey) else { return }
      let fid = BeanFileID(rawValue: head.fileId)
      activeFileId = fid
      activeFileKey = head.fileKey
      activeNonce = head.nonce
      activeOpusBuffer.removeAll(keepingCapacity: true)
      activeMarks.removeAll()
      activeReceivedWireBytes = 0
      if head.unfinished {
        activeIsRealtime = true
        activeExpectedBytes = 0
        continuation?.yield(
          .transferChanged(.streamingRealtime(fileId: fid, receivedBytes: 0, markCount: 0))
        )
      } else {
        activeIsRealtime = false
        activeExpectedBytes = Int(head.fileSize)
        continuation?.yield(
          .transferChanged(
            .pullingOffline(
              fileId: fid,
              receivedBytes: 0,
              totalBytes: activeExpectedBytes,
              markCount: 0
            )
          )
        )
      }

    case (0x1A, 0x08), (0x1A, 0x12), (0x1B, 0x08), (0x1B, 0x12):
      let unpacked = KoeCore.unpackSlices(frame.raw, fileKey: activeFileKey, nonce: activeNonce)
      guard unpacked.sliceCount > 0 else { return }
      let fid = activeFileId ?? BeanFileID(rawValue: 1)
      activeFileId = fid
      activeOpusBuffer.append(unpacked.opusBytes)
      activeReceivedWireBytes += unpacked.wireRecordBytes
      let newMarks = unpacked.markedSequences.map { MarkTimestampMs(sequence: $0) }
      for m in newMarks where !activeMarks.contains(m) {
        activeMarks.append(m)
      }
      activeMarks.sort()
      if activeIsRealtime {
        continuation?.yield(
          .transferChanged(
            .streamingRealtime(
              fileId: fid,
              receivedBytes: activeReceivedWireBytes,
              markCount: activeMarks.count
            )
          )
        )
      } else {
        continuation?.yield(
          .transferChanged(
            .pullingOffline(
              fileId: fid,
              receivedBytes: activeReceivedWireBytes,
              totalBytes: max(activeExpectedBytes, activeReceivedWireBytes),
              markCount: activeMarks.count
            )
          )
        )
      }
      continuation?.yield(
        .liveSliceUnpacked(fileId: fid, sliceCount: unpacked.sliceCount, marks: newMarks)
      )

    case (0x1A, 0x0A), (0x1B, 0x0A):
      _ = await finalizeActiveRecording(destinationDirectory: destinationDirectory, segments: [])

    default:
      break
    }
  }

  public func finalizeActiveRecording(
    destinationDirectory: URL,
    segments: [KoeLiveCaptionSegment]
  ) async -> KoeSavedRecording? {
    guard let fid = activeFileId, !activeOpusBuffer.isEmpty else {
      resetActiveTransfer()
      continuation?.yield(.transferChanged(.idle))
      return nil
    }
    try? FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
    let opusData = KoeCore.muxOggOpus(activeOpusBuffer)
    let opusURL = destinationDirectory.appendingPathComponent("\(fid.rawValue).opus")
    try? opusData.write(to: opusURL, options: .atomic)

    let sliceCount = activeOpusBuffer.count / 160
    let durationMs = UInt64(sliceCount) * 20
    let wavURL = destinationDirectory.appendingPathComponent("\(fid.rawValue).wav")
    let wavData = Self.buildAudiblePreviewWAV(durationMs: max(durationMs, 400), marks: activeMarks)
    try? wavData.write(to: wavURL, options: .atomic)

    let saved = KoeSavedRecording(
      id: RecordingID(rawValue: "\(fid.rawValue)"),
      beanFileId: fid,
      title: "录音豆 #\(fid.rawValue)",
      createdAt: Date(),
      durationMs: max(durationMs, 400),
      byteCount: opusData.count,
      opusFileURL: opusURL,
      playableWAVURL: wavURL,
      marks: activeMarks,
      transcriptSegments: segments
    )
    resetActiveTransfer()
    continuation?.yield(.transferChanged(.idle))
    continuation?.yield(.recordingSaved(saved))
    return saved
  }

  public func simulateBeanRealtimePipeline(destinationDirectory: URL) async -> KoeSavedRecording? {
    let sk = KoeCore.hkdfSha256(ikm: Data(repeating: 0x42, count: 32))
    sessionKey = sk

    var telemetryPacket = Data([0x09, 0xFF, 0x00, 0x00, 0x01, 0x01, 0x01, 0x00, 0x00])
    telemetryPacket.append(1)
    telemetryPacket.append(8)
    telemetryPacket.append(1)
    telemetryPacket.append(contentsOf: Array("1.4.8".utf8))
    telemetryPacket.append(contentsOf: Array("D3200NATIVE639D0".utf8))
    var totalMem: UInt32 = (64 * 1024 * 1024).littleEndian
    var freeMem: UInt32 = (58 * 1024 * 1024).littleEndian
    withUnsafeBytes(of: &totalMem) { telemetryPacket.append(contentsOf: $0) }
    withUnsafeBytes(of: &freeMem) { telemetryPacket.append(contentsOf: $0) }
    telemetryPacket.append(0)
    telemetryPacket.append(contentsOf: Array("2.1.0".utf8))
    telemetryPacket.append(9)
    telemetryPacket.append(contentsOf: [0xAA, 0xBB, 0xCC, 0xDD, 0x63, 0x9D])
    let telLen = UInt16(telemetryPacket.count + 1)
    telemetryPacket[7] = UInt8(telLen & 0xFF)
    telemetryPacket[8] = UInt8((telLen >> 8) & 0xFF)
    telemetryPacket.append(KoeCore.checksum(telemetryPacket))
    await ingestRawBleChunk(telemetryPacket, destinationDirectory: destinationDirectory)

    var plainFileKeyMaterial = Data("soundcored3200".utf8)
    let fileKey = Data((0..<32).map { UInt8(($0 * 7 + 13) & 0xFF) })
    plainFileKeyMaterial.append(fileKey)
    let sessionNonce = Data((0..<16).map { UInt8(($0 * 3 + 5) & 0xFF) })
    var encryptedFileKey = plainFileKeyMaterial
    _ = encryptedFileKey.withUnsafeMutableBytes { buf in
      sk.withUnsafeBytes { skRaw in
        sessionNonce.withUnsafeBytes { ivRaw in
          koe_crypto_aes_ctr_in_place(
            buf.bindMemory(to: UInt8.self).baseAddress,
            plainFileKeyMaterial.count,
            skRaw.bindMemory(to: UInt8.self).baseAddress,
            sk.count,
            ivRaw.bindMemory(to: UInt8.self).baseAddress,
            sessionNonce.count
          )
        }
      }
    }

    let fileNonce = Data((0..<16).map { UInt8(($0 * 11 + 19) & 0xFF) })
    let demoFileId: UInt32 = 20261107
    var headPayload = Data()
    var fidLe = demoFileId.littleEndian
    var fsizeLe = UInt32.max.littleEndian
    withUnsafeBytes(of: &fidLe) { headPayload.append(contentsOf: $0) }
    withUnsafeBytes(of: &fsizeLe) { headPayload.append(contentsOf: $0) }
    headPayload.append(fileNonce)
    headPayload.append(encryptedFileKey)
    headPayload.append(sessionNonce)
    headPayload.append(0)
    let headFrame = KoeCore.encodeFrame(cmdType: 0x1A, cmdId: 0x07, payload: headPayload)
    var rxHead = headFrame
    rxHead[0] = 0x09
    rxHead[1] = 0xFF
    rxHead[rxHead.count - 1] = KoeCore.checksum(rxHead.prefix(rxHead.count - 1))
    await ingestRawBleChunk(rxHead, destinationDirectory: destinationDirectory)

    var slicePayload = Data()
    for seq in UInt32(0)..<UInt32(60) {
      var seqLe = seq.littleEndian
      withUnsafeBytes(of: &seqLe) { slicePayload.append(contentsOf: $0) }
      let flags: UInt8 = (seq == 15 || seq == 45) ? 0x01 : 0x00
      slicePayload.append(flags)
      var chunk = Data(repeating: 0x78, count: 160)
      chunk[1] = UInt8(seq & 0xFF)
      _ = chunk.withUnsafeMutableBytes { cBuf in
        fileKey.withUnsafeBytes { fkRaw in
          fileNonce.withUnsafeBytes { ivRaw in
            koe_crypto_decrypt_chunks_in_place(
              cBuf.bindMemory(to: UInt8.self).baseAddress,
              160,
              fkRaw.bindMemory(to: UInt8.self).baseAddress,
              fileKey.count,
              ivRaw.bindMemory(to: UInt8.self).baseAddress,
              fileNonce.count,
              seq
            )
          }
        }
      }
      slicePayload.append(chunk)
      slicePayload.append(0x00)
    }
    var rxSlices = KoeCore.encodeFrame(cmdType: 0x1A, cmdId: 0x08, payload: slicePayload)
    rxSlices[0] = 0x09
    rxSlices[1] = 0xFF
    rxSlices[rxSlices.count - 1] = KoeCore.checksum(rxSlices.prefix(rxSlices.count - 1))
    await ingestRawBleChunk(rxSlices, destinationDirectory: destinationDirectory)

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
    return await finalizeActiveRecording(
      destinationDirectory: destinationDirectory,
      segments: [seg1, seg2]
    )
  }

  private func resetActiveTransfer() {
    activeFileId = nil
    activeFileKey = nil
    activeNonce = nil
    activeExpectedBytes = 0
    activeReceivedWireBytes = 0
    activeOpusBuffer.removeAll(keepingCapacity: false)
    activeMarks.removeAll()
    activeIsRealtime = false
  }

  public static func defaultExportDirectory() -> URL {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? FileManager.default.temporaryDirectory
    return base
      .appendingPathComponent("AnkerRecorder", isDirectory: true)
      .appendingPathComponent("exports", isDirectory: true)
  }

  private static func buildAudiblePreviewWAV(durationMs: UInt64, marks: [MarkTimestampMs]) -> Data {
    let sampleRate = 16000
    let totalSamples = max(1600, Int(durationMs) * sampleRate / 1000)
    let pcmByteLength = UInt32(totalSamples * 2)
    var out = KoeCore.wavHeader(pcmLength: pcmByteLength)
    out.reserveCapacity(44 + Int(pcmByteLength))
    let markSamples = Set(marks.map { Int($0.rawValue) * sampleRate / 1000 })
    for i in 0..<totalSamples {
      let isNearMark = markSamples.contains { abs(i - $0) < 800 }
      let freq = isNearMark ? 880.0 : 440.0
      let amp = isNearMark ? 6000.0 : 1800.0
      let sample = Int16(sin(2.0 * .pi * freq * Double(i) / Double(sampleRate)) * amp)
      var le = sample.littleEndian
      withUnsafeBytes(of: &le) { out.append(contentsOf: $0) }
    }
    return out
  }
}

final class D3200CoreBluetoothBridge: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate, @unchecked Sendable {
  static let serviceUUID = CBUUID(string: "020CF5DA-0000-1000-8000-00805F9B34FB")
  static let writeUUID = CBUUID(string: "00007777-0000-1000-8000-00805F9B34FB")
  static let notifyUUID = CBUUID(string: "00008888-0000-1000-8000-00805F9B34FB")

  private let onChunk: @Sendable (Data) async -> Void
  private let onReady: @Sendable (String) async -> Void
  private let onDisconnected: @Sendable (String?) async -> Void
  private var central: CBCentralManager?
  private var peripheral: CBPeripheral?
  private var writeChar: CBCharacteristic?
  private let queue = DispatchQueue(label: "com.semanticcraft.koe.native.ble")

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
    queue.async { [weak self] in
      guard let self else { return }
      if self.central == nil {
        self.central = CBCentralManager(delegate: self, queue: self.queue)
      } else if self.central?.state == .poweredOn {
        self.central?.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
      }
    }
  }

  func disconnect() {
    queue.async { [weak self] in
      guard let self else { return }
      self.central?.stopScan()
      if let p = self.peripheral {
        self.central?.cancelPeripheralConnection(p)
      }
      self.peripheral = nil
      self.writeChar = nil
    }
  }

  func send(_ frame: Data) {
    queue.async { [weak self] in
      guard let self, let p = self.peripheral, let c = self.writeChar else { return }
      p.writeValue(frame, for: c, type: .withoutResponse)
    }
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
