import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import '../crypto/device_crypto.dart';
import '../protocol/models.dart';

final class _KoeDeviceInfoNative extends Struct {
  @Int32()
  external int connectStatus;

  @Int32()
  external int battery;

  @Uint8()
  external int charging;

  @Int32()
  external int boxBattery;

  @Uint8()
  external int boxCharging;

  @Uint8()
  external int recordingStatus;

  @Uint8()
  external int hasMemory;

  @Uint32()
  external int totalMemoryKb;

  @Uint32()
  external int freeMemoryKb;

  @Array(16)
  external Array<Uint8> firmwareVersion;

  @Array(32)
  external Array<Uint8> serialNumber;

  @Array(24)
  external Array<Uint8> boxMac;

  @Array(16)
  external Array<Uint8> boxFirmware;

  @Array(16)
  external Array<Uint8> wifiFirmware;
}

final class _KoeOfflineFileEntryNative extends Struct {
  @Uint32()
  external int fileId;

  @Uint32()
  external int durationMs;

  @Uint8()
  external int hasEndTime;

  @Array(3)
  external Array<Uint8> reserved;

  @Uint32()
  external int endTime;
}

final class _KoeOfflineFileListHeaderNative extends Struct {
  @Uint16()
  external int fileCount;

  @Uint16()
  external int parsedEntries;

  @Uint8()
  external int hasTransportState;

  @Array(3)
  external Array<Uint8> reserved;

  @Uint32()
  external int currentTransportTimestamp;

  @Uint32()
  external int currentTransportDuration;
}

final class _KoeSliceMarkTransitionNative extends Struct {
  @Uint8()
  external int cmdId;

  @Uint8()
  external int flags;

  @Array(2)
  external Array<Uint8> reserved;

  @Uint32()
  external int sequence;
}

final class _KoeAudioFileHeadNative extends Struct {
  @Uint32()
  external int fileId;

  @Uint32()
  external int fileSize;

  @Uint8()
  external int errorCode;

  @Uint8()
  external int unfinished;

  @Uint8()
  external int hasFileKey;

  @Uint8()
  external int reserved;

  @Array(16)
  external Array<Uint8> nonce;

  @Array(46)
  external Array<Uint8> encryptedFileKey;

  @Array(16)
  external Array<Uint8> sessionNonce;

  @Array(32)
  external Array<Uint8> fileKey;
}

class KoeParsedFileHead {
  const KoeParsedFileHead({
    required this.secret,
    required this.unfinished,
    this.fileKey,
  });

  final AudioFileSecretKey secret;
  final bool unfinished;
  final Uint8List? fileKey;
}

class KoeUnpackedSliceBatch {
  const KoeUnpackedSliceBatch({
    required this.opusBytes,
    required this.markedSequences,
    required this.sliceCount,
  });

  final Uint8List opusBytes;
  final List<int> markedSequences;
  final int sliceCount;

  int get wireRecordBytes => sliceCount * 166;
}

typedef _ChecksumNative = Uint8 Function(Pointer<Uint8>, Size);
typedef _ChecksumDart = int Function(Pointer<Uint8>, int);

typedef _EncodeNative = Size Function(
  Uint8,
  Uint8,
  Pointer<Uint8>,
  Size,
  Pointer<Uint8>,
  Size,
);
typedef _EncodeDart = int Function(
  int,
  int,
  Pointer<Uint8>,
  int,
  Pointer<Uint8>,
  int,
);

typedef _BatteryRemainingNative = Int32 Function(Int32);
typedef _BatteryRemainingDart = int Function(int);

typedef _DeviceInfoParseNative = Int32 Function(
  Pointer<Uint8>,
  Size,
  Pointer<_KoeDeviceInfoNative>,
);
typedef _DeviceInfoParseDart = int Function(
  Pointer<Uint8>,
  int,
  Pointer<_KoeDeviceInfoNative>,
);

typedef _OfflineFileListParseNative = Size Function(
  Pointer<Uint8>,
  Size,
  Uint8,
  Pointer<_KoeOfflineFileListHeaderNative>,
  Pointer<_KoeOfflineFileEntryNative>,
  Size,
);
typedef _OfflineFileListParseDart = int Function(
  Pointer<Uint8>,
  int,
  int,
  Pointer<_KoeOfflineFileListHeaderNative>,
  Pointer<_KoeOfflineFileEntryNative>,
  int,
);

