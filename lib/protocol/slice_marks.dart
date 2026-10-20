import 'commands.dart';
import 'frame.dart';

/// The bean's double-tap mark, confirmed on a real soundcore Work
/// (2026-10-20, PROTOCOL.md): the flags byte of the slice recorded at that
/// moment is `0x01`, and the next slice is back to `0x00`. Each slice holds
/// 20 ms of audio, so the mark sits at sequence × 20 ms into the recording.
/// No other packet accompanies it; it arrives with the live stream and
/// again when the file is retrieved.
abstract final class SliceMark {
  static const flag = 0x01;
  static const sliceDuration = Duration(milliseconds: 20);

  /// The note on a bookmark saved from a mark.
  static const bookmarkNote = '录音豆双击标记';

  static bool isMark(int flags) => flags & flag != 0;

  /// Where in the recording the slice with [sequence] starts.
  static Duration position(int sequence) => sliceDuration * sequence;
}

/// Logs departures from a plain `0x08` slice with flags 0, once per
/// change, so marks and any other flag values show in the device log with
/// their sequence numbers without one line per slice.
class SliceMarkProbe {
  (int, int) _last = (RxCmd.fileSliceId, 0);

  /// Log lines for [packet]; empty unless the frame kind or a flags byte
  /// changed since the previous slice.
  List<String> inspect(DecodedPacket packet, {DateTime? at}) {
    final raw = packet.raw;
    final lines = <String>[];
    var i = 9;
    while (raw.length - i >= 165) {
      final sequence = readU32Le(raw, i);
      final flags = raw[i + 4];
      final signature = (packet.cmdId, flags);
      if (signature != _last) {
        _last = signature;
        final time = (at ?? DateTime.now()).toIso8601String();
        lines.add(
          '标记线索 cmd=0x${_hex(packet.cmdId)} seq=$sequence '
          'flags=0x${_hex(flags)} at=$time',
        );
      }
      i += 165;
      if (i < raw.length) i += 1;
    }
    return lines;
  }

  static String _hex(int value) =>
      value.toRadixString(16).padLeft(2, '0').toUpperCase();
}
