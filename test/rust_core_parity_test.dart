import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:koe/audio/ogg_opus.dart';
import 'package:koe/audio/opus_wave.dart';
import 'package:koe/crypto/device_crypto.dart';
import 'package:koe/native/koe_core_ffi.dart';
import 'package:koe/protocol/commands.dart';
import 'package:koe/protocol/frame.dart';
import 'package:koe/protocol/models.dart';
import 'package:koe/protocol/slice_marks.dart';

void main() {
  test('Rust FFI kernel is loaded and matches protocol, crypto, Ogg, and WAV outputs across 20 seeds', () {
    final ffi = KoeCoreFfi.instance;
    expect(ffi, isNotNull, reason: 'libkoe_core_ffi native library must be loaded');
    expect(ffi!.isAvailable, isTrue);

    for (var seed = 0; seed < 20; seed++) {
      final payload = Uint8List.fromList(
        List<int>.generate((seed % 32) + 4, (i) => (seed * 31 + i * 17) & 0xFF),
      );
      final encoded = ProtocolFrame.encode(
        cmdType: 0x1A,
        cmdId: 0x07,
        payload: payload,
      );
      expect(ProtocolFrame.verifyChecksum(encoded), isTrue);
      expect(
        encoded,
        equals(
          ffi.protocolEncode(cmdType: 0x1A, cmdId: 0x07, payload: payload),
        ),
      );

      final rxBody = <int>[
        0x09,
        0xFF,
        0x00,
        0x00,
        0x01,
        0x1A,
        0x07,
        (10 + payload.length) & 0xFF,
        ((10 + payload.length) >> 8) & 0xFF,
        ...payload,
      ];
      final rxPkt = [...rxBody, ProtocolFrame.checksum(rxBody)];
      final stream = <int>[0xDE, 0xAD, ...rxPkt, 0x09, 0xFF];
      final packets = ProtocolFrame.processBuffer(stream);
      expect(packets, hasLength(1));
      expect(packets.single.payload, equals(payload));
      expect(stream, equals([0x09, 0xFF]));

      final ikm = Uint8List.fromList(
        List<int>.generate(32, (i) => (seed + i * 7) & 0xFF),
      );
      final salt = Uint8List.fromList([1, 2, 3]);
      final info = Uint8List.fromList([1, 2, 3]);
      final sessionKey = DeviceCrypto.hkdfSha256(
        ikm: ikm,
        salt: salt,
        info: info,
        length: 32,
      );
      expect(
        sessionKey,
        equals(
          ffi.hkdfSha256(ikm: ikm, salt: salt, info: info, length: 32),
        ),
      );

      final nonce = Uint8List.fromList(
        List<int>.generate(16, (i) => (seed * 3 + i) & 0xFF),
      );
      final chunk = Uint8List.fromList(
        List<int>.generate(160, (i) => ((seed + 1) * (i + 3)) & 0xFF),
      );
      final streamDec = AesCtrStreamDecrypt(fileKey: sessionKey, nonce: nonce);
      final dec = streamDec.decryptChunk(chunk, seed);
      expect(dec, isNotNull);
      final roundTrip = streamDec.decryptChunk(dec!, seed);
      expect(roundTrip, equals(chunk));

      final rawOpus = Uint8List((seed + 3) * OggOpus.frameSize);
      for (var f = 0; f < seed + 3; f++) {
        rawOpus[f * OggOpus.frameSize] = 0x78;
        for (var j = 1; j < OggOpus.frameSize - (f % 5); j++) {
          rawOpus[f * OggOpus.frameSize + j] = (f + j + seed) & 0xFF;
        }
      }
      final ogg = OggOpus.muxRawFrames(rawOpus);
      expect(OggOpus.isOgg(ogg), isTrue);
      expect(ogg, equals(ffi.oggOpusMuxRawFrames(rawOpus)));

      final wavHdr = OpusWave.buildWavHeader((seed + 1) * 1920);
      expect(OggOpus.isWav(wavHdr), isTrue);
      expect(wavHdr, equals(ffi.wavHeader((seed + 1) * 1920)));
    }
  });

  test('DeviceCrypto batch contiguous stream decrypt matches per-chunk decrypt', () {
    final a = DeviceCrypto();
    final b = DeviceCrypto();
    final pubA = a.ensureKeyPair();
    final pubB = b.ensureKeyPair();
    final shared = a.computeEcdhShared(pubB)!;
    expect(b.computeEcdhShared(pubA), equals(shared));
    expect(
      a.completeHandshake(devicePublicKey: pubB, deviceSharedKey: shared),
      isTrue,
    );

    final sessionNonce = Uint8List.fromList(List<int>.generate(16, (i) => i + 1));
    final nonce = Uint8List.fromList(List<int>.generate(16, (i) => i + 17));
    final fileKey = Uint8List.fromList(List<int>.generate(32, (i) => i + 33));
    final plainKey = Uint8List.fromList([
      ...utf8.encode(DeviceCrypto.fileKeyMagic),
      ...fileKey,
    ]);
    final encKey = DeviceCrypto.aesCtrDecrypt(
      data: plainKey,
      key: a.sessionKey!,
      iv: sessionNonce,
    )!;
    expect(
      a.initFileDecrypt(
        fileId: 'batch-1',
        encryptedFileKey: encKey,
        sessionNonce: sessionNonce,
        nonce: nonce,
      ),
      isTrue,
    );

    const numChunks = 8;
    final contiguous = Uint8List.fromList(
      List<int>.generate(numChunks * 160, (i) => (i * 13 + 7) & 0xFF),
    );
    final batchDec = a.decryptContiguousChunks(
      fileId: 'batch-1',
      startSequence: 0,
      data: contiguous,
    );
    expect(batchDec, isNotNull);

    final perChunk = BytesBuilder(copy: false);
    for (var seq = 0; seq < numChunks; seq++) {
      perChunk.add(
        a.decryptChunk(
          fileId: 'batch-1',
          sequence: seq,
          data: Uint8List.sublistView(contiguous, seq * 160, (seq + 1) * 160),
        )!,
      );
    }
    expect(batchDec, equals(perChunk.toBytes()));
  });

  test('Rust FFI matches DeviceInfoModel, OfflineFileList, and SliceMarkProbe across 20 seeds', () {
    final ffi = KoeCoreFfi.instance!;
    for (var seed = 0; seed < 20; seed++) {
      expect(
        DeviceInfoModel.batteryRemaining(seed),
        equals(ffi.batteryRemaining(seed)),
      );
      final packet = Uint8List.fromList([
        0x09, 0xFF, 0x00, 0x00, 0x01, 0x01, 0x01, 0x36, 0x00,
        seed % 2,
        seed % 10,
        (seed + 1) % 2,
        ...utf8.encode('1.${seed % 9}.0'),
        ...utf8.encode('D3200SN${seed.toString().padLeft(9, '0')}'),
        0x00, 0x00, 0x04, 0x00,
        0x00, 0x00, 0x02, 0x00,
        seed % 2,
        ...utf8.encode('2.${seed % 9}.1'),
        (seed + 3) % 10,
        0xAA, 0xBB, 0xCC, 0xDD, 0xEE, (seed + 1) & 0xFF,
        0x00,
      ]);
      final info = DeviceInfoModel.parsePacket(packet);
      final ffiInfo = ffi.parseDeviceInfoPacket(packet);
      expect(info.connectStatus, equals(ffiInfo.connectStatus));
      expect(info.battery, equals(ffiInfo.battery));
      expect(info.charging, equals(ffiInfo.charging));
      expect(info.firmwareVersion, equals(ffiInfo.firmwareVersion));
      expect(info.serialNumber, equals(ffiInfo.serialNumber));
      expect(info.totalMemoryKb, equals(ffiInfo.totalMemoryKb));
      expect(info.freeMemoryKb, equals(ffiInfo.freeMemoryKb));
      expect(info.boxBattery, equals(ffiInfo.boxBattery));
      expect(info.boxCharging, equals(ffiInfo.boxCharging));
      expect(info.boxMac, equals(ffiInfo.boxMac));
      expect(info.boxFirmware, equals(ffiInfo.boxFirmware));

      final fileListPayload = Uint8List.fromList([
        2, 0,
        ...u32Le(1000 + seed),
        ...u32Le(2000 + seed),
        ...u32Le(3000 + seed * 20),
        ...u32Le(4000 + seed),
        ...u32Le(5000 + seed),
        ...u32Le(6000 + seed * 20),
        ...u32Le(7000 + seed),
        ...u32Le(8000 + seed),
      ]);
      final page = OfflineFileList.parse(fileListPayload, withEndTime: true);
      final ffiPage = ffi.parseOfflineFileList(
        fileListPayload,
        withEndTime: true,
      );
      expect(page.fileCount, equals(ffiPage.fileCount));
      expect(page.files.length, equals(ffiPage.files.length));
      for (var i = 0; i < page.files.length; i++) {
        expect(page.files[i].fileId, equals(ffiPage.files[i].fileId));
        expect(page.files[i].durationMs, equals(ffiPage.files[i].durationMs));
        expect(page.files[i].endTime, equals(ffiPage.files[i].endTime));
      }
      expect(
        page.currentTransportTimestamp,
        equals(ffiPage.currentTransportTimestamp),
      );
      expect(
        page.currentTransportDuration,
        equals(ffiPage.currentTransportDuration),
      );

      final sliceBody = <int>[
        0x09, 0xFF, 0x00, 0x00, 0x01, 0x1A, RxCmd.fileSliceId, 0x56, 0x01,
        ...u32Le(seed),
        0x01,
        ...List<int>.filled(161, 0),
        ...u32Le(seed + 1),
        0x00,
        ...List<int>.filled(161, 0),
      ];
      final slicePkt = DecodedPacket.fromBytes([
        ...sliceBody,
        ProtocolFrame.checksum(sliceBody),
      ]);
      final probe = SliceMarkProbe();
      final lines = probe.inspect(
        slicePkt,
        at: DateTime.utc(2026, 11, 7, 12, 0, seed),
      );
      expect(lines, hasLength(2));
      expect(lines.first, contains('seq=$seed flags=0x01'));
      expect(lines.last, contains('seq=${seed + 1} flags=0x00'));
    }
  });
}
