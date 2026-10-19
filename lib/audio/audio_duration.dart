import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'ogg_opus.dart';

/// Reads duration metadata from the local audio formats produced by the app.
class AudioDuration {
  AudioDuration._();

  static Future<Duration?> read(String path) async {
    try {
      final file = File(path);
      if (!await file.exists()) return null;
      final length = await file.length();
      if (length <= 0) return null;

      final input = await file.open();
      try {
        final header = Uint8List.fromList(
          await input.read(math.min(length, 44)),
        );
        if (OggOpus.isWav(header)) {
          return await _wavDuration(input, length);
        }
        if (OggOpus.isOgg(header)) {
          final tailLength = math.min(length, 64 * 1024);
          await input.setPosition(length - tailLength);
          return _oggDuration(Uint8List.fromList(await input.read(tailLength)));
        }
        if (path.endsWith('.opus') || path.endsWith('.opus.bin')) {
          final frames = (length + OggOpus.frameSize - 1) ~/ OggOpus.frameSize;
          return Duration(milliseconds: frames * 20);
        }
      } finally {
        await input.close();
      }
    } catch (_) {}
    return null;
  }

  /// Walks RIFF chunks instead of assuming the 44-byte layout: iPhone
  /// recordings put JUNK and FLLR chunks before `fmt ` and `data`.
  static Future<Duration?> _wavDuration(
    RandomAccessFile input,
    int fileLength,
  ) async {
    int? byteRate;
    var offset = 12;
    while (offset + 8 <= fileLength) {
      await input.setPosition(offset);
      final header = Uint8List.fromList(await input.read(8));
      if (header.length < 8) return null;
      final id = String.fromCharCodes(header, 0, 4);
      final size = ByteData.sublistView(header).getUint32(4, Endian.little);
      final body = offset + 8;
      if (id == 'fmt ') {
        if (size < 12 || body + 12 > fileLength) return null;
        await input.setPosition(body + 8);
        final rate = Uint8List.fromList(await input.read(4));
        byteRate = ByteData.sublistView(rate).getUint32(0, Endian.little);
      } else if (id == 'data') {
        final rate = byteRate;
        if (rate == null || rate <= 0) return null;
        final dataLength = math.min(size, math.max(0, fileLength - body));
        if (dataLength <= 0) return null;
        return Duration(
          microseconds: (dataLength * Duration.microsecondsPerSecond / rate)
              .round(),
        );
      }
      offset = body + size + (size.isOdd ? 1 : 0);
    }
    return null;
  }

  static Duration? _oggDuration(Uint8List tail) {
    final data = ByteData.sublistView(tail);
    for (var i = tail.length - 27; i >= 0; i--) {
      if (tail[i] != 0x4f ||
          tail[i + 1] != 0x67 ||
          tail[i + 2] != 0x67 ||
          tail[i + 3] != 0x53) {
        continue;
      }
      final granule = data.getUint64(i + 6, Endian.little);
      if (granule <= 0) continue;
      return Duration(
        microseconds:
            (granule * Duration.microsecondsPerSecond / OggOpus.sampleRate)
                .round(),
      );
    }
    return null;
  }
}
