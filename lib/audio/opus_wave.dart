import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import 'ogg_opus.dart';
import 'opus_pcm_decoder.dart';
import '../native/koe_core_ffi.dart';
import '../util/off_ui.dart';
import 'recording_audio.dart';

/// Converts the D3200's raw fixed-size Opus frames to a standard PCM WAV file.
class OpusWave {
  OpusWave._();

  static const sampleRate = 48000;
  static const channels = 1;
  static const bitsPerSample = 16;

  /// Raw files at least this large are decoded on a background isolate.
  static const backgroundThreshold = 256 * 1024;

  static Future<String> convertRawFile(String path) async {
    switch (RecordingAudio.of(path).kind) {
      case RecordingAudioKind.wav:
        return path;
      case RecordingAudioKind.deviceRaw:
        throw StateError('加密的原始文件无法转换');
      case RecordingAudioKind.deviceOpus || RecordingAudioKind.container:
        break;
    }

    final source = File(path);
    if (!await source.exists()) throw StateError('文件不存在：$path');
    final size = await source.length();
    if (size == 0) throw StateError('文件为空');
    if (size < backgroundThreshold) return _convert(path);
    try {
      return await runOffUi(
        () => _convert(path, requireDecoder: true),
        size: size,
        threshold: backgroundThreshold,
        debugName: 'OpusWave.convertRawFile',
      );
    } on _DecoderUnavailable {
      // libopus could not be bound on the background isolate; decode here so
      // the recording still converts, and count it like any other fallback.
      offUiFallbacks++;
      debugPrint('[OffUi] Opus decoder unavailable off the UI isolate');
      return _convert(path);
    }
  }

  static Future<String> _convert(
    String path, {
    bool requireDecoder = false,
  }) async {
    final source = File(path);
    final input = await source.open();
    final prefix = await input.read(12);
    await input.setPosition(0);
    if (OggOpus.isOgg(prefix)) {
      await input.close();
      throw StateError('需要原始 Opus 帧');
    }

    final decoder = OpusPcmDecoder(outputSampleRate: sampleRate);
    if (requireDecoder && !decoder.ensureStarted()) {
      await input.close();
      throw const _DecoderUnavailable();
    }
    final wavPath = RecordingAudio.of(path).convertedWav;
    final partial = File('$wavPath.part');
    final output = await partial.open(mode: FileMode.write);
    var completed = false;
    try {
      await output.writeFrom(_wavHeader(0));
      final pcmBatch = BytesBuilder(copy: false);
      var pcmLength = 0;
      var carry = Uint8List(0);
      while (true) {
        final chunk = await input.read(OggOpus.frameSize * 100);
        if (chunk.isEmpty) {
          if (carry.isNotEmpty) {
            final pcm = decoder.decodeFrame(carry);
            if (pcm != null && pcm.isNotEmpty) {
              pcmBatch.add(pcm);
              pcmLength += pcm.length;
            }
          }
          break;
        }

        final data = carry.isEmpty
            ? chunk
            : (Uint8List(carry.length + chunk.length)
                ..setRange(0, carry.length, carry)
                ..setRange(carry.length, carry.length + chunk.length, chunk));
        final completeLength =
            (data.length ~/ OggOpus.frameSize) * OggOpus.frameSize;
        for (
          var offset = 0;
          offset < completeLength;
          offset += OggOpus.frameSize
        ) {
          final pcm = decoder.decodeFrame(
            Uint8List.sublistView(data, offset, offset + OggOpus.frameSize),
          );
          if (pcm != null && pcm.isNotEmpty) {
            pcmBatch.add(pcm);
            pcmLength += pcm.length;
          }
        }
        carry = completeLength == data.length
            ? Uint8List(0)
            : Uint8List.fromList(data.sublist(completeLength));
        if (pcmBatch.isNotEmpty) {
          await output.writeFrom(pcmBatch.takeBytes());
        }
        await Future<void>.delayed(Duration.zero);
      }
      if (pcmBatch.isNotEmpty) {
        await output.writeFrom(pcmBatch.takeBytes());
      }
      if (pcmLength == 0) throw StateError('Opus 解码失败');
      await output.setPosition(0);
      await output.writeFrom(_wavHeader(pcmLength));
      await output.flush();
      completed = true;
    } finally {
      await input.close();
      await output.close();
      decoder.dispose();
      if (!completed && await partial.exists()) {
        await partial.delete();
      }
    }

    final wav = File(wavPath);
    if (await wav.exists()) await wav.delete();
    await partial.rename(wavPath);
    return wavPath;
  }

  static Uint8List buildWavHeader(int pcmLength) => _wavHeader(pcmLength);

  static Uint8List _wavHeader(int pcmLength) {
    final ffi = KoeCoreFfi.instance;
    if (ffi != null) {
      return ffi.wavHeader(pcmLength);
    }
    final byteRate = sampleRate * channels * bitsPerSample ~/ 8;
    final blockAlign = channels * bitsPerSample ~/ 8;
    final header = ByteData(44);
    _ascii(header, 0, 'RIFF');
    header.setUint32(4, 36 + pcmLength, Endian.little);
    _ascii(header, 8, 'WAVE');
    _ascii(header, 12, 'fmt ');
    header.setUint32(16, 16, Endian.little);
    header.setUint16(20, 1, Endian.little);
    header.setUint16(22, channels, Endian.little);
    header.setUint32(24, sampleRate, Endian.little);
    header.setUint32(28, byteRate, Endian.little);
    header.setUint16(32, blockAlign, Endian.little);
    header.setUint16(34, bitsPerSample, Endian.little);
    _ascii(header, 36, 'data');
    header.setUint32(40, pcmLength, Endian.little);
    return header.buffer.asUint8List();
  }

  static void _ascii(ByteData data, int offset, String value) {
    for (var i = 0; i < value.length; i++) {
      data.setUint8(offset + i, value.codeUnitAt(i));
    }
  }
}

/// Thrown on a background isolate when libopus cannot be bound there.
class _DecoderUnavailable implements Exception {
  const _DecoderUnavailable();
}
