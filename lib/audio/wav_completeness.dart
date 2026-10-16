import 'dart:io';
import 'dart:typed_data';

/// Result of [inspectWav]. [length] is the file size the decision was made on,
/// so a caller can detect a file that keeps growing after the inspection.
class WavInspection {
  const WavInspection._(this.length, this.problem);

  final int length;

  /// Why the file is not a complete WAV, or null when it is.
  final String? problem;

  bool get complete => problem == null;
}

/// Checks that [path] is a finished RIFF/WAVE file: the RIFF size matches the
/// file length (a writer that is still appending has not patched it yet), and
/// a non-empty `data` chunk lies entirely inside the file. Reads headers only.
Future<WavInspection> inspectWav(String path) async {
  RandomAccessFile? raf;
  var length = 0;
  try {
    raf = await File(path).open();
    length = await raf.length();
    if (length < 12) return WavInspection._(length, '文件头不完整');
    final header = await raf.read(12);
    if (header.length < 12 ||
        _id(header, 0) != 'RIFF' ||
        _id(header, 8) != 'WAVE') {
      return WavInspection._(length, '不是完整的 WAV 文件');
    }
    final riffSize = _u32(header, 4);
    if (riffSize + 8 != length) {
      return WavInspection._(length, '文件长度与 WAV 头不一致，可能仍在写入');
    }
    var offset = 12;
    while (offset + 8 <= length) {
      await raf.setPosition(offset);
      final chunk = await raf.read(8);
      if (chunk.length < 8) break;
      final size = _u32(chunk, 4);
      if (_id(chunk, 0) == 'data') {
        if (size == 0) return WavInspection._(length, '没有音频数据');
        if (offset + 8 + size > length) {
          return WavInspection._(length, '音频数据不完整');
        }
        return WavInspection._(length, null);
      }
      offset += 8 + size + (size.isOdd ? 1 : 0);
    }
    return WavInspection._(length, '缺少音频数据');
  } on FileSystemException {
    return WavInspection._(length, '无法读取录音文件');
  } finally {
    await raf?.close();
  }
}

String _id(Uint8List bytes, int offset) =>
    String.fromCharCodes(bytes, offset, offset + 4);

int _u32(Uint8List bytes, int offset) =>
    ByteData.sublistView(bytes, offset, offset + 4).getUint32(0, Endian.little);