typedef _SliceMarkInspectNative = Size Function(
  Pointer<Uint8>,
  Size,
  Pointer<Uint8>,
  Pointer<Uint8>,
  Pointer<_KoeSliceMarkTransitionNative>,
  Size,
);
typedef _SliceMarkInspectDart = int Function(
  Pointer<Uint8>,
  int,
  Pointer<Uint8>,
  Pointer<Uint8>,
  Pointer<_KoeSliceMarkTransitionNative>,
  int,
);

typedef _ParseFileHeadNative = Int32 Function(
  Pointer<Uint8>,
  Size,
  Pointer<Uint8>,
  Size,
  Pointer<_KoeAudioFileHeadNative>,
);
typedef _ParseFileHeadDart = int Function(
  Pointer<Uint8>,
  int,
  Pointer<Uint8>,
  int,
  Pointer<_KoeAudioFileHeadNative>,
);

typedef _UnpackSlicesNative = Size Function(
  Pointer<Uint8>,
  Size,
  Pointer<Uint8>,
  Size,
  Pointer<Uint8>,
  Size,
  Pointer<Uint8>,
  Size,
  Pointer<Uint32>,
  Size,
  Pointer<Size>,
);
typedef _UnpackSlicesDart = int Function(
  Pointer<Uint8>,
  int,
  Pointer<Uint8>,
  int,
  Pointer<Uint8>,
  int,
  Pointer<Uint8>,
  int,
  Pointer<Uint32>,
  int,
  Pointer<Size>,
);

typedef _HkdfNative = Int32 Function(
  Pointer<Uint8>,
  Size,
  Pointer<Uint8>,
  Size,
  Pointer<Uint8>,
  Size,
  Pointer<Uint8>,
  Size,
);
typedef _HkdfDart = int Function(
  Pointer<Uint8>,
  int,
  Pointer<Uint8>,
  int,
  Pointer<Uint8>,
  int,
  Pointer<Uint8>,
  int,
);

typedef _AesCtrNative = Int32 Function(
  Pointer<Uint8>,
  Size,
  Pointer<Uint8>,
  Size,
  Pointer<Uint8>,
  Size,
);
typedef _AesCtrDart = int Function(
  Pointer<Uint8>,
  int,
  Pointer<Uint8>,
  int,
  Pointer<Uint8>,
  int,
);

typedef _DecryptChunksNative = Int32 Function(
  Pointer<Uint8>,
  Size,
  Pointer<Uint8>,
  Size,
  Pointer<Uint8>,
  Size,
  Uint32,
);
typedef _DecryptChunksDart = int Function(
  Pointer<Uint8>,
  int,
  Pointer<Uint8>,
  int,
  Pointer<Uint8>,
  int,
  int,
);

typedef _OggCrcNative = Uint32 Function(Pointer<Uint8>, Size);
typedef _OggCrcDart = int Function(Pointer<Uint8>, int);

typedef _OggMuxNative = Pointer<Uint8> Function(
  Pointer<Uint8>,
  Size,
  Pointer<Size>,
);
typedef _OggMuxDart = Pointer<Uint8> Function(
  Pointer<Uint8>,
  int,
  Pointer<Size>,
);

typedef _BufferFreeNative = Void Function(Pointer<Uint8>, Size);
typedef _BufferFreeDart = void Function(Pointer<Uint8>, int);

typedef _WavHeaderNative = Int32 Function(Uint32, Pointer<Uint8>);
typedef _WavHeaderDart = int Function(int, Pointer<Uint8>);

