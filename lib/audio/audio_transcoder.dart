import 'dart:io';

import 'package:flutter/services.dart';

import 'ogg_opus.dart';

/// Containers Koe can tell apart from the first bytes of a file.
enum AudioContainer {
  wav,
  ogg,
  mp3,

  /// MP4 family (m4a, mp4, mov) — imported AAC/ALAC audio.
  mp4,

  /// AAC in ADTS frames (`.aac`).
  adts,
  flac,
  unknown;

  static AudioContainer sniff(List<int> h) {
    if (OggOpus.isWav(h)) return wav;
    if (OggOpus.isOgg(h)) return ogg;
    if (h.length >= 8 &&
        h[4] == 0x66 &&
        h[5] == 0x74 &&
        h[6] == 0x79 &&
        h[7] == 0x70) {
      return mp4;
    }
    if (h.length >= 4 &&
        h[0] == 0x66 &&
        h[1] == 0x4C &&
        h[2] == 0x61 &&
        h[3] == 0x43) {
      return flac;
    }
    if (h.length >= 3 && h[0] == 0x49 && h[1] == 0x44 && h[2] == 0x33) {
      return mp3; // ID3 tag
    }
    if (h.length >= 2 && h[0] == 0xFF && (h[1] & 0xE0) == 0xE0) {
      // MPEG frame sync; layer bits 00 mean ADTS AAC instead of MP3.
      return (h[1] & 0x06) == 0 ? adts : mp3;
    }
    return unknown;
  }

  static Future<AudioContainer> read(String path) async {
    final input = await File(path).open();
    try {
      return sniff(await input.read(12));
    } finally {
      await input.close();
    }
  }
}

class AudioTranscodeException implements Exception {
  const AudioTranscodeException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Decodes any system-readable audio file into 16 kHz mono PCM16 WAV, the
/// format every Koe speech service accepts.
abstract class AudioTranscoder {
  Future<void> toWav(String input, String output);
}

/// AVFoundation conversion in `darwin/AudioTranscodeBridge.swift`.
class PlatformAudioTranscoder implements AudioTranscoder {
  const PlatformAudioTranscoder([
    this._channel = const MethodChannel(
      'com.semanticcraft.koe/audio_transcode',
    ),
  ]);

  final MethodChannel _channel;

  @override
  Future<void> toWav(String input, String output) async {
    try {
      await _channel.invokeMethod<void>('toWav', {
        'input': input,
        'output': output,
        'sampleRate': 16000,
      });
    } on PlatformException catch (e) {
      throw AudioTranscodeException(e.message ?? '无法转换音频');
    } on MissingPluginException {
      throw const AudioTranscodeException('此设备无法转换音频格式');
    }
  }
}
