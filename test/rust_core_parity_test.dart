import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:koe/ai/qwen_stt.dart';
import 'package:koe/audio/ogg_opus.dart';
import 'package:koe/audio/opus_wave.dart';
import 'package:koe/crypto/device_crypto.dart';
import 'package:koe/native/koe_core_ffi.dart';
import 'package:koe/protocol/commands.dart';
import 'package:koe/protocol/frame.dart';
import 'package:koe/protocol/models.dart';
import 'package:koe/protocol/slice_marks.dart';
import 'package:koe/state/context/ask_retrieval.dart';
import 'package:koe/state/context/commitments.dart';
import 'package:koe/state/meeting_minutes.dart';
import 'package:koe/state/recorder_controller.dart';

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

  test('Rust FFI batch 1A07 file head and 1A08 slice unpacker match Dart across 20 seeds', () {
    final ffi = KoeCoreFfi.instance!;
    final crypto = DeviceCrypto();
    crypto.sessionKey = Uint8List.fromList(
      List<int>.generate(32, (i) => (i * 5 + 3) & 0xFF),
    );

    for (var seed = 0; seed < 20; seed++) {
      final sessionNonce = Uint8List.fromList(
        List<int>.generate(16, (i) => (seed + i) & 0xFF),
      );
      final fileNonce = Uint8List.fromList(
        List<int>.generate(16, (i) => (seed * 3 + i + 1) & 0xFF),
      );
      final rawFileKey = Uint8List.fromList(
        List<int>.generate(32, (i) => (seed * 11 + i + 7) & 0xFF),
      );
      final plainKeyMaterial = Uint8List.fromList([
        ...utf8.encode(DeviceCrypto.fileKeyMagic),
        ...rawFileKey,
      ]);
      final encFileKey = DeviceCrypto.aesCtrDecrypt(
        data: plainKeyMaterial,
        key: crypto.sessionKey!,
        iv: sessionNonce,
      )!;

      final headFrame = Uint8List.fromList([
        0x09, 0xFF, 0x00, 0x00, 0x01, 0x1A, 0x07, 0x62, 0x00,
        ...u32Le(5000 + seed),
        ...u32Le(166 * (seed + 2)),
        ...fileNonce,
        ...encFileKey,
        ...sessionNonce,
        0x00,
        0x00,
      ]);
      final parsedSecret = AudioFileSecretKey.parseFrame(headFrame)!;
      final ffiHead = ffi.parseFileHead(
        headFrame,
        sessionKey: crypto.sessionKey,
      )!;
      expect(parsedSecret.fileId, equals(ffiHead.secret.fileId));
      expect(parsedSecret.fileSize, equals(ffiHead.secret.fileSize));
      expect(parsedSecret.nonce, equals(ffiHead.secret.nonce));
      expect(
        parsedSecret.encryptedFileKey,
        equals(ffiHead.secret.encryptedFileKey),
      );
      expect(parsedSecret.sessionNonce, equals(ffiHead.secret.sessionNonce));
      expect(ffiHead.fileKey, equals(rawFileKey));

      final fileIdStr = '${5000 + seed}';
      expect(
        crypto.initFileDecrypt(
          fileId: fileIdStr,
          encryptedFileKey: encFileKey,
          sessionNonce: sessionNonce,
          nonce: fileNonce,
        ),
        isTrue,
      );

      final plain0 = Uint8List.fromList(
        List<int>.generate(160, (i) => (seed + i * 3) & 0xFF),
      );
      final plain1 = Uint8List.fromList(
        List<int>.generate(160, (i) => (seed * 7 + i) & 0xFF),
      );
      final enc0 = crypto.decryptChunk(
        fileId: fileIdStr,
        sequence: seed * 2,
        data: plain0,
      )!;
      final enc1 = crypto.decryptChunk(
        fileId: fileIdStr,
        sequence: seed * 2 + 1,
        data: plain1,
      )!;

      final sliceFrame = Uint8List.fromList([
        0x09, 0xFF, 0x00, 0x00, 0x01, 0x1A, 0x08, 0x56, 0x01,
        ...u32Le(seed * 2),
        0x01,
        ...enc0,
        0x00,
        ...u32Le(seed * 2 + 1),
        0x00,
        ...enc1,
        0x00,
        0x00,
      ]);

      final unpacked = crypto.unpackSliceFrame(
        frame: sliceFrame,
        fileId: fileIdStr,
        decrypt: true,
      );
      expect(unpacked.sliceCount, equals(2));
      expect(unpacked.markedSequences, equals([seed * 2]));
      expect(
        unpacked.opusBytes,
        equals(Uint8List.fromList([...plain0, ...plain1])),
      );
    }
  });

  test('Rust FFI decodes real 20ms 440Hz Opus packet to 16kHz/48kHz PCM16 and WAV', () {
    final ffi = KoeCoreFfi.instance!;
    const opusHex =
        '7881a75d6c9e99ac0000067e5639f73b1ea2dc310f523839'
        '393ea3d08447cbe1b6b8ff44143d7621af0734dd0787ec99'
        'fec0f544189d5f482942ded82f85b618f43b6492de947050'
        'e097687d6c10d0af638553a27165e791290180531504';
    final padded = Uint8List(160);
    for (var i = 0; i < opusHex.length; i += 2) {
      padded[i ~/ 2] = int.parse(opusHex.substring(i, i + 2), radix: 16);
    }

    final pcm16k = ffi.decodeOpusPcm16(padded, sampleRate: 16000);
    expect(pcm16k, isNotNull);
    expect(pcm16k!.length, equals(640));
    final sample130 = ByteData.sublistView(pcm16k).getInt16(130 * 2, Endian.little);
    expect(sample130, closeTo(-4130, 16));

    final pcm48k = ffi.decodeOpusPcm16(padded, sampleRate: 48000);
    expect(pcm48k, isNotNull);
    expect(pcm48k!.length, equals(1920));

    final wav48k = ffi.decodeOpusWav(padded, sampleRate: 48000, marksMs: const [0]);
    expect(wav48k, isNotNull);
    expect(wav48k!.length, equals(44 + 1920));
    expect(OggOpus.isWav(wav48k), isTrue);
  });

  test('Rust FFI unpackSlices skips duplicate sequences and startTransportAudioFile encodes byte offset', () {
    final ffi = KoeCoreFfi.instance!;
    final tx = DeviceCommands.startTransportAudioFile(
      fileId: 42,
      alreadyTransferred: 3320,
      realtimeFlag: 0,
    );
    expect(tx.length, equals(19));
    expect(tx.sublist(9, 13), equals([0xF8, 0x0C, 0x00, 0x00]));
    expect(tx.sublist(13, 17), equals([0x2A, 0x00, 0x00, 0x00]));

    final slice0 = List<int>.filled(160, 0x78);
    final slice1 = List<int>.filled(160, 0x79);
    final dupFrame = Uint8List.fromList([
      0x09, 0xFF, 0x00, 0x00, 0x01, 0x1A, 0x08, 0x00, 0x00,
      ...u32Le(5), 0x01, ...slice0, 0x00,
      ...u32Le(5), 0x01, ...slice0, 0x00,
      ...u32Le(6), 0x00, ...slice1, 0x00,
      0x00,
    ]);
    final unpacked = ffi.unpackSlices(dupFrame);
    expect(unpacked.sliceCount, equals(2));
    expect(unpacked.wireRecordBytes, equals(332));
    expect(unpacked.markedSequences, equals([5]));
    expect(unpacked.opusBytes.length, equals(320));
  });

  test('Rust FFI Wi-Fi SoftAP 1A/05 endpoint parser, subnet check, WS hex commands, and UDP keepalive match Dart', () {
    final ffi = KoeCoreFfi.instance!;
    final raw1a05 = <int>[
      0x09, 0xFF, 0x00, 0x00, 0x01, 0x1A, 0x05, 0x10, 0x00,
      1, 4, 168, 192, 0x02, 0x7D,
    ];
    final pkt1a05 = Uint8List.fromList([
      ...raw1a05,
      ProtocolFrame.checksum(raw1a05),
    ]);
    final ep = ffi.parseWifiConfigResponse(pkt1a05);
    expect(ep, isNotNull);
    expect(ep!.ip, equals('192.168.4.1'));
    expect(ep.port, equals(32002));

    final failed1a05Body = <int>[
      0x09, 0xFF, 0x00, 0x00, 0x02, 0x1A, 0x05, 0x10, 0x00,
      1, 4, 168, 192, 0x02, 0x7D,
    ];
    final failed1a05 = Uint8List.fromList([
      ...failed1a05Body,
      ProtocolFrame.checksum(failed1a05Body),
    ]);
    expect(ffi.parseWifiConfigResponse(failed1a05), isNull);

    expect(ffi.sharesIpv4Subnet([192, 168, 4, 1], [192, 168, 4, 2]), isTrue);
    expect(ffi.sharesIpv4Subnet([192, 168, 4, 1], [192, 168, 4, 1]), isFalse);
    expect(ffi.sharesIpv4Subnet([192, 168, 4, 1], [192, 168, 5, 2]), isFalse);

    final reqHex = ffi.buildWifiFileRequestHex(
      fileId: 0x01020304,
      alreadyTransferred: 332,
    );
    expect(reqHex.length, equals(36));
    expect(reqHex, equals('08ee0000001a0712004c010000040302011b'));
    expect(
      ffi.wifiTransferCompleteHex(),
      equals('08ee0000001a0a0b000126'),
    );
    expect(
      utf8.decode(ffi.wifiKeepalivePayload()),
      equals('soundcore-keep-alive-unicast'),
    );
  });

  test('Rust FFI UtteranceSpine S1..Sn append, cumulative prefix dedup, edit invalidation, and minutes grounding', () {
    final ffi = KoeCoreFfi.instance!;
    final spine = ffi.spineNew(sessionId: 'dart-spine-test');
    try {
      final snap0 = ffi.spineSnapshot(spine);
      expect(snap0.segmentCount, equals(0));
      expect(snap0.revision, equals(0));
      expect(snap0.isStale, isFalse);

      final s1 = ffi.spineAppendSegment(
        handle: spine,
        text: '基本工资是3910元。',
        startMs: 0,
        endMs: 2000,
      );
      final s2 = ffi.spineAppendSegment(
        handle: spine,
        text: '绩效发放比例按80%计算。',
        startMs: 2000,
        endMs: 4000,
      );
      expect(s1, equals(1));
      expect(s2, equals(2));

      expect(
        ffi.spineSetTranslation(
          handle: spine,
          ordinal: 1,
          translation: 'Base salary is 3910 CNY.',
          targetLanguage: 'en',
        ),
        isTrue,
      );
      final seg1Before = ffi.spineGetSegment(handle: spine, ordinal: 1)!;
      expect(seg1Before.citationId, equals('S1'));
      expect(seg1Before.revision, equals(1));
      expect(seg1Before.translation, equals('Base salary is 3910 CNY.'));

      expect(
        ffi.spineUpdateSegmentText(
          handle: spine,
          ordinal: 1,
          newText: '基本工资调整为4200元。',
        ),
        isTrue,
      );
      expect(ffi.spineSnapshot(spine).isStale, isTrue);
      final seg1After = ffi.spineGetSegment(handle: spine, ordinal: 1)!;
      expect(seg1After.revision, equals(2));
      expect(seg1After.text, equals('基本工资调整为4200元。'));
      expect(seg1After.translation, isNull);

      ffi.spineClearStale(spine);
      expect(ffi.spineSnapshot(spine).isStale, isFalse);

      final s3 = ffi.spineAcceptCumulative(
        handle: spine,
        connectionId: 'conn-1',
        text: '所以实发工资按4200元乘以80%发放。',
      );
      final s4 = ffi.spineAcceptCumulative(
        handle: spine,
        connectionId: 'conn-1',
        text: '所以实发工资按4200元乘以80%发放。 下月生效。',
        translation: 'Effective next month.',
        targetLanguage: 'en',
      );
      expect(s3, equals(3));
      expect(s4, equals(4));
      final seg4 = ffi.spineGetSegment(handle: spine, ordinal: 4)!;
      expect(seg4.text, equals('下月生效。'));
      expect(seg4.translation, equals('Effective next month.'));

      final cited = ffi.spineFormatCitedSources(spine);
      expect(cited, contains('[S1] 基本工资调整为4200元。'));
      expect(cited, contains('[S4] 下月生效。'));

      expect(
        ffi.minutesValidateClaimGrounding(
          spineHandle: spine,
          claim: '实发工资按4200元乘以80%计算',
          citations: const [1, 2],
        ),
        isFalse,
      );
      expect(
        ffi.minutesValidateClaimGrounding(
          spineHandle: spine,
          claim: '实发工资按4200元乘以80%计算',
          citations: const [3],
        ),
        isTrue,
      );
    } finally {
      ffi.spineFree(spine);
    }
  });

  test('Rust FFI Slice K Qwen ASR transcript parsing, S1..Sn minutes validation, batch planning, and longest-match term replacement match Dart', () {
    final ffi = KoeCoreFfi.instance!;
    final spine = ffi.spineNew(sessionId: 'slice-k-parity');
    try {
      const qwenRaw = '''
{
  "properties": { "original_duration_in_milliseconds": 4500 },
  "transcripts": [{
    "sentences": [
      { "text": "合同约定基本工资为3910元，深科录音豆记录。", "begin_time": 0, "end_time": 1500, "speaker_id": 0 },
      { "text": "本月出勤率是80%。", "begin_time": 1500, "end_time": 3000, "speaker_id": 1 },
      { "text": "所以实发工资按3910元乘以80%折算。", "begin_time": 3000, "end_time": 4500, "speaker_id": 0 }
    ]
  }]
}
''';
      final dartParsed = parseQwenTranscript(
        jsonDecode(qwenRaw) as Map<String, Object?>,
      );
      expect(dartParsed.segments, hasLength(3));
      final rustCount = ffi.qwenParseTranscriptIntoSpine(
        spineHandle: spine,
        json: qwenRaw,
      );
      expect(rustCount, equals(dartParsed.segments.length));
      for (var i = 0; i < dartParsed.segments.length; i++) {
        final rSeg = ffi.spineGetSegment(handle: spine, ordinal: i + 1)!;
        expect(rSeg.text, equals(dartParsed.segments[i].text));
        expect(rSeg.startMs, equals(dartParsed.segments[i].startMs));
        expect(rSeg.endMs, equals(dartParsed.segments[i].endMs));
      }

      final sourceTexts = [
        for (final s in dartParsed.segments) s.text,
      ];

      const validMinutesJson = '''
{
  "schemaVersion": 2,
  "title": "薪资与深科测试",
  "overview": "确认基本工资与出勤折算。",
  "topics": [
    {
      "text": "实发工资按3910元乘以80%折算",
      "summary": "单句依据充分",
      "sources": ["S3"],
      "points": [
        { "text": "基本工资为3910元", "sources": ["S1"] }
      ]
    }
  ],
  "decisions": [],
  "actions": [],
  "questions": [],
  "terms": [
    { "name": "声刻", "note": "硬件品牌", "heard": ["深科"], "sources": ["S1"] }
  ]
}
''';
      expect(
        MeetingMinutes.parse(
          validMinutesJson,
          sourceTexts.length,
          sourceTexts: sourceTexts,
        ).title,
        equals('薪资与深科测试'),
      );
      expect(
        ffi.minutesValidateJson(spineHandle: spine, json: validMinutesJson),
        equals(1),
      );

      const invalidCiteJson = '''
{
  "schemaVersion": 2,
  "title": "测试",
  "overview": "概述",
  "topics": [{ "text": "越界引用", "sources": ["S9"] }],
  "decisions": [],
  "actions": [],
  "questions": []
}
''';
      expect(
        () => MeetingMinutes.parse(
          invalidCiteJson,
          sourceTexts.length,
          sourceTexts: sourceTexts,
        ),
        throwsFormatException,
      );
      expect(
        ffi.minutesValidateJson(spineHandle: spine, json: invalidCiteJson),
        equals(-1),
      );

      const ungroundedHeardJson = '''
{
  "schemaVersion": 2,
  "title": "测试",
  "overview": "概述",
  "topics": [{ "text": "正常主题", "sources": ["S1"] }],
  "decisions": [],
  "actions": [],
  "questions": [],
  "terms": [
    { "name": "声刻", "note": "品牌", "heard": ["不存在的错词"], "sources": ["S1"] }
  ]
}
''';
      expect(
        () => MeetingMinutes.parse(
          ungroundedHeardJson,
          sourceTexts.length,
          sourceTexts: sourceTexts,
        ),
        throwsFormatException,
      );
      expect(
        ffi.minutesValidateJson(spineHandle: spine, json: ungroundedHeardJson),
        equals(-2),
      );

      const stitchedWageJson = '''
{
  "schemaVersion": 2,
  "title": "测试",
  "overview": "概述",
  "topics": [{ "text": "员工实发工资按3910元乘以80%计算", "sources": ["S1", "S2"] }],
  "decisions": [],
  "actions": [],
  "questions": []
}
''';
      expect(
        () => MeetingMinutes.parse(
          stitchedWageJson,
          sourceTexts.length,
          sourceTexts: sourceTexts,
        ),
        throwsFormatException,
      );
      expect(
        ffi.minutesValidateJson(spineHandle: spine, json: stitchedWageJson),
        equals(-3),
      );

      const baselessRatioJson = '''
{
  "schemaVersion": 2,
  "title": "测试",
  "overview": "概述",
  "topics": [{ "text": "社保缴费基数按80%计算", "sources": ["S1", "S2"] }],
  "decisions": [],
  "actions": [],
  "questions": []
}
''';
      expect(
        () => MeetingMinutes.parse(
          baselessRatioJson,
          sourceTexts.length,
          sourceTexts: sourceTexts,
        ),
        throwsFormatException,
      );
      expect(
        ffi.minutesValidateJson(spineHandle: spine, json: baselessRatioJson),
        equals(-3),
      );

      const sampleText = '深科与深科Work录音豆以及安克创新';
      const replacements = <String, String>{
        '深科': '声刻',
        '深科Work': 'Soundcore Work',
        '声刻': '被二次替换则错',
      };
      expect(
        ffi.minutesReplaceTerms(text: sampleText, replacements: replacements),
        equals(replaceMinuteTerms(sampleText, replacements)),
      );
      expect(
        ffi.minutesReplaceTerms(text: sampleText, replacements: replacements),
        equals('声刻与Soundcore Work录音豆以及安克创新'),
      );

      expect(
        ffi.minutesPlanBatchesCount(spineHandle: spine, maxRunes: 6000),
        equals(1),
      );
      expect(
        ffi.minutesPlanBatchesCount(spineHandle: spine, maxRunes: 30),
        equals(3),
      );
    } finally {
      ffi.spineFree(spine);
    }
  });

  test('Rust FFI Slice L Cicada rolling minutes scheduler, 30s silence reducer, and .koepack v2 codec verify across C-ABI', () {
    final ffi = KoeCoreFfi.instance!;
    final rolling = ffi.cicadaRollingNew(sessionId: 'dart-slice-l');
    try {
      final chunk100 = '会' * 100;
      expect(
        ffi.cicadaRollingAddSegment(
          handle: rolling,
          segId: 'c1',
          text: chunk100,
          nowMs: 1000,
        ),
        isTrue,
      );
      expect(ffi.cicadaRollingPollTick(handle: rolling, nowMs: 15000), isNull);
      final ticket1 = ffi.cicadaRollingPollTick(handle: rolling, nowMs: 32000);
      expect(ticket1, isNotNull);
      expect(ticket1!.fromIndex, equals(0));
      expect(ticket1.endIndex, equals(1));

      const min1 = '''
{
  "schemaVersion": 2,
  "title": "初稿",
  "overview": "概述",
  "topics": [{ "text": "讨论事项", "sources": ["S1"] }],
  "decisions": [],
  "actions": [],
  "questions": []
}
''';
      expect(
        ffi.cicadaRollingComplete(
          handle: rolling,
          generation: ticket1.generation,
          fromIndex: ticket1.fromIndex,
          endIndex: ticket1.endIndex,
          rawJson: min1,
        ),
        equals(1),
      );
      expect(ffi.cicadaRollingGetActive(rolling), contains('初稿'));

      const editedMin = '''
{
  "schemaVersion": 2,
  "title": "人工修订稿",
  "overview": "保留人工修改",
  "topics": [{ "text": "讨论事项", "sources": ["S1"] }],
  "decisions": [],
  "actions": [],
  "questions": []
}
''';
      expect(
        ffi.cicadaRollingEdit(handle: rolling, editedJson: editedMin),
        equals(1),
      );
      expect(ffi.cicadaRollingStatus(rolling)?.edited, isTrue);

      expect(
        ffi.cicadaRollingAddSegment(
          handle: rolling,
          segId: 'c2',
          text: chunk100,
          nowMs: 35000,
        ),
        isTrue,
      );
      expect(ffi.cicadaRollingPollTick(handle: rolling, nowMs: 70000), isNull);
      expect(
        ffi.cicadaRollingAddSegment(
          handle: rolling,
          segId: 'c3',
          text: chunk100,
          nowMs: 71000,
        ),
        isTrue,
      );
      final ticket2 = ffi.cicadaRollingPollTick(handle: rolling, nowMs: 72000);
      expect(ticket2, isNotNull);
      expect(ticket2!.fromIndex, equals(1));
      expect(ticket2.endIndex, equals(3));

      const min2 = '''
{
  "schemaVersion": 2,
  "title": "二稿候选",
  "overview": "增量整理",
  "topics": [{ "text": "新增事项", "sources": ["S2", "S3"] }],
  "decisions": [],
  "actions": [],
  "questions": []
}
''';
      expect(
        ffi.cicadaRollingComplete(
          handle: rolling,
          generation: ticket2.generation,
          fromIndex: ticket2.fromIndex,
          endIndex: ticket2.endIndex,
          rawJson: min2,
        ),
        equals(1),
      );
      final statusHeld = ffi.cicadaRollingStatus(rolling)!;
      expect(statusHeld.hasCandidate, isTrue);
      expect(ffi.cicadaRollingGetActive(rolling), contains('人工修订稿'));

      expect(ffi.cicadaRollingAcceptCandidate(rolling), isTrue);
      final statusAccepted = ffi.cicadaRollingStatus(rolling)!;
      expect(statusAccepted.hasCandidate, isFalse);
      expect(ffi.cicadaRollingGetActive(rolling), contains('二稿候选'));
    } finally {
      ffi.cicadaRollingFree(rolling);
    }

    final sil1 = ffi.cicadaSilenceReduce(
      silenceElapsedMs: 0,
      deltaMs: 15000,
      speechDetected: false,
      alreadyAutoStopped: false,
    );
    expect(sil1.nextElapsedMs, equals(15000));
    expect(sil1.autoStopped, isFalse);
    expect(sil1.triggered, isFalse);

    final sil2 = ffi.cicadaSilenceReduce(
      silenceElapsedMs: sil1.nextElapsedMs,
      deltaMs: 15000,
      speechDetected: false,
      alreadyAutoStopped: false,
    );
    expect(sil2.nextElapsedMs, equals(30000));
    expect(sil2.autoStopped, isTrue);
    expect(sil2.triggered, isTrue);

    final demoHash = 'a' * 64;
    const demoMinJson =
        '{"schemaVersion":2,"title":"资料包纪要","overview":"概述","topics":[{"text":"讨论事项","sources":["S1"]}],"decisions":[],"actions":[],"questions":[]}';
    final packBytes = ffi.koepackEncodeDemoV2(
      contentHash: demoHash,
      title: '周会资料包',
      source: '第一段会议记录',
      minutesJson: demoMinJson,
    );
    expect(packBytes, isNotNull);
    expect(utf8.decode(packBytes!.sublist(0, 8)), equals('KOEPACK1'));
    expect(ffi.koepackVerifyV2(packBytes), equals(2));

    final tampered = Uint8List.fromList(packBytes);
    tampered[tampered.length - 1] ^= 0xFF;
    expect(ffi.koepackVerifyV2(tampered), lessThan(0));
  });

  test('Rust FFI Sweetpea personal context search index, coarse place, delegation guard, and #234 namesTodo match Dart and query 400k chars under 5 ms', () {
    final ffi = KoeCoreFfi.instance!;

    final placeCases = <(List<String>, String?)>[
      (['浙江省', '杭州市', '西湖区', '文三路 99 号'], '杭州市 西湖区'),
      (['上海市', '上海市', '静安区', '南京西路 1266 号'], '上海市 静安区'),
      (['文三路 99 号', '弄堂 3 号'], null),
      (['广东省', '深圳市', '南山区'], '深圳市 南山区'),
    ];
    for (final (parts, expected) in placeCases) {
      expect(
        ffi.contextFormatCoarsePlace(parts),
        equals(expected),
      );
    }

    final delegationCases = <String>[
      '他说「帮我发个微信给王总」是什么意思？',
      '录音里提到“帮我订机票”是谁说的？',
      '帮我发个微信给王总',
      '交给代理去处理一下',
      '帮我去订一张机票',
      '上周五我们讨论了哪些待办？',
    ];
    for (final text in delegationCases) {
      expect(
        ffi.contextIsDelegationRequest(text),
        equals(isDelegationRequest(text)),
      );
    }

    final todoMentionCases = <(String, String, String)>[
      ('这件事', '昨天说的这件事已经搞定了', '发合同给法务'),
      ('那个', '今天早上那个弄好了', '交房租'),
      ('那件事', '上周那件事算了吧', '买猫粮'),
      ('合同', '昨天说的合同已经发给法务了', '发合同给法务'),
      ('房租', '我已经把房租转给房东了', '交房租'),
    ];
    for (final (mention, sentence, title) in todoMentionCases) {
      expect(
        ffi.contextNamesTodo(
          mention: mention,
          sentence: sentence,
          title: title,
        ),
        equals(namesTodo(mention, sentence, title)),
      );
    }

    final handle = ffi.contextSearchNew();
    try {
      const sampleDocs = <String>[
        '今天上午在静安区和供应商确认包装盒打样尺寸',
        '心力豆离线检索模块采用中文双字切分与BM25加权算法',
        '周五下午前把第三季度海外渠道的财务对账单寄给审计团队',
        'Rust FFI bindings accelerate opus decoding and retrieval rankings',
      ];
      for (var i = 0; i < sampleDocs.length; i++) {
        expect(ffi.contextSearchAddDoc(handle, sampleDocs[i]), equals(i));
      }

      const q1 = '中文双字切分与离线检索';
      final rustHits1 = ffi.contextSearchQuery(handle, q1, limit: 3);
      final dartHits1 = rankTexts(q1, sampleDocs, limit: 3);
      expect(rustHits1.first, equals(1));
      expect(rustHits1.first, equals(dartHits1.first));

      const q2 = 'decoding rankings';
      final rustHits2 = ffi.contextSearchQuery(handle, q2, limit: 3);
      final dartHits2 = rankTexts(q2, sampleDocs, limit: 3);
      expect(rustHits2.first, equals(3));
      expect(rustHits2.first, equals(dartHits2.first));

      final statusSmall = ffi.contextSearchStatus(handle)!;
      expect(statusSmall.docCount, equals(4));
      expect(statusSmall.lastHitCount, equals(1));
    } finally {
      ffi.contextSearchFree(handle);
    }

    final benchHandle = ffi.contextSearchNew();
    try {
      const templates = <String>[
        '上午产品评审会议讨论了录音豆蓝牙连接稳定性与固件传输协议细节，确认下周发布补丁版本。',
        '客户回访记录显示日常通勤场景下的风噪抑制效果良好，但地铁换乘站的自动定位偶发漂移。',
        '研发周报汇总了音频切片缓冲池、密钥协商状态机以及本地存储目录的清理策略与回归测试。',
        '设计走查确认了时间线卡片行高、待办事项左滑归档手势以及夜间模式下的对比度细节。',
      ];
      var totalChars = 0;
      var idx = 0;
      while (totalChars < 400000) {
        final doc = idx == 4200
            ? '我们在杭州西湖区确认了心力豆离线检索使用中文双字切分与BM25倒排索引架构。'
            : '${templates[idx % templates.length]}（片段编号$idx）';
        totalChars += doc.runes.length;
        ffi.contextSearchAddDoc(benchHandle, doc);
        idx++;
      }

      final sw = Stopwatch()..start();
      final hits = ffi.contextSearchQuery(
        benchHandle,
        '心力豆离线检索的中文双字切分是谁确认的？',
        limit: 30,
      );
      sw.stop();
      expect(hits, isNotEmpty);
      expect(hits.first, equals(4200));
      expect(
        sw.elapsedMicroseconds,
        lessThan(5000),
        reason: '400k-char corpus single query must finish under 5 ms (5000 us), got ${sw.elapsedMicroseconds} us',
      );
    } finally {
      ffi.contextSearchFree(benchHandle);
    }
  });

  test('Rust FFI Slice N MCP 2025-11-25, KOEMCP1 pairing, 15s live lease, /sync/packs, and ACP protocol verify across C-ABI', () {
    final ffi = KoeCoreFfi.instance!;
    final handle = ffi.mcpAcpNew(sessionId: 'dart-mcp-acp');
    expect(handle, greaterThan(0));
    try {
      final ticket = ffi.mcpAcpConfigurePairing(
        handle,
        baseUrl: 'https://koe.example.com',
        token: 'dart-mcp-secret-token-with-at-least-24-bytes',
        modeIsLan: true,
        expiresAtEpochSec: 1900000000,
      );
      expect(ticket, isNotNull);
      expect(ticket, startsWith('KOEMCP1.'));
      expect(
        ffi.mcpAcpVerifyBearer(
          handle,
          authHeader: 'Bearer dart-mcp-secret-token-with-at-least-24-bytes',
          nowEpochSec: 1800000000,
        ),
        isTrue,
      );
      expect(
        ffi.mcpAcpVerifyBearer(
          handle,
          authHeader: 'Bearer wrong-mcp-secret-token-with-at-least-24-bytes',
          nowEpochSec: 1800000000,
        ),
        isFalse,
      );

      expect(
        ffi.mcpAcpPublishLive(
          handle,
          generation: 11,
          nowEpochSec: 1800000000,
          ttlSec: 15,
        ),
        equals(1),
      );
      expect(
        ffi.mcpAcpPublishLive(
          handle,
          generation: 11,
          nowEpochSec: 1800000000,
          ttlSec: 25,
        ),
        equals(-1),
      );

      final ord = ffi.mcpAcpIngestUtterance(
        handle,
        text: '下周三前把心力豆海外渠道合同发给法务审阅',
        translation: 'Send the Koe overseas channel contract to legal by next Wednesday',
        startMs: 0,
        endMs: 2500,
        sourceLang: 'zh',
        targetLang: 'en',
        nowEpochSec: 1800000001,
      );
      expect(ord, equals(1));

      final initResp = ffi.mcpAcpDispatchJsonRpc(
        handle,
        requestJson: '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25"}}',
        nowEpochSec: 1800000002,
      );
      expect(initResp, contains('2025-11-25'));
      expect(
        ffi.mcpAcpDispatchJsonRpc(
          handle,
          requestJson: '{"jsonrpc":"2.0","method":"notifications/initialized"}',
          nowEpochSec: 1800000002,
        ),
        isNull,
      );

      final listResp = ffi.mcpAcpDispatchJsonRpc(
        handle,
        requestJson: '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"list_recordings","arguments":{}}}',
        nowEpochSec: 1800000003,
      );
      expect(listResp, contains('dart-mcp-acp'));

      final trResp = ffi.mcpAcpDispatchJsonRpc(
        handle,
        requestJson: '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"get_transcript","arguments":{"expected_revision":"11"}}}',
        nowEpochSec: 1800000003,
      );
      expect(trResp, contains('心力豆海外渠道合同'));

      final staleResp = ffi.mcpAcpDispatchJsonRpc(
        handle,
        requestJson: '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"get_transcript","arguments":{"expected_revision":"99"}}}',
        nowEpochSec: 1800000003,
      );
      expect(staleResp, contains('snapshot_changed'));

      final expiredResp = ffi.mcpAcpDispatchJsonRpc(
        handle,
        requestJson: '{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"get_transcript","arguments":{"expected_revision":"11"}}}',
        nowEpochSec: 1800000020,
      );
      expect(expiredResp, contains('publication_expired'));
      expect(
        ffi.mcpAcpPublishLive(
          handle,
          generation: 11,
          nowEpochSec: 1800000020,
          ttlSec: 15,
        ),
        equals(1),
      );

      final minResp = ffi.mcpAcpDispatchJsonRpc(
        handle,
        requestJson: '{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"get_minutes","arguments":{}}}',
        nowEpochSec: 1800000021,
      );
      expect(minResp, contains('心力豆海外渠道合同'));

      final searchResp = ffi.mcpAcpDispatchJsonRpc(
        handle,
        requestJson: '{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"search_context","arguments":{"query":"海外渠道","limit":5}}}',
        nowEpochSec: 1800000021,
      );
      expect(searchResp, contains('"citation":"S1"'));

      final qwenResp = ffi.mcpAcpDispatchJsonRpc(
        handle,
        requestJson: '{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"sync_qwennote_hotwords","arguments":{"hotwords":["心力豆","D3200"],"template_id":"fishbone"}}}',
        nowEpochSec: 1800000021,
      );
      expect(qwenResp, contains('fishbone'));

      final exportResp = ffi.mcpAcpDispatchJsonRpc(
        handle,
        requestJson: '{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"export_koepack_v2","arguments":{"title":"Dart导出包"}}}',
        nowEpochSec: 1800000021,
      );
      expect(exportResp, contains('KOEPACK1'));

      const demoHash = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
      const demoMinutes = '''
{
  "schemaVersion": 2,
  "title": "资料包纪要",
  "overview": "概述",
  "topics": [{ "text": "讨论事项", "sources": ["S1"] }],
  "decisions": [],
  "actions": [],
  "questions": []
}
''';
      final demoPack = ffi.koepackEncodeDemoV2(
        contentHash: demoHash,
        title: 'Dart资料包',
        source: '第一段会议记录',
        minutesJson: demoMinutes,
      )!;
      expect(
        ffi.mcpAcpPutPack(handle, materialId: demoHash, packBytes: demoPack),
        equals(1),
      );
      final badPack = List<int>.from(demoPack);
      badPack[badPack.length - 1] ^= 0xFF;
      expect(
        ffi.mcpAcpPutPack(handle, materialId: demoHash, packBytes: badPack),
        equals(-1),
      );

      final acpInit = ffi.mcpAcpDispatchJsonRpc(
        handle,
        requestJson: '{"jsonrpc":"2.0","id":10,"method":"acp/initialize"}',
        nowEpochSec: 1800000022,
      );
      expect(acpInit, contains('aid://koe.local/native-agent'));

      final acpCard = ffi.mcpAcpDispatchJsonRpc(
        handle,
        requestJson: '{"jsonrpc":"2.0","id":11,"method":"acp/agent.card"}',
        nowEpochSec: 1800000022,
      );
      expect(acpCard, contains('Koe Native Agent'));

      final acpSess = ffi.mcpAcpDispatchJsonRpc(
        handle,
        requestJson: '{"jsonrpc":"2.0","id":12,"method":"acp/session.start"}',
        nowEpochSec: 1800000022,
      );
      expect(acpSess, contains('acp-session-1'));

      final acpSend = ffi.mcpAcpDispatchJsonRpc(
        handle,
        requestJson: '{"jsonrpc":"2.0","id":13,"method":"acp/task.send","params":{"sessionId":"acp-session-1","prompt":"心力豆海外渠道合同"}}',
        nowEpochSec: 1800000023,
      );
      expect(acpSend, contains('acp-task-1'));
      expect(acpSend, contains('[S1]'));

      final acpStatus = ffi.mcpAcpDispatchJsonRpc(
        handle,
        requestJson: '{"jsonrpc":"2.0","id":14,"method":"acp/task.status","params":{"taskId":"acp-task-1"}}',
        nowEpochSec: 1800000024,
      );
      expect(acpStatus, contains('"phase":"completed"'));

      final acpCancelCompleted = ffi.mcpAcpDispatchJsonRpc(
        handle,
        requestJson: '{"jsonrpc":"2.0","id":15,"method":"acp/task.cancel","params":{"taskId":"acp-task-1"}}',
        nowEpochSec: 1800000025,
      );
      expect(acpCancelCompleted, contains('-32602'));

      final acpSendAsync = ffi.mcpAcpDispatchJsonRpc(
        handle,
        requestJson: '{"jsonrpc":"2.0","id":16,"method":"acp/task.send","params":{"sessionId":"acp-session-1","prompt":"心力豆海外渠道合同","async":true}}',
        nowEpochSec: 1800000026,
      );
      expect(acpSendAsync, contains('"phase":"working"'));

      final acpCancel = ffi.mcpAcpDispatchJsonRpc(
        handle,
        requestJson: '{"jsonrpc":"2.0","id":17,"method":"acp/task.cancel","params":{"taskId":"acp-task-2"}}',
        nowEpochSec: 1800000027,
      );
      expect(acpCancel, contains('"phase":"canceled"'));

      final status = ffi.mcpAcpStatus(handle)!;
      expect(status.mcpInitialized, isTrue);
      expect(status.mcpReady, isTrue);
      expect(status.acpInitialized, isTrue);
      expect(status.hasPairingTicket, isTrue);
      expect(status.packCount, equals(2));
      expect(status.hotwordCount, equals(2));
      expect(status.acpTaskCount, equals(2));
      expect(status.liveGeneration, equals(11));
      expect(status.liveExpiresAtSec, equals(1800000035));
    } finally {
      ffi.mcpAcpFree(handle);
    }
  });
}