/// Dart FFI bindings to the `#![forbid(unsafe_code)]` `koe_core` Rust kernel
/// exposed via `libkoe_core_ffi`.
final class KoeCoreFfi {
  KoeCoreFfi._(DynamicLibrary lib)
    : _checksum = lib.lookupFunction<_ChecksumNative, _ChecksumDart>(
        'koe_protocol_checksum',
        isLeaf: true,
      ),
      _encode = lib.lookupFunction<_EncodeNative, _EncodeDart>(
        'koe_protocol_encode',
        isLeaf: true,
      ),
      _batteryRemaining =
          lib.lookupFunction<_BatteryRemainingNative, _BatteryRemainingDart>(
            'koe_battery_remaining',
            isLeaf: true,
          ),
      _deviceInfoParsePacket =
          lib.lookupFunction<_DeviceInfoParseNative, _DeviceInfoParseDart>(
            'koe_device_info_parse_packet',
            isLeaf: true,
          ),
      _deviceInfoParsePayload =
          lib.lookupFunction<_DeviceInfoParseNative, _DeviceInfoParseDart>(
            'koe_device_info_parse_payload',
            isLeaf: true,
          ),
      _offlineFileListParse =
          lib.lookupFunction<
            _OfflineFileListParseNative,
            _OfflineFileListParseDart
          >('koe_offline_file_list_parse', isLeaf: true),
      _sliceMarkInspect =
          lib.lookupFunction<_SliceMarkInspectNative, _SliceMarkInspectDart>(
            'koe_slice_mark_inspect_transitions',
            isLeaf: true,
          ),
      _parseFileHead =
          lib.lookupFunction<_ParseFileHeadNative, _ParseFileHeadDart>(
            'koe_transport_parse_file_head',
            isLeaf: true,
          ),
      _unpackSlices =
          lib.lookupFunction<_UnpackSlicesNative, _UnpackSlicesDart>(
            'koe_transport_unpack_slices',
            isLeaf: true,
          ),
      _hkdf = lib.lookupFunction<_HkdfNative, _HkdfDart>(
        'koe_crypto_hkdf_sha256',
        isLeaf: true,
      ),
      _aesCtr = lib.lookupFunction<_AesCtrNative, _AesCtrDart>(
        'koe_crypto_aes_ctr_in_place',
        isLeaf: true,
      ),
      _decryptChunks =
          lib.lookupFunction<_DecryptChunksNative, _DecryptChunksDart>(
            'koe_crypto_decrypt_chunks_in_place',
            isLeaf: true,
          ),
      _oggCrc32 = lib.lookupFunction<_OggCrcNative, _OggCrcDart>(
        'koe_ogg_crc32',
        isLeaf: true,
      ),
      _oggMux = lib.lookupFunction<_OggMuxNative, _OggMuxDart>(
        'koe_ogg_opus_mux_raw_frames',
        isLeaf: true,
      ),
      _bufferFree = lib.lookupFunction<_BufferFreeNative, _BufferFreeDart>(
        'koe_buffer_free',
        isLeaf: true,
      ),
      _wavHeader = lib.lookupFunction<_WavHeaderNative, _WavHeaderDart>(
        'koe_wav_header',
        isLeaf: true,
      );

  static final KoeCoreFfi? instance = _load();

  bool get isAvailable => true;

  static KoeCoreFfi? _load() {
    for (final candidate in _candidateLibraries()) {
      try {
        return KoeCoreFfi._(candidate());
      } on Object {
        continue;
      }
    }
    return null;
  }

  static Iterable<DynamicLibrary Function()> _candidateLibraries() sync* {
    final envPath = Platform.environment['KOE_CORE_FFI_PATH'];
    if (envPath != null && envPath.isNotEmpty) {
      yield () => DynamicLibrary.open(envPath);
    }
    if (Platform.isMacOS || Platform.isIOS) {
      final execDir = File(Platform.resolvedExecutable).parent.path;
      final bundled = '$execDir/../Frameworks/libkoe_core_ffi.dylib';
      if (File(bundled).existsSync()) {
        yield () => DynamicLibrary.open(bundled);
      }
      final cwd = Directory.current.path;
      for (final rel in [
        '$cwd/rust/target/release/libkoe_core_ffi.dylib',
        '$cwd/rust/target/debug/libkoe_core_ffi.dylib',
      ]) {
        if (File(rel).existsSync()) {
          yield () => DynamicLibrary.open(rel);
        }
      }
      yield DynamicLibrary.process;
    } else if (Platform.isAndroid || Platform.isLinux) {
      final cwd = Directory.current.path;
      for (final rel in [
        '$cwd/rust/target/release/libkoe_core_ffi.so',
        '$cwd/rust/target/debug/libkoe_core_ffi.so',
      ]) {
        if (File(rel).existsSync()) {
          yield () => DynamicLibrary.open(rel);
        }
      }
      yield () => DynamicLibrary.open('libkoe_core_ffi.so');
    }
  }

