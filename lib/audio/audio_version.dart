import 'dart:io';
import 'dart:typed_data';
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
  final digest = SHA256Digest();
  await for (final chunk in file.openRead()) {
    digest.update(
      chunk is Uint8List ? chunk : Uint8List.fromList(chunk),
      0,
      chunk.length,
    );
  }
  final after = await file.stat();
  if (after.type != FileSystemEntityType.file ||
      before.size != after.size ||
      before.modified != after.modified) {
    throw const AudioVersionException('音频内容已变化，请等待录音完整取回后重试');
  }
  final output = Uint8List(digest.digestSize);
  digest.doFinal(output, 0);
  return output.map((v) => v.toRadixString(16).padLeft(2, '0')).join();
}
