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
    rxPacket.append(1) // connectStatus = 1
    rxPacket.append(4) // battery bucket 4 -> 50%
    rxPacket.append(1) // charging = true
    rxPacket.append(contentsOf: Array("1.2.3".utf8))
    rxPacket.append(contentsOf: Array("D3200ABCDEF12345".utf8))
    var totalMem: UInt32 = (64 * 1024 * 1024).littleEndian
    var freeMem: UInt32 = (60 * 1024 * 1024).littleEndian
    withUnsafeBytes(of: &totalMem) { rxPacket.append(contentsOf: $0) }
    withUnsafeBytes(of: &freeMem) { rxPacket.append(contentsOf: $0) }
    rxPacket.append(0) // boxCharging = false
    rxPacket.append(contentsOf: Array("2.0.1".utf8))
    rxPacket.append(8) // boxBattery bucket 8 -> 90%
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
  }
}