  final _ChecksumDart _checksum;
  final _EncodeDart _encode;
  final _BatteryRemainingDart _batteryRemaining;
  final _DeviceInfoParseDart _deviceInfoParsePacket;
  final _DeviceInfoParseDart _deviceInfoParsePayload;
  final _OfflineFileListParseDart _offlineFileListParse;
  final _SliceMarkInspectDart _sliceMarkInspect;
  final _ParseFileHeadDart _parseFileHead;
  final _UnpackSlicesDart _unpackSlices;
  final _HkdfDart _hkdf;
  final _AesCtrDart _aesCtr;
  final _DecryptChunksDart _decryptChunks;
  final _OggCrcDart _oggCrc32;
  final _OggMuxDart _oggMux;
  final _BufferFreeDart _bufferFree;
  final _WavHeaderDart _wavHeader;

  int protocolChecksum(List<int> data) {
    if (data.isEmpty) return 0;
    final ptr = malloc<Uint8>(data.length);
    try {
      ptr.asTypedList(data.length).setAll(0, data);
      return _checksum(ptr, data.length);
    } finally {
      malloc.free(ptr);
    }
  }

  Uint8List protocolEncode({
    required int cmdType,
    required int cmdId,
    List<int> payload = const [],
  }) {
    final outCap = payload.length + 10;
    final payloadPtr = payload.isEmpty
        ? nullptr
        : malloc<Uint8>(payload.length);
    final outPtr = malloc<Uint8>(outCap);
    try {
      if (payload.isNotEmpty) {
        payloadPtr.asTypedList(payload.length).setAll(0, payload);
      }
      final written = _encode(
        cmdType & 0xFF,
        cmdId & 0xFF,
        payloadPtr,
        payload.length,
        outPtr,
        outCap,
      );
      return Uint8List.fromList(outPtr.asTypedList(written));
    } finally {
      if (payloadPtr != nullptr) malloc.free(payloadPtr);
      malloc.free(outPtr);
    }
  }

  int? batteryRemaining(int? raw) {
    if (raw == null) return null;
    final pct = _batteryRemaining(raw);
    return pct < 0 ? null : pct;
  }

  DeviceInfoModel parseDeviceInfoPacket(Uint8List raw, {String rawHex = ''}) {
    final rawPtr = raw.isEmpty ? nullptr : malloc<Uint8>(raw.length);
    final outPtr = calloc<_KoeDeviceInfoNative>(1);
    try {
      if (raw.isNotEmpty) rawPtr.asTypedList(raw.length).setAll(0, raw);
      _deviceInfoParsePacket(rawPtr, raw.length, outPtr);
      return _decodeDeviceInfo(outPtr.ref, rawHex);
    } finally {
      if (rawPtr != nullptr) malloc.free(rawPtr);
      calloc.free(outPtr);
    }
  }

  DeviceInfoModel parseDeviceInfoPayload(
    Uint8List payload, {
    String rawHex = '',
  }) {
    final payPtr = payload.isEmpty ? nullptr : malloc<Uint8>(payload.length);
    final outPtr = calloc<_KoeDeviceInfoNative>(1);
    try {
      if (payload.isNotEmpty) {
        payPtr.asTypedList(payload.length).setAll(0, payload);
      }
      _deviceInfoParsePayload(payPtr, payload.length, outPtr);
      return _decodeDeviceInfo(outPtr.ref, rawHex);
    } finally {
      if (payPtr != nullptr) malloc.free(payPtr);
      calloc.free(outPtr);
    }
  }

