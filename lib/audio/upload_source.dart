import 'dart:io';

import 'audio_duration.dart';
import 'recording_audio.dart';

/// Only substitute the matching compressed recording, never unrelated audio.
Future<String> compressedUploadSource(String path) async {
  final raw = RecordingAudio.of(path).framesForWav;
  if (raw == null) return path;
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
