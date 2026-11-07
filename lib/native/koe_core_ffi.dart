import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

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
}
