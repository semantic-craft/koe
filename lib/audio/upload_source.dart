import 'dart:io';

import 'audio_duration.dart';
import 'audio_transcoder.dart';
import 'ogg_opus.dart';
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

/// Why [prepareUploadAudio] could not produce a file to send.
class UploadPreparationException implements Exception {
  const UploadPreparationException(this.message, {this.cancelled = false});

  /// Readable reason, already worded for the user.
  final String message;

  /// The caller stopped wanting the result; [message] is not shown then.
  final bool cancelled;

  @override
  String toString() => message;
}

/// The step every cloud engine runs before it uploads [path]: imported
/// containers (mp3, m4a/mp4, aac, flac) go as they are, WAV and Ogg too, and
/// device originals (bare Opus frames) are wrapped in Ogg first (#233).
///
/// Returns the file to send and the container it is in; each engine then
/// decides whether it accepts that container or converts it.
Future<({String path, AudioContainer container})> prepareUploadAudio(
  String path, {
  required bool Function() isCurrent,
}) async {
  final container = await AudioContainer.read(path);
  switch (container) {
    case AudioContainer.mp3:
    case AudioContainer.mp4:
    case AudioContainer.adts:
    case AudioContainer.flac:
    case AudioContainer.wav:
    case AudioContainer.ogg:
      return (path: path, container: container);
    case AudioContainer.unknown:
      break;
  }
  try {
    final wrapped = await OggOpus.prepareUpload(path, isCurrent: isCurrent);
    return (path: wrapped, container: AudioContainer.ogg);
  } on StateError catch (e) {
    if (!isCurrent()) {
      throw const UploadPreparationException('已取消', cancelled: true);
    }
    throw UploadPreparationException(
      e.message == '不支持的音频格式'
          ? '无法准备音频：不支持的音频格式，请导入 M4A、MP3、WAV 或 AAC'
          : '无法准备音频：${e.message}',
    );
  }
}
