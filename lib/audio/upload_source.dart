import 'dart:io';
import 'audio_duration.dart';

/// Only substitute the matching compressed recording, never unrelated audio.
Future<String> compressedUploadSource(String path) async {
  if (!path.endsWith('.wav')) return path;
  final raw = '${path.substring(0, path.length - 4)}.opus';
  if (!await File(raw).exists()) return path;
  final playbackDuration = await AudioDuration.read(path);
  final rawDuration = await AudioDuration.read(raw);
  if (playbackDuration == null ||
      rawDuration == null ||
      (playbackDuration - rawDuration).inMilliseconds.abs() > 500) {
    return path;
  }
  return raw;
}