  OfflineFileList parseOfflineFileList(
    Uint8List payload, {
    bool withEndTime = false,
  }) {
    final payPtr = payload.isEmpty ? nullptr : malloc<Uint8>(payload.length);
    final hdrPtr = calloc<_KoeOfflineFileListHeaderNative>(1);
    Pointer<_KoeOfflineFileEntryNative> entriesPtr = nullptr;
    try {
      if (payload.isNotEmpty) {
        payPtr.asTypedList(payload.length).setAll(0, payload);
      }
      final flag = withEndTime ? 1 : 0;
      final total = _offlineFileListParse(
        payPtr,
        payload.length,
        flag,
        hdrPtr,
        nullptr,
        0,
      );
      final files = <OfflineFileEntry>[];
      if (total > 0) {
        entriesPtr = calloc<_KoeOfflineFileEntryNative>(total);
        _offlineFileListParse(
          payPtr,
          payload.length,
          flag,
          hdrPtr,
          entriesPtr,
          total,
        );
        for (var i = 0; i < total; i++) {
          final e = (entriesPtr + i).ref;
          files.add(
            OfflineFileEntry(
              fileId: e.fileId,
              durationMs: e.durationMs,
              endTime: e.hasEndTime != 0 ? e.endTime : null,
            ),
          );
        }
      }
      final hdr = hdrPtr.ref;
      return OfflineFileList(
        files: files,
        fileCount: hdr.fileCount,
        currentTransportTimestamp: hdr.hasTransportState != 0
            ? hdr.currentTransportTimestamp
            : null,
        currentTransportDuration: hdr.hasTransportState != 0
            ? hdr.currentTransportDuration
            : null,
      );
    } finally {
      if (payPtr != nullptr) malloc.free(payPtr);
      if (entriesPtr != nullptr) calloc.free(entriesPtr);
      calloc.free(hdrPtr);
    }
  }

  (int, int, List<(int, int, int)>) inspectSliceMarkTransitions({
    required Uint8List raw,
    required int lastCmdId,
    required int lastFlags,
  }) {
    if (raw.length < 10) return (lastCmdId, lastFlags, const []);
    final maxSlices = (raw.length ~/ 165) + 1;
    final rawPtr = malloc<Uint8>(raw.length);
    final cmdPtr = calloc<Uint8>(1);
    final flagsPtr = calloc<Uint8>(1);
    final outPtr = calloc<_KoeSliceMarkTransitionNative>(maxSlices);
    try {
      rawPtr.asTypedList(raw.length).setAll(0, raw);
      cmdPtr.value = lastCmdId & 0xFF;
      flagsPtr.value = lastFlags & 0xFF;
      final count = _sliceMarkInspect(
        rawPtr,
        raw.length,
        cmdPtr,
        flagsPtr,
        outPtr,
        maxSlices,
      );
      final list = <(int, int, int)>[];
      for (var i = 0; i < count; i++) {
        final t = (outPtr + i).ref;
        list.add((t.cmdId, t.sequence, t.flags));
      }
      return (cmdPtr.value, flagsPtr.value, list);
    } finally {
      malloc.free(rawPtr);
      calloc.free(cmdPtr);
      calloc.free(flagsPtr);
      calloc.free(outPtr);
    }
  }

  KoeParsedFileHead? parseFileHead(Uint8List raw, {Uint8List? sessionKey}) {
    if (raw.length < 97) return null;
    final rawPtr = malloc<Uint8>(raw.length);
    final skPtr = (sessionKey != null && sessionKey.isNotEmpty)
        ? malloc<Uint8>(sessionKey.length)
        : nullptr;
    final outPtr = calloc<_KoeAudioFileHeadNative>(1);
    try {
      rawPtr.asTypedList(raw.length).setAll(0, raw);
      if (skPtr != nullptr && sessionKey != null) {
        skPtr.asTypedList(sessionKey.length).setAll(0, sessionKey);
      }
      final ok = _parseFileHead(
        rawPtr,
        raw.length,
        skPtr,
        sessionKey?.length ?? 0,
        outPtr,
      );
      if (ok != 1) return null;
      final c = outPtr.ref;
      final secret = AudioFileSecretKey(
        fileId: c.fileId,
        fileSize: c.fileSize,
        nonce: _readFixedBytes(c.nonce, 16),
        encryptedFileKey: _readFixedBytes(c.encryptedFileKey, 46),
        sessionNonce: _readFixedBytes(c.sessionNonce, 16),
        errorCode: c.errorCode,
      );
      return KoeParsedFileHead(
        secret: secret,
        unfinished: c.unfinished != 0,
        fileKey: c.hasFileKey != 0 ? _readFixedBytes(c.fileKey, 32) : null,
      );
    } finally {
      malloc.free(rawPtr);
      if (skPtr != nullptr) malloc.free(skPtr);
      calloc.free(outPtr);
    }
  }

