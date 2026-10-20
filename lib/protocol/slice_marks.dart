import 'commands.dart';
import 'frame.dart';

/// Diagnostic for the bean's own key-point mark (double-tap the mic).
///
/// The onboarding text promises the gesture, but its format on the wire is
/// unconfirmed. Candidates are the `0x12` slice frame and the flags byte
/// after each slice's sequence number, both of which are otherwise skipped.
/// This reports when either departs from a plain `0x08` slice with flags 0,
/// once per change, so a double tap on a real device shows up in the log
/// with its sequence number without one line per slice.
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
