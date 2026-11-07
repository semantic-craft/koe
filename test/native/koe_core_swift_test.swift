import Foundation

@main
struct KoeCoreSwiftTest {
  static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
      fputs("FAIL: \(message)\n", stderr)
      exit(1)
    }
  }

  static func main() async {
    let encoded = KoeCore.encodeFrame(cmdType: 0x01, cmdId: 0x01)
    check(encoded.count == 10, "encoded getDeviceInfo length must be 10")
    check(encoded[0] == 0x08 && encoded[1] == 0xEE, "TX magic must be 08 EE")
    check(KoeCore.verifyChecksum(encoded), "encoded frame must pass checksum verification")

    check(KoeCore.batteryRemaining(0) == 10, "bucket 0 must map to 10%")
    check(KoeCore.batteryRemaining(9) == 100, "bucket 9 must map to 100%")
    check(KoeCore.batteryRemaining(75) == 75, "literal 75% must stay 75%")

    var rxPacket = Data([0x09, 0xFF, 0x00, 0x00, 0x01, 0x01, 0x01, 0x00, 0x00])
    rxPacket.append(1)
    rxPacket.append(4)
    rxPacket.append(1)
    rxPacket.append(contentsOf: Array("1.2.3".utf8))
    rxPacket.append(contentsOf: Array("D3200ABCDEF12345".utf8))
    var totalMem: UInt32 = (64 * 1024 * 1024).littleEndian
    var freeMem: UInt32 = (60 * 1024 * 1024).littleEndian
    withUnsafeBytes(of: &totalMem) { rxPacket.append(contentsOf: $0) }
    withUnsafeBytes(of: &freeMem) { rxPacket.append(contentsOf: $0) }
    rxPacket.append(0)
    rxPacket.append(contentsOf: Array("2.0.1".utf8))
    rxPacket.append(8)
    rxPacket.append(contentsOf: [0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0x01])
    let totalLen = UInt16(rxPacket.count + 1)
    rxPacket[7] = UInt8(totalLen & 0xFF)
    rxPacket[8] = UInt8((totalLen >> 8) & 0xFF)
    rxPacket.append(KoeCore.checksum(rxPacket))

    let telemetry = KoeCore.parseDeviceInfoPacket(rxPacket)
    check(telemetry.connectStatus == 1, "connectStatus must be 1")
    check(telemetry.battery == 50, "battery must be 50")
    check(telemetry.charging == true, "charging must be true")
    check(telemetry.firmwareVersion == "1.2.3", "firmwareVersion must match")
    check(telemetry.serialNumber == "d3200abcdef12345", "serialNumber must be lowercased")
    check(telemetry.totalMemoryKb == 64 * 1024 * 1024, "totalMemoryKb must match")
    check(telemetry.freeMemoryKb == 60 * 1024 * 1024, "freeMemoryKb must match")
    check(telemetry.boxBattery == 90, "boxBattery must be 90")
    check(telemetry.boxMac == "AA:BB:CC:DD:EE:01", "boxMac must match")

    let fileListPayload = Data([
      1, 0,
      100, 0, 0, 0,
      200, 0, 0, 0,
      44, 1, 0, 0,
      144, 1, 0, 0,
      244, 1, 0, 0,
    ])
    let page = KoeCore.parseOfflineFileList(fileListPayload, withEndTime: true)
    check(page.fileCount == 1, "fileCount must be 1")
    check(page.files.count == 1, "files.count must be 1")
    check(page.files[0].fileId == 100, "fileId must be 100")
    check(page.files[0].endTime == 200, "endTime must be 200")
    check(page.files[0].durationMs == 300, "durationMs must be 300")
    check(page.currentTransportTimestamp == 400, "currentTransportTimestamp must be 400")
    check(page.currentTransportDuration == 500, "currentTransportDuration must be 500")

    var rawOpus = Data(count: 320)
    rawOpus[0] = 0x78
    rawOpus[160] = 0x78
    let ogg = KoeCore.muxOggOpus(rawOpus)
    check(ogg.count > 64 && String(decoding: ogg.prefix(4), as: UTF8.self) == "OggS", "muxOggOpus must emit OggS")

    let wav = KoeCore.wavHeader(pcmLength: 1920)
    check(wav.count == 44 && String(decoding: wav.prefix(4), as: UTF8.self) == "RIFF", "wavHeader must emit 44-byte RIFF")

    let opusPacket94 = Data([
      0x78, 0x81, 0xa7, 0x5d, 0x6c, 0x9e, 0x99, 0xac, 0x00, 0x00, 0x06, 0x7e,
      0x56, 0x39, 0xf7, 0x3b, 0x1e, 0xa2, 0xdc, 0x31, 0x0f, 0x52, 0x38, 0x39,
      0x39, 0x3e, 0xa3, 0xd0, 0x84, 0x47, 0xcb, 0xe1, 0xb6, 0xb8, 0xff, 0x44,
      0x14, 0x3d, 0x76, 0x21, 0xaf, 0x07, 0x34, 0xdd, 0x07, 0x87, 0xec, 0x99,
      0xfe, 0xc0, 0xf5, 0x44, 0x18, 0x9d, 0x5f, 0x48, 0x29, 0x42, 0xde, 0xd8,
      0x2f, 0x85, 0xb6, 0x18, 0xf4, 0x3b, 0x64, 0x92, 0xde, 0x94, 0x70, 0x50,
      0xe0, 0x97, 0x68, 0x7d, 0x6c, 0x10, 0xd0, 0xaf, 0x63, 0x85, 0x53, 0xa2,
      0x71, 0x65, 0xe7, 0x91, 0x29, 0x01, 0x80, 0x53, 0x15, 0x04,
    ])
    var padded160 = Data(count: 160)
    padded160.replaceSubrange(0..<opusPacket94.count, with: opusPacket94)
    let pcm16k = KoeCore.decodeOpusPcm16(padded160, sampleRate: 16_000)
    check(pcm16k.count == 640, "decodeOpusPcm16(16kHz) must decode 320 samples (640 bytes)")
    let sample130 = Int16(bitPattern: UInt16(pcm16k[130 * 2]) | (UInt16(pcm16k[130 * 2 + 1]) << 8))
    check(abs(Int(sample130) - (-4130)) <= 16, "decodeOpusPcm16(16kHz) sample 130 must be near -4130")
    let pcm48k = KoeCore.decodeOpusPcm16(padded160, sampleRate: 48_000)
    check(pcm48k.count == 1920, "decodeOpusPcm16(48kHz) must decode 960 samples (1920 bytes)")
    let decodedWav = KoeCore.decodeOpusWav(padded160, sampleRate: 48_000, marksMs: [0])
    check(decodedWav.count == 44 + 1920 && String(decoding: decodedWav.prefix(4), as: UTF8.self) == "RIFF", "decodeOpusWav must emit 1964-byte RIFF WAV")

    var headFrame = Data([0x09, 0xFF, 0x00, 0x00, 0x01, 0x1A, 0x07, 0x62, 0x00])
    var fid: UInt32 = UInt32(888).littleEndian
    var fsize: UInt32 = UInt32.max.littleEndian
    withUnsafeBytes(of: &fid) { headFrame.append(contentsOf: $0) }
    withUnsafeBytes(of: &fsize) { headFrame.append(contentsOf: $0) }
    headFrame.append(contentsOf: [UInt8](repeating: 0x33, count: 16))
    headFrame.append(contentsOf: [UInt8](repeating: 0x44, count: 46))
    headFrame.append(contentsOf: [UInt8](repeating: 0x55, count: 16))
    headFrame.append(0)
    headFrame.append(0)
    let parsedHead = KoeCore.parseFileHead(headFrame)
    check(parsedHead != nil, "parseFileHead must succeed on >=97B frame")
    check(parsedHead?.fileId == 888, "parsedHead.fileId must be 888")
    check(parsedHead?.unfinished == true, "parsedHead.unfinished must be true for 0xFFFFFFFF")

    var sliceFrame = Data([0x09, 0xFF, 0x00, 0x00, 0x01, 0x1A, 0x08, 0x56, 0x01])
    var seq0: UInt32 = UInt32(5).littleEndian
    var seq1: UInt32 = UInt32(6).littleEndian
    withUnsafeBytes(of: &seq0) { sliceFrame.append(contentsOf: $0) }
    sliceFrame.append(0x01)
    sliceFrame.append(contentsOf: [UInt8](repeating: 0x78, count: 160))
    sliceFrame.append(0x00)
    withUnsafeBytes(of: &seq1) { sliceFrame.append(contentsOf: $0) }
    sliceFrame.append(0x00)
    sliceFrame.append(contentsOf: [UInt8](repeating: 0x79, count: 160))
    sliceFrame.append(0x00)
    sliceFrame.append(0x00)
    let batch = KoeCore.unpackSlices(sliceFrame)
    check(batch.sliceCount == 2, "unpackSlices must unpack 2 slices")
    check(batch.wireRecordBytes == 332, "wireRecordBytes must be 332")
    check(batch.markedSequences == [5], "markedSequences must contain [5]")
    check(batch.opusBytes.count == 320 && batch.opusBytes[0] == 0x78 && batch.opusBytes[160] == 0x79, "opusBytes must concatenate both 160B frames")

    let startTransport = KoeCore.encodeStartTransportAudioFile(fileId: 42, alreadyTransferred: 3320, realtimeFlag: 0)
    check(startTransport.count == 19 && KoeCore.verifyChecksum(startTransport), "encodeStartTransportAudioFile must emit valid 19B frame")
    check(Array(startTransport[9..<13]) == [0xF8, 0x0C, 0x00, 0x00], "alreadyTransferred 3320 must be encoded at payload offset 0..4")
    check(Array(startTransport[13..<17]) == [0x2A, 0x00, 0x00, 0x00], "fileId 42 must be encoded at payload offset 4..8")
    let derivedKey = KoeCore.hkdfSha256(ikm: Data(repeating: 0xAB, count: 32))
    check(derivedKey.count == 32, "hkdfSha256 must derive 32-byte session key")
    check(KoeCore.isSliceMark(0x01) && !KoeCore.isSliceMark(0x00), "isSliceMark must check bit 0")
    check(KoeCore.sliceMarkPositionMs(50) == 1000, "sliceMarkPositionMs(50) must equal 1000ms")

    var reassembler = D3200FrameReassembler()
    let splitA = Data([0xDE, 0xAD]) + rxPacket.prefix(12)
    let splitB = rxPacket.dropFirst(12)
    check(reassembler.ingest(splitA).isEmpty, "partial BLE notification must wait for remainder")
    let reassembled = reassembler.ingest(Data(splitB))
    check(reassembled.count == 1 && reassembled[0].cmdType == 0x01 && reassembled[0].cmdId == 0x01, "reassembler must emit verified 0x01/0x01 frame")

    let sessionHandle = KoeTransportSession()
    let badReply = Data(repeating: 0xAA, count: 97)
    let mismatchSecret = Data(repeating: 0xBB, count: 32)
    check(!sessionHandle.acceptEcdhReply(replyPayload: badReply, sharedSecret: mismatchSecret), "acceptEcdhReply must reject mismatched shared secret")
    var goodReply = Data(repeating: 0x11, count: 65)
    goodReply.append(mismatchSecret)
    check(sessionHandle.acceptEcdhReply(replyPayload: goodReply, sharedSecret: mismatchSecret), "acceptEcdhReply must accept matching shared secret")

    let pullTx = sessionHandle.beginOfflinePull(fileId: 500, durationMs: 2_000)
    check(pullTx.count == 19, "beginOfflinePull must return 19-byte 1A/07 TX frame")
    let w1 = sessionHandle.pollTimers(elapsedMs: 5_000, nowEpochSec: 1_700_000_010)
    check(w1.transferPhase == 2 && w1.transferRetryCount == 1 && w1.outboundTxFrames.count == 1, "first 5s watchdog timeout must retry once")
    let w2 = sessionHandle.pollTimers(elapsedMs: 5_000, nowEpochSec: 1_700_000_015)
    check(w2.transferPhase == 2 && w2.transferRetryCount == 2 && w2.outboundTxFrames.count == 1, "second 5s watchdog timeout must retry twice")
    let w3 = sessionHandle.pollTimers(elapsedMs: 5_000, nowEpochSec: 1_700_000_020)
    check(w3.transferPhase == 4 && w3.transferErrorCode == 0xFE && w3.transferRetryCount == 2, "third 5s watchdog timeout must fail with 0xFE")

    let drainSession = KoeTransportSession()
    var liveHeadPayload = Data()
    var liveFid: UInt32 = UInt32(9002).littleEndian
    var liveSize: UInt32 = UInt32.max.littleEndian
    withUnsafeBytes(of: &liveFid) { liveHeadPayload.append(contentsOf: $0) }
    withUnsafeBytes(of: &liveSize) { liveHeadPayload.append(contentsOf: $0) }
    liveHeadPayload.append(contentsOf: [UInt8](repeating: 0x11, count: 16))
    liveHeadPayload.append(contentsOf: [UInt8](repeating: 0x22, count: 46))
    liveHeadPayload.append(contentsOf: [UInt8](repeating: 0x33, count: 16))
    liveHeadPayload.append(0)
    var liveHeadRx = Data([0x09, 0xFF, 0x00, 0x00, 0x01, 0x1A, 0x07, UInt8((10 + liveHeadPayload.count) & 0xFF), 0x00])
    liveHeadRx.append(liveHeadPayload)
    liveHeadRx.append(KoeCore.checksum(liveHeadRx))
    _ = drainSession.ingestBleChunk(liveHeadRx, nowEpochSec: 1_700_000_100)

    var liveSlicePayload = Data()
    var liveSeq0: UInt32 = UInt32(0).littleEndian
    withUnsafeBytes(of: &liveSeq0) { liveSlicePayload.append(contentsOf: $0) }
    liveSlicePayload.append(0x01)
    liveSlicePayload.append(padded160)
    liveSlicePayload.append(0x00)
    let liveSliceTotalLen = UInt16(10 + liveSlicePayload.count)
    var liveSliceRx = Data([
      0x09, 0xFF, 0x00, 0x00, 0x01, 0x1A, 0x08,
      UInt8(liveSliceTotalLen & 0xFF), UInt8((liveSliceTotalLen >> 8) & 0xFF),
    ])
    liveSliceRx.append(liveSlicePayload)
    liveSliceRx.append(KoeCore.checksum(liveSliceRx))
    _ = drainSession.ingestBleChunk(liveSliceRx, nowEpochSec: 1_700_000_100)

    let stopStep = drainSession.stopRealtimeRecording()
    check(stopStep.isRealtimeQuietDraining && stopStep.outboundTxFrames.count == 1, "stopRealtimeRecording must enter 2s quiet-drain window and emit pauseRecord")
    let drainMid = drainSession.pollTimers(elapsedMs: 1_200, nowEpochSec: 1_700_000_101)
    check(!drainMid.hasFinalizedRecording && drainMid.isRealtimeQuietDraining, "1200ms into quiet drain must not finalize early")
    let drainEnd = drainSession.pollTimers(elapsedMs: 800, nowEpochSec: 1_700_000_102)
    check(drainEnd.hasFinalizedRecording && !drainEnd.isRealtimeQuietDraining, "2000ms total quiet drain must finalize recording")
    let drainedModel = drainSession.takeFinalized()
    check(drainedModel?.entry.id == 9002 && drainedModel?.entry.marksMs == [0], "finalized quiet-drained recording must preserve id and mark")

    check(D3200CoreBluetoothBridge.restoreIdentifier == "com.anker.koe.d3200.central", "CoreBluetooth restoreIdentifier must match")
    check(D3200CoreBluetoothBridge.lastPeripheralUUIDDefaultsKey == "koe.ble.last_peripheral_uuid", "lastPeripheralUUIDDefaultsKey must match")
    check(!D3200CoreBluetoothBridge.supportsStateRestoration(), "unbundled test binary must disable CoreBluetooth state restoration")
    check(D3200CoreBluetoothBridge.makeCentralOptions() == nil, "makeCentralOptions must return nil in unbundled CLI")
    let sampleUUID = UUID()
    let restoredIds = D3200CoreBluetoothBridge.restoredPeripheralIdentifiers(
      from: ["kCBRestoredPeripherals": [sampleUUID]]
    )
    check(restoredIds == [sampleUUID], "restoredPeripheralIdentifiers must extract restored UUIDs")

    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("koe-native-host-test-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let actor = BeanTransportActor()
    let saved = await actor.simulateBeanRealtimePipeline(destinationDirectory: tempDir)
    check(saved != nil, "simulateBeanRealtimePipeline must produce a KoeSavedRecording")
    if let saved {
      check(saved.id.rawValue == "20261107", "saved recording id must match simulated fileId")
      check(saved.marks.map(\.sequence) == [15, 45], "saved recording marks must extract sequences [15, 45]")
      check(saved.marks.map(\.rawValue) == [300, 900], "saved recording mark timestamps must be [300, 900] ms")
      let opusBytes = (try? Data(contentsOf: saved.opusFileURL)) ?? Data()
      check(opusBytes.count > 64 && String(decoding: opusBytes.prefix(4), as: UTF8.self) == "OggS", "saved .opus file must start with OggS")
      if let wavURL = saved.playableWAVURL {
        let wavBytes = (try? Data(contentsOf: wavURL)) ?? Data()
        check(
          wavBytes.count == 44 + 60 * 960 * 2 && String(decoding: wavBytes.prefix(4), as: UTF8.self) == "RIFF",
          "saved .wav file must be 115,244 bytes of decoded 48 kHz RIFF WAV"
        )
      } else {
        check(false, "saved recording must include playableWAVURL")
      }

      let liveSession = KoeTransportSession()
      let liveStep = liveSession.simulateRealtimePipeline(nowEpochSec: 1_700_000_000)
      check(liveStep.livePcm16BytesAvailable == 38_400, "simulateRealtimePipeline must report 38,400 bytes of 16 kHz live PCM16")
      let livePcm = liveSession.takeLivePcm16()
      check(livePcm.count == 38_400, "takeLivePcm16 must drain 38,400 bytes")

      await MainActor.run {
        let host = KoeNativeHost(transport: actor, exportDirectory: tempDir)
        host.interpreting.ttsEnabled = false
        host.playback.ingestRecording(saved)
        check(host.playback.selectedRecordingId == saved.id, "ingestRecording must select the new recording")

        host.playback.jumpToMark(direction: .next)
        check(host.playback.playbackState.positionMs == 300, "first jumpToMark(.next) must land on 300ms")
        host.playback.jumpToMark(direction: .next)
        check(host.playback.playbackState.positionMs == 900, "second jumpToMark(.next) must land on 900ms")
        host.playback.jumpToMark(direction: .previous)
        check(host.playback.playbackState.positionMs == 300, "jumpToMark(.previous) must return to 300ms")

        host.playback.moveToTrash(saved.id)
        check(host.playback.recordings.isEmpty, "moveToTrash must remove recording immediately without modal")
        check(host.playback.recentlyTrashed?.id == saved.id, "recentlyTrashed must hold removed recording")
        host.playback.undoTrash()
        check(host.playback.recordings.count == 1 && host.playback.recordings[0].id == saved.id, "undoTrash must restore recording")

        for seg in saved.transcriptSegments {
          host.interpreting.ingestSegment(seg)
        }
        check(host.interpreting.segments.count == 2, "LiveInterpretingModel must store 2 bilingual segments")
      }
      await actor.finishStream()
    }

    var wifiConfigRx = Data([
      0x09, 0xFF, 0x00, 0x00, 0x01, 0x1A, 0x05, 0x10, 0x00,
      1, 4, 168, 192, 0x02, 0x7D,
    ])
    wifiConfigRx.append(KoeCore.checksum(wifiConfigRx))
    let parsedEp = KoeCore.parseWifiConfigResponse(wifiConfigRx)
    check(parsedEp?.ip == [192, 168, 4, 1] && parsedEp?.port == 32002 && parsedEp?.ipString == "192.168.4.1", "parseWifiConfigResponse must decode reverse IPv4 and LE port 32002")
    check(KoeCore.sharesIpv4Subnet(deviceIp: [192, 168, 4, 1], localIp: [192, 168, 4, 2]), "sharesIpv4Subnet must match /24")
    check(!KoeCore.sharesIpv4Subnet(deviceIp: [192, 168, 4, 1], localIp: [192, 168, 4, 1]), "sharesIpv4Subnet must reject identical host")
    let reqHex = KoeCore.buildWifiFileRequestHex(fileId: 1001, alreadyTransferred: 0)
    check(reqHex.count == 36 && reqHex.hasPrefix("08ee0000001a071200") && reqHex.hasSuffix("1b"), "buildWifiFileRequestHex must emit 36-char lowercase hex ending with 1b")
    check(KoeCore.wifiTransferCompleteHex() == "08ee0000001a0a0b000126", "wifiTransferCompleteHex must match 22-char hex")
    check(String(decoding: KoeCore.wifiKeepalivePayload(), as: UTF8.self) == "soundcore-keep-alive-unicast", "wifiKeepalivePayload must be 28-byte keep-alive")

    let wifiSession = KoeTransportSession()
    _ = wifiSession.ingestBleChunk(wifiConfigRx, nowEpochSec: 1_700_000_200)
    check(wifiSession.currentWifiEndpoint()?.ipString == "192.168.4.1" && wifiSession.currentWifiEndpoint()?.port == 32002, "ingestBleChunk(1A/05) must store wifiEndpoint on session")

    check(wifiSession.beginWifiBatch(fileIds: [701, 702, 703]), "beginWifiBatch must start batch")
    check(wifiSession.popOutboundWifiWs() == KoeCore.buildWifiFileRequestHex(fileId: 701, alreadyTransferred: 0), "beginWifiBatch must queue WS 1A/07 request for 701")
    check(wifiSession.popOutboundWifiUdp() == KoeCore.wifiKeepalivePayload(), "beginWifiBatch must queue initial UDP keepalive")

    func makeShortHead(fileId: UInt32, fileSize: UInt32, errorCode: UInt8 = 0) -> Data {
      var frame = Data([0x09, 0xFF, 0x00, 0x00, 0x01, 0x1A, 0x07, 0x12, 0x00])
      var fid = fileId.littleEndian
      var fsize = fileSize.littleEndian
      withUnsafeBytes(of: &fid) { frame.append(contentsOf: $0) }
      withUnsafeBytes(of: &fsize) { frame.append(contentsOf: $0) }
      if errorCode != 0 {
        frame.append(contentsOf: [UInt8](repeating: 0, count: 78))
        frame.append(errorCode)
        let total = UInt16(frame.count + 1)
        frame[7] = UInt8(total & 0xFF)
        frame[8] = UInt8((total >> 8) & 0xFF)
      }
      frame.append(KoeCore.checksum(frame))
      return frame
    }

    func makeSingleSlice(seq: UInt32, mark: Bool) -> Data {
      var payload = Data()
      var s = seq.littleEndian
      withUnsafeBytes(of: &s) { payload.append(contentsOf: $0) }
      payload.append(mark ? 0x01 : 0x00)
      payload.append(padded160)
      payload.append(0x00)
      let total = UInt16(10 + payload.count)
      var frame = Data([0x09, 0xFF, 0x00, 0x00, 0x01, 0x1A, 0x08, UInt8(total & 0xFF), UInt8((total >> 8) & 0xFF)])
      frame.append(payload)
      frame.append(KoeCore.checksum(frame))
      return frame
    }

    var doneFrame = Data([0x09, 0xFF, 0x00, 0x00, 0x01, 0x1A, 0x0A, 0x0B, 0x00, 0x00])
    doneFrame.append(KoeCore.checksum(doneFrame))

    let hexHead701 = makeShortHead(fileId: 701, fileSize: 166).map { String(format: "%02x", $0) }.joined()
    _ = wifiSession.ingestWifiChunk(Data(hexHead701.utf8), nowEpochSec: 1_700_000_201)
    let step701 = wifiSession.ingestWifiChunk(makeSingleSlice(seq: 0, mark: true), nowEpochSec: 1_700_000_201)
    check(step701.hasFinalizedRecording, "file 701 must finalize immediately on reaching expected_wire_bytes")
    check(wifiSession.popOutboundWifiWs() == KoeCore.buildWifiFileRequestHex(fileId: 702, alreadyTransferred: 0), "completing 701 must advance to 702")

    let step702 = wifiSession.ingestWifiChunk(makeShortHead(fileId: 702, fileSize: 166, errorCode: 1), nowEpochSec: 1_700_000_202)
    check(step702.transferUpdated && wifiSession.currentWifiBatchProgress().skippedCount == 1, "error_code 1 on 702 must skip and advance")
    check(wifiSession.popOutboundWifiWs() == KoeCore.buildWifiFileRequestHex(fileId: 703, alreadyTransferred: 0), "skipping 702 must advance to 703")

    _ = wifiSession.ingestWifiChunk(makeShortHead(fileId: 703, fileSize: 332), nowEpochSec: 1_700_000_203)
    _ = wifiSession.ingestWifiChunk(doneFrame, nowEpochSec: 1_700_000_203)
    check(wifiSession.currentWifiBatchProgress().phase == 2, "stale 1A/0A before slices must be ignored")
    _ = wifiSession.ingestWifiChunk(makeSingleSlice(seq: 0, mark: false), nowEpochSec: 1_700_000_203)
    _ = wifiSession.ingestWifiChunk(doneFrame, nowEpochSec: 1_700_000_203)
    check(wifiSession.currentWifiBatchProgress().phase == 2, "premature 1A/0A at 166/332 bytes must be ignored")
    _ = wifiSession.ingestWifiChunk(makeSingleSlice(seq: 1, mark: true), nowEpochSec: 1_700_000_204)
    let progDone = wifiSession.currentWifiBatchProgress()
    check(progDone.phase == 4 && progDone.finalizedCount == 2 && progDone.skippedCount == 1, "batch must complete with 2 finalized and 1 skipped")
    check(wifiSession.popOutboundWifiWs() == "FINISH", "completed batch must emit FINISH first")
    check(wifiSession.popOutboundWifiWs() == KoeCore.wifiTransferCompleteHex(), "completed batch must emit 1A/0A hex second")
    let fin701 = wifiSession.takeFinalized()
    let fin703 = wifiSession.takeFinalized()
    check(fin701?.entry.id == 701 && fin703?.entry.id == 703 && wifiSession.takeFinalized() == nil, "takeFinalized must drain both 701 and 703 in FIFO order")

    let wifiHostDir = FileManager.default.temporaryDirectory.appendingPathComponent("koe-wifi-host-test-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: wifiHostDir) }
    let wifiActor = BeanTransportActor()
    let wifiHost = await MainActor.run {
      let h = KoeNativeHost(transport: wifiActor, exportDirectory: wifiHostDir)
      h.interpreting.ttsEnabled = false
      return h
    }
    await wifiActor.ingestRawBleChunk(wifiConfigRx, destinationDirectory: wifiHostDir)
    for _ in 0..<200 {
      let hasEp = await MainActor.run { wifiHost.sidebar.wifiEndpoint?.ipString == "192.168.4.1" }
      if hasEp { break }
      try? await Task.sleep(nanoseconds: 5_000_000)
    }
    let hostEp = await MainActor.run { wifiHost.sidebar.wifiEndpoint }
    check(hostEp?.ipString == "192.168.4.1" && hostEp?.port == 32002, "BeanSidebarModel must receive wifiEndpointUpdated from 1A/05")

    await MainActor.run {
      wifiHost.sidebar.startWifiBatch(fileIds: [901])
      wifiHost.sidebar.ingestWifiChunk(makeShortHead(fileId: 901, fileSize: 166))
      wifiHost.sidebar.ingestWifiChunk(makeSingleSlice(seq: 0, mark: true))
    }
    for _ in 0..<200 {
      let ready = await MainActor.run {
        wifiHost.playback.recordings.contains(where: { $0.id.rawValue == "901" })
          && wifiHost.sidebar.wifiBatchProgress?.phase == 4
      }
      if ready { break }
      try? await Task.sleep(nanoseconds: 5_000_000)
    }
    await MainActor.run {
      check(wifiHost.sidebar.wifiBatchProgress?.phase == 4 && wifiHost.sidebar.wifiBatchProgress?.finalizedCount == 1, "BeanSidebarModel wifiBatchProgress must reach phase 4 with finalizedCount == 1")
      check(wifiHost.playback.recordings.count == 1 && wifiHost.playback.recordings[0].id.rawValue == "901", "KoeNativeHost playback.recordings must include Wi-Fi batch recording 901")
    }
    await wifiActor.finishStream()

    let spine = KoeUtteranceSpine(sessionId: "swift-spine-test")
    check(spine.snapshot().segmentCount == 0 && spine.snapshot().revision == 0 && !spine.snapshot().isStale, "new KoeUtteranceSpine must start empty and non-stale")
    let s1 = spine.appendSegment(text: "基本工资是3910元。", startMs: 0, endMs: 2_000, sourceLanguage: "zh", provider: "qwen")
    let s2 = spine.appendSegment(text: "绩效发放比例按80%计算。", startMs: 2_000, endMs: 4_000, sourceLanguage: "zh", provider: "qwen")
    check(s1 == 1 && s2 == 2, "appendSegment must assign 1-based ordinals S1 and S2")
    check(spine.segment(ordinal: 1)?.id == "S1" && spine.segment(ordinal: 1)?.text == "基本工资是3910元。", "segment(1) must return S1 text")
    check(spine.setTranslation(ordinal: 1, translation: "Base salary is 3910 CNY.", targetLanguage: "en"), "setTranslation must succeed on S1")
    check(spine.segment(ordinal: 1)?.translation == "Base salary is 3910 CNY.", "segment(1) must expose translation")
    check(spine.updateSegmentText(ordinal: 1, newText: "基本工资调整为4200元。"), "updateSegmentText must succeed on S1")
    check(spine.snapshot().isStale, "updateSegmentText must mark spine stale")
    check(spine.segment(ordinal: 1)?.revision == 2 && spine.segment(ordinal: 1)?.translation == nil, "updateSegmentText must increment segment revision and invalidate stale translation")
    spine.clearStale()
    check(!spine.snapshot().isStale, "clearStale must reset stale flag")
    let s3 = spine.acceptCumulative(connectionId: "conn-1", text: "所以实发工资按4200元乘以80%发放。", sourceLanguage: "zh", translation: "Net pay is 4200 * 80%.", targetLanguage: "en", provider: "qwen")
    let s4 = spine.acceptCumulative(connectionId: "conn-1", text: "所以实发工资按4200元乘以80%发放。 下月生效。", sourceLanguage: "zh", translation: "Effective next month.", targetLanguage: "en", provider: "qwen")
    check(s3 == 3 && s4 == 4 && spine.segment(ordinal: 4)?.text == "下月生效。", "acceptCumulative must strip confirmed prefix and append only delta as S4")
    check(spine.formatCitedSources().contains("[S1] 基本工资调整为4200元。") && spine.formatCitedSources().contains("[S4] 下月生效。"), "formatCitedSources must format [S1]..[S4] lines")
    check(!spine.validateClaimGrounding(claim: "实发工资按4200元乘以80%计算", citations: [1, 2]), "validateClaimGrounding must reject cross-segment wage+percentage stitching across S1 and S2")
    check(spine.validateClaimGrounding(claim: "实发工资按4200元乘以80%计算", citations: [3]), "validateClaimGrounding must accept single-segment grounded calculation on S3")
  }
}