  KoeUnpackedSliceBatch unpackSlices(
    Uint8List frame, {
    Uint8List? fileKey,
    Uint8List? nonce,
  }) {
    if (frame.length < 174) {
      return KoeUnpackedSliceBatch(
        opusBytes: Uint8List(0),
        markedSequences: const [],
        sliceCount: 0,
      );
    }
    final maxSlices = (frame.length - 9) ~/ 165;
    final framePtr = malloc<Uint8>(frame.length);
    final fkPtr = (fileKey != null && fileKey.isNotEmpty)
        ? malloc<Uint8>(fileKey.length)
        : nullptr;
    final noncePtr = (nonce != null && nonce.isNotEmpty)
        ? malloc<Uint8>(nonce.length)
        : nullptr;
    final opusCap = maxSlices * 160;
    final opusPtr = malloc<Uint8>(opusCap);
    final marksPtr = calloc<Uint32>(maxSlices);
    final marksCountPtr = calloc<Size>(1);
    try {
      framePtr.asTypedList(frame.length).setAll(0, frame);
      if (fkPtr != nullptr && fileKey != null) {
        fkPtr.asTypedList(fileKey.length).setAll(0, fileKey);
      }
      if (noncePtr != nullptr && nonce != null) {
        noncePtr.asTypedList(nonce.length).setAll(0, nonce);
      }
      final sliceCount = _unpackSlices(
        framePtr,
        frame.length,
        fkPtr,
        fileKey?.length ?? 0,
        noncePtr,
        nonce?.length ?? 0,
        opusPtr,
        opusCap,
        marksPtr,
        maxSlices,
        marksCountPtr,
      );
      final marksCount = marksCountPtr.value;
      final marks = <int>[
        for (var i = 0; i < marksCount; i++) (marksPtr + i).value,
      ];
      return KoeUnpackedSliceBatch(
        opusBytes: Uint8List.fromList(opusPtr.asTypedList(sliceCount * 160)),
        markedSequences: marks,
        sliceCount: sliceCount,
      );
    } finally {
      malloc.free(framePtr);
      if (fkPtr != nullptr) malloc.free(fkPtr);
      if (noncePtr != nullptr) malloc.free(noncePtr);
      malloc.free(opusPtr);
      calloc.free(marksPtr);
      calloc.free(marksCountPtr);
    }
  }

  Uint8List hkdfSha256({
    required Uint8List ikm,
    required Uint8List salt,
    required Uint8List info,
    required int length,
  }) {
    final ikmPtr = malloc<Uint8>(ikm.isEmpty ? 1 : ikm.length);
    final saltPtr = malloc<Uint8>(salt.isEmpty ? 1 : salt.length);
    final infoPtr = malloc<Uint8>(info.isEmpty ? 1 : info.length);
    final outPtr = malloc<Uint8>(length);
    try {
      if (ikm.isNotEmpty) ikmPtr.asTypedList(ikm.length).setAll(0, ikm);
      if (salt.isNotEmpty) saltPtr.asTypedList(salt.length).setAll(0, salt);
      if (info.isNotEmpty) infoPtr.asTypedList(info.length).setAll(0, info);
      _hkdf(
        ikmPtr,
        ikm.length,
        saltPtr,
        salt.length,
        infoPtr,
        info.length,
        outPtr,
        length,
      );
      return Uint8List.fromList(outPtr.asTypedList(length));
    } finally {
      malloc.free(ikmPtr);
      malloc.free(saltPtr);
      malloc.free(infoPtr);
      malloc.free(outPtr);
    }
  }

  Uint8List? aesCtrDecrypt({
    required Uint8List data,
    required Uint8List key,
    required Uint8List iv,
  }) {
    if (key.length != 16 && key.length != 24 && key.length != 32) {
      return null;
    }
    if (data.isEmpty) return Uint8List(0);
    final bufPtr = malloc<Uint8>(data.length);
    final keyPtr = malloc<Uint8>(key.length);
    final ivPtr = malloc<Uint8>(iv.isEmpty ? 1 : iv.length);
    try {
      bufPtr.asTypedList(data.length).setAll(0, data);
      keyPtr.asTypedList(key.length).setAll(0, key);
      if (iv.isNotEmpty) ivPtr.asTypedList(iv.length).setAll(0, iv);
      final ok = _aesCtr(
        bufPtr,
        data.length,
        keyPtr,
        key.length,
        ivPtr,
        iv.length,
      );
      if (ok != 1) return null;
      return Uint8List.fromList(bufPtr.asTypedList(data.length));
    } finally {
      malloc.free(bufPtr);
      malloc.free(keyPtr);
      malloc.free(ivPtr);
    }
  }

