import 'dart:ffi';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:pointycastle/digests/sha256.dart';

class AudioVersionException implements Exception {
  const AudioVersionException(this.message);
  final String message;
}

/// Content identity is independent of a file name, path, or modification date.
/// Read in bounded chunks; never allocate a complete long recording.
Future<String?> audioVersion(String path) async {
  final file = File(path);
  final before = await file.stat();
  if (before.type != FileSystemEntityType.file) return null;
  final digest =
      await (_CommonCrypto.instance?.sha256(file.openRead()) ??
          _dartSha256(file.openRead()));
  final after = await file.stat();
  if (after.type != FileSystemEntityType.file ||
      before.size != after.size ||
      before.modified != after.modified) {
    throw const AudioVersionException('音频内容已变化，请等待录音完整取回后重试');
  }
  return digest.map((v) => v.toRadixString(16).padLeft(2, '0')).join();
}

/// Elsewhere: pure Dart, about 36 MB/s in AOT, so 13 seconds for a
/// four-hour take (460 MB).
Future<Uint8List> _dartSha256(Stream<List<int>> chunks) async {
  final digest = SHA256Digest();
  await for (final chunk in chunks) {
    digest.update(
      chunk is Uint8List ? chunk : Uint8List.fromList(chunk),
      0,
      chunk.length,
    );
  }
  final output = Uint8List(digest.digestSize);
  digest.doFinal(output, 0);
  return output;
}

/// CommonCrypto is loaded in every iOS and macOS process and hashes a
/// four-hour take in about 0.2 seconds (#409).
final class _CommonCrypto {
  _CommonCrypto(DynamicLibrary process)
    : _init = process
          .lookupFunction<
            Int32 Function(Pointer<Uint8>),
            int Function(Pointer<Uint8>)
          >('CC_SHA256_Init', isLeaf: true),
      _update = process
          .lookupFunction<
            Int32 Function(Pointer<Uint8>, Pointer<Uint8>, Uint32),
            int Function(Pointer<Uint8>, Pointer<Uint8>, int)
          >('CC_SHA256_Update', isLeaf: true),
      _final = process
          .lookupFunction<
            Int32 Function(Pointer<Uint8>, Pointer<Uint8>),
            int Function(Pointer<Uint8>, Pointer<Uint8>)
          >('CC_SHA256_Final', isLeaf: true);

  static final _CommonCrypto? instance = _load();

  static _CommonCrypto? _load() {
    if (!Platform.isIOS && !Platform.isMacOS) return null;
    try {
      return _CommonCrypto(DynamicLibrary.process());
    } on ArgumentError {
      return null;
    }
  }

  /// sizeof(CC_SHA256_CTX) and CC_SHA256_DIGEST_LENGTH in CommonDigest.h.
  static const _contextSize = 104;
  static const _digestSize = 32;
  static const _bufferSize = 64 * 1024;

  final int Function(Pointer<Uint8>) _init;
  final int Function(Pointer<Uint8>, Pointer<Uint8>, int) _update;
  final int Function(Pointer<Uint8>, Pointer<Uint8>) _final;

  /// Each call owns its context and buffer, so hashes can run side by side.
  Future<Uint8List> sha256(Stream<List<int>> chunks) async {
    final context = calloc<Uint8>(_contextSize);
    final buffer = malloc<Uint8>(_bufferSize);
    final digest = calloc<Uint8>(_digestSize);
    try {
      _init(context);
      final staging = buffer.asTypedList(_bufferSize);
      await for (final chunk in chunks) {
        for (var at = 0; at < chunk.length; at += _bufferSize) {
          final length = math.min(_bufferSize, chunk.length - at);
          staging.setRange(0, length, chunk, at);
          _update(context, buffer, length);
        }
      }
      _final(digest, context);
      return Uint8List.fromList(digest.asTypedList(_digestSize));
    } finally {
      calloc.free(context);
      malloc.free(buffer);
      calloc.free(digest);
    }
  }
}
