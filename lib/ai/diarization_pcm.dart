import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

/// Bounded reads of the streaming transcoder's normalized PCM16 mono WAV.
/// RIFF chunks are walked because AVFoundation adds metadata before audio.
class DiarizationPcm {
  DiarizationPcm._(this._file, this._offset, this.sampleCount, this.rate);
  final RandomAccessFile _file;
  final int _offset;
  final int sampleCount;
  final int rate;
  static const sampleRate = 16000;

  static DiarizationPcm open(String path) {
    final file = File(path).openSync();
    try {
      final length = file.lengthSync();
      final header = file.readSync(12);
      if (header.length != 12 ||
          String.fromCharCodes(header, 0, 4) != 'RIFF' ||
          String.fromCharCodes(header, 8, 12) != 'WAVE') {
        throw const FormatException('发言人区分需要标准 WAV 音频');
      }
      var validFormat = false;
      var rate = 0;
      var offset = 12;
      while (offset + 8 <= length) {
        file.setPositionSync(offset);
        final chunk = file.readSync(8);
        final size = ByteData.sublistView(chunk).getUint32(4, Endian.little);
        final id = String.fromCharCodes(chunk, 0, 4);
        final body = offset + 8;
        if (id == 'fmt ' && size >= 16) {
          final bytes = file.readSync(16);
          if (bytes.length != 16) break;
          final fmt = ByteData.sublistView(bytes);
          rate = fmt.getUint32(4, Endian.little);
          validFormat =
              fmt.getUint16(0, Endian.little) == 1 &&
              fmt.getUint16(2, Endian.little) == 1 &&
              rate > 0 &&
              fmt.getUint16(12, Endian.little) == 2 &&
              fmt.getUint16(14, Endian.little) == 16;
        } else if (id == 'data') {
          if (!validFormat || size > length - body || size.isOdd || size == 0) {
            break;
          }
          if (size ~/ 2 > rate * 3600) {
            throw StateError('本机发言人区分单次最多 1 小时；原文已保留');
          }
          return DiarizationPcm._(file, body, size ~/ 2, rate);
        }
        offset = body + size + (size.isOdd ? 1 : 0);
      }
      throw const FormatException('发言人区分需要完整的单声道 PCM16 WAV');
    } catch (_) {
      file.closeSync();
      rethrow;
    }
  }

  Float32List read(int start, int end) {
    final count = math.min(end, sampleCount) - start;
    if (start < 0 || count < 0) throw RangeError('Invalid audio interval');
    _file.setPositionSync(_offset + start * 2);
    final bytes = _file.readSync(count * 2);
    if (bytes.length != count * 2) throw const FormatException('音频文件读取不完整');
    final data = ByteData.sublistView(bytes);
    final samples = Float32List(count);
    for (var i = 0; i < count; i++) {
      samples[i] = data.getInt16(i * 2, Endian.little) / 32768;
    }
    return samples;
  }

  void close() => _file.closeSync();
}