  Uint8List? decryptChunks({
    required Uint8List data,
    required Uint8List fileKey,
    required Uint8List nonce,
    required int startSequence,
  }) {
    if (data.isEmpty) return Uint8List(0);
    final bufPtr = malloc<Uint8>(data.length);
    final keyPtr = malloc<Uint8>(fileKey.length);
    final noncePtr = malloc<Uint8>(nonce.isEmpty ? 1 : nonce.length);
    try {
      bufPtr.asTypedList(data.length).setAll(0, data);
      keyPtr.asTypedList(fileKey.length).setAll(0, fileKey);
      if (nonce.isNotEmpty) noncePtr.asTypedList(nonce.length).setAll(0, nonce);
      final ok = _decryptChunks(
        bufPtr,
        data.length,
        keyPtr,
        fileKey.length,
        noncePtr,
        nonce.length,
        startSequence,
      );
      if (ok != 1) return null;
      return Uint8List.fromList(bufPtr.asTypedList(data.length));
    } finally {
      malloc.free(bufPtr);
      malloc.free(keyPtr);
      malloc.free(noncePtr);
    }
  }

  int oggCrc32(Uint8List data) {
    if (data.isEmpty) return 0;
    final ptr = malloc<Uint8>(data.length);
    try {
      ptr.asTypedList(data.length).setAll(0, data);
      return _oggCrc32(ptr, data.length);
    } finally {
      malloc.free(ptr);
    }
  }

  Uint8List oggOpusMuxRawFrames(Uint8List raw) {
    final rawPtr = malloc<Uint8>(raw.length);
    final outLenPtr = calloc<Size>(1);
    Pointer<Uint8> muxPtr = nullptr;
    var muxLen = 0;
    try {
      rawPtr.asTypedList(raw.length).setAll(0, raw);
      muxPtr = _oggMux(rawPtr, raw.length, outLenPtr);
      muxLen = outLenPtr.value;
      if (muxPtr == nullptr || muxLen == 0) {
        throw StateError('无音频数据');
      }
      return Uint8List.fromList(muxPtr.asTypedList(muxLen));
    } finally {
      if (muxPtr != nullptr && muxLen > 0) {
        _bufferFree(muxPtr, muxLen);
      }
      malloc.free(rawPtr);
      calloc.free(outLenPtr);
    }
  }

  Uint8List wavHeader(int pcmLength) {
    final outPtr = malloc<Uint8>(44);
    try {
      _wavHeader(pcmLength, outPtr);
      return Uint8List.fromList(outPtr.asTypedList(44));
    } finally {
      malloc.free(outPtr);
    }
  }

  static DeviceInfoModel _decodeDeviceInfo(
    _KoeDeviceInfoNative c,
    String rawHex,
  ) {
    return DeviceInfoModel(
      connectStatus: c.connectStatus < 0 ? null : c.connectStatus,
      battery: c.battery < 0 ? null : c.battery,
      charging: c.charging != 0,
      firmwareVersion: _readFixedUtf8(c.firmwareVersion, 16),
      serialNumber: _readFixedUtf8(c.serialNumber, 32),
      totalMemoryKb: c.hasMemory != 0 ? c.totalMemoryKb : null,
      freeMemoryKb: c.hasMemory != 0 ? c.freeMemoryKb : null,
      boxBattery: c.boxBattery < 0 ? null : c.boxBattery,
      boxCharging: c.boxCharging != 0,
      boxMac: _readFixedUtf8(c.boxMac, 24),
      boxFirmware: _readFixedUtf8(c.boxFirmware, 16),
      wifiFirmware: _readFixedUtf8(c.wifiFirmware, 16),
      recordingStatus: c.recordingStatus,
      rawHex: rawHex,
    );
  }

  static String _readFixedUtf8(Array<Uint8> arr, int maxLen) {
    final bytes = <int>[];
    for (var i = 0; i < maxLen; i++) {
      final b = arr[i];
      if (b == 0) break;
      bytes.add(b);
    }
    return utf8.decode(bytes, allowMalformed: true);
  }

  static Uint8List _readFixedBytes(Array<Uint8> arr, int len) {
    final out = Uint8List(len);
    for (var i = 0; i < len; i++) {
      out[i] = arr[i];
    }
    return out;
  }
}
