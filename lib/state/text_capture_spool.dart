import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'atomic_file.dart';

/// Where a text-only capture stands, saved next to its audio spool so a
/// capture cut off by a crash, or stopped without network, can still have
/// its unrecognized tail turned into text later.
class TextCaptureSpoolState {
  const TextCaptureSpoolState({
    required this.documentId,
    required this.startedAt,
    required this.sentBytes,
  });

  final String documentId;
  final DateTime startedAt;

  /// Audio before this offset is already reflected in the saved text.
  final int sentBytes;

  Map<String, Object?> toJson() => {
    'version': 1,
    'documentId': documentId,
    'startedAt': startedAt.toIso8601String(),
    'sentBytes': sentBytes,
  };

  static TextCaptureSpoolState? decode(Object? value) {
    if (value is! Map) return null;
    final id = value['documentId'];
    final startedAt = DateTime.tryParse('${value['startedAt']}');
    final sent = value['sentBytes'];
    if (id is! String || id.isEmpty || startedAt == null || sent is! int) {
      return null;
    }
    return TextCaptureSpoolState(
      documentId: id,
      startedAt: startedAt,
      sentBytes: sent < 0 ? 0 : sent,
    );
  }
}

/// Raw 16 kHz mono PCM16 written while a text-only capture runs.
///
/// The audio exists only so nothing said is lost to a dropped connection:
/// it is re-sent after a reconnect, recognized from file when the network
/// was gone, or kept as an original when the user asks. Otherwise it is
/// deleted once its text is saved.
class TextCaptureSpool {
  TextCaptureSpool._(this.pcm, this._state);

  static const sampleRate = 16000;
  static const bytesPerSecond = sampleRate * 2;

  final File pcm;
  final File _state;
  int _length = 0;
  Future<void> _writes = Future<void>.value();
  RandomAccessFile? _out;

  /// Bytes safely written so far.
  int get length => _length;

  static File _stateFile(File pcm) => File(p.setExtension(pcm.path, '.json'));

  static Future<TextCaptureSpool> create(Directory dir, String id) async {
    await dir.create(recursive: true);
    final pcm = File(p.join(dir.path, '$id.pcm'));
    final spool = TextCaptureSpool._(pcm, _stateFile(pcm));
    spool._out = await pcm.open(mode: FileMode.write);
    return spool;
  }

  /// Opens a spool left behind by an earlier run, read-only.
  static Future<TextCaptureSpool> existing(File pcm) async {
    final spool = TextCaptureSpool._(pcm, _stateFile(pcm));
    spool._length = (await pcm.length()) & ~1;
    return spool;
  }

  /// Spools in [dir] together with their saved state; unreadable state files
  /// are skipped and left alone.
  static Future<List<(TextCaptureSpool, TextCaptureSpoolState)>> pending(
    Directory dir,
  ) async {
    final found = <(TextCaptureSpool, TextCaptureSpoolState)>[];
    if (!await dir.exists()) return found;
    await for (final entity in dir.list()) {
      if (entity is! File || p.extension(entity.path) != '.pcm') continue;
      try {
        final raw = await _stateFile(entity).readAsString();
        final state = TextCaptureSpoolState.decode(jsonDecode(raw));
        if (state == null) continue;
        found.add((await existing(entity), state));
      } catch (_) {
        continue;
      }
    }
    return found;
  }

  /// Appends [samples]; writes are applied in call order.
  Future<void> append(Uint8List samples) {
    final out = _out;
    if (out == null || samples.isEmpty) return _writes;
    return _writes = _writes.then((_) async {
      await out.writeFrom(samples);
      _length += samples.length;
    });
  }

  /// Waits for every append so far to reach the file.
  Future<void> flush() => _writes;

  Future<Uint8List> read(int start, int end) async {
    final from = start.clamp(0, _length);
    final to = end.clamp(from, _length);
    if (to == from) return Uint8List(0);
    final input = await pcm.open();
    try {
      await input.setPosition(from);
      return await input.read(to - from);
    } finally {
      await input.close();
    }
  }

  Future<void> saveState(TextCaptureSpoolState state) =>
      writeFileAtomically(_state, jsonEncode(state.toJson()));

  /// Writes the audio from [start] to the end as a WAV file at [path].
  Future<String> writeWav(String path, {int start = 0}) async {
    await _writes;
    final from = start.clamp(0, _length) & ~1;
    final dataLength = _length - from;
    final output = await File(path).open(mode: FileMode.write);
    try {
      await output.writeFrom(_wavHeader(dataLength));
      final input = await pcm.open();
      try {
        await input.setPosition(from);
        var left = dataLength;
        while (left > 0) {
          final chunk = await input.read(left < 1 << 20 ? left : 1 << 20);
          if (chunk.isEmpty) break;
          await output.writeFrom(chunk);
          left -= chunk.length;
        }
      } finally {
        await input.close();
      }
    } finally {
      await output.close();
    }
    return path;
  }

  Future<void> close() async {
    await _writes;
    final out = _out;
    _out = null;
    await out?.close();
  }

  Future<void> delete() async {
    await close();
    for (final file in [pcm, _state]) {
      try {
        if (await file.exists()) await file.delete();
      } catch (_) {}
    }
  }

  static Uint8List _wavHeader(int pcmLength) {
    final header = ByteData(44);
    void ascii(int at, String value) {
      for (var i = 0; i < value.length; i++) {
        header.setUint8(at + i, value.codeUnitAt(i));
      }
    }

    ascii(0, 'RIFF');
    header.setUint32(4, 36 + pcmLength, Endian.little);
    ascii(8, 'WAVE');
    ascii(12, 'fmt ');
    header.setUint32(16, 16, Endian.little);
    header.setUint16(20, 1, Endian.little);
    header.setUint16(22, 1, Endian.little);
    header.setUint32(24, sampleRate, Endian.little);
    header.setUint32(28, bytesPerSecond, Endian.little);
    header.setUint16(32, 2, Endian.little);
    header.setUint16(34, 16, Endian.little);
    ascii(36, 'data');
    header.setUint32(40, pcmLength, Endian.little);
    return header.buffer.asUint8List();
  }
}
