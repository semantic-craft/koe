import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:koe/audio/ogg_opus.dart';
import 'package:koe/audio/opus_wave.dart';
import 'package:koe/crypto/device_crypto.dart';
import 'package:koe/native/koe_core_ffi.dart';
import 'package:koe/protocol/frame.dart';

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
}
