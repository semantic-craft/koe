import 'dart:io';
import 'dart:typed_data';

/// Default window used to confirm a retrieved file is no longer growing.
///
/// Only needed for files this app did not just finish writing itself; a WAV
/// returned by an awaited `OpusWave.convertRawFile` is already final.
const retrievedAudioSettle = Duration(milliseconds: 300);

/// The single transport-level completeness rule for device transfers (BLE
/// pull and Wi-Fi export).
///
/// Both transports keep a file that stopped at >= 95% of the announced size
/// for playback, but only the device's done signal or every announced byte
/// makes it a complete recording. Anything else is reported to
/// `processRetrievedRecording` as `transferComplete: false`, so it is never
/// submitted automatically and never compared as a new audio version.
bool retrievedTransferComplete({
  required bool doneSignal,
  required int received,
  required int expected,
}) => doneSignal || (expected > 0 && received >= expected);

/// Checks that [path] is a finished WAV before any paid transcription.
///
/// Returns `null` when the RIFF/WAVE header is finalized, the declared audio
/// fits inside the file, and the size/modification time stay unchanged for
/// [settle]. Otherwise returns a user-facing reason; the file is never
/// modified or deleted.
///
/// Retrieved WAVs are produced by `OpusWave.convertRawFile`, which writes a
/// zero-length header into `*.wav.part` and patches it on completion, so a
/// placeholder or overrunning size here means the file was cut short or is
/// still being written by someone else.
Future<String?> incompleteRetrievedAudioReason(
  String path, {
  Duration settle = retrievedAudioSettle,
}) async {
  final file = File(path);
  final before = await file.stat();
  if (before.type != FileSystemEntityType.file) {
    return '录音文件不存在，请重新取回后再转写';
  }
  final headerProblem = await _wavHeaderProblem(file, before.size);
  if (headerProblem != null) return headerProblem;
  if (settle > Duration.zero) await Future<void>.delayed(settle);
  final after = await file.stat();
  if (after.type != FileSystemEntityType.file ||
      after.size != before.size ||
      after.modified != before.modified) {
    return '录音仍在写入，已保留；写入完成后再转写';
  }
  return null;
}

const _placeholderSize = 0xFFFFFFFF;
const _incomplete = '录音未完整取回，已保留已收到的部分；请重新取回后再转写';

Future<String?> _wavHeaderProblem(File file, int length) async {
  if (length < 44) return _incomplete;
  final input = await file.open();
  try {
    final riff = ByteData.sublistView(Uint8List.fromList(await input.read(12)));
    if (riff.lengthInBytes < 12 ||
        _ascii(riff, 0) != 'RIFF' ||
        _ascii(riff, 8) != 'WAVE') {
      return '录音不是可识别的 WAV 文件，已保留；请重新取回';
    }
    final riffSize = riff.getUint32(4, Endian.little);
    if (riffSize == 0 || riffSize == _placeholderSize) {
      return '录音仍在写入，已保留；写入完成后再转写';
    }
    if (riffSize + 8 > length) return _incomplete;

    var offset = 12;
    var sawFormat = false;
    while (offset + 8 <= length) {
      await input.setPosition(offset);
      final chunk = ByteData.sublistView(
        Uint8List.fromList(await input.read(8)),
      );
      if (chunk.lengthInBytes < 8) break;
      final id = _ascii(chunk, 0);
      final size = chunk.getUint32(4, Endian.little);
      final body = offset + 8;
      if (id == 'fmt ') {
        if (size < 16 || body + size > length) return _incomplete;
        sawFormat = true;
      } else if (id == 'data') {
        if (!sawFormat) return '录音不是可识别的 WAV 文件，已保留；请重新取回';
        if (size == 0 || size == _placeholderSize) {
          return '录音仍在写入或没有音频数据，已保留；完整取回后再转写';
        }
        if (body + size > length) return _incomplete;
        return null;
      }
      // Chunks are word aligned; an odd size carries one pad byte.
      offset = body + size + (size.isOdd ? 1 : 0);
    }
    return _incomplete;
  } finally {
    await input.close();
  }
}

String _ascii(ByteData data, int offset) =>
    String.fromCharCodes(List.generate(4, (i) => data.getUint8(offset + i)));
