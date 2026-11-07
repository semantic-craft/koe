import Foundation

@main
struct KoeCoreSwiftTest {
  static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
      fputs("FAIL: \(message)\n", stderr)
      exit(1)
    }
  }

  static func main() {
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

    let startTransport = KoeCore.encodeStartTransportAudioFile(fileId: 42, alreadyTransferred: 166, realtimeFlag: 1)
    check(startTransport.count == 19 && KoeCore.verifyChecksum(startTransport), "encodeStartTransportAudioFile must emit valid 19B frame")
    let derivedKey = KoeCore.hkdfSha256(ikm: Data(repeating: 0xAB, count: 32))
    check(derivedKey.count == 32, "hkdfSha256 must derive 32-byte session key")
    check(KoeCore.isSliceMark(0x01) && !KoeCore.isSliceMark(0x00), "isSliceMark must check bit 0")
    check(KoeCore.sliceMarkPositionMs(50) == 1000, "sliceMarkPositionMs(50) must equal 1000ms")
  }
}
