import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:opus_codec_dart/opus_codec_dart.dart';

import 'ogg_opus.dart';

/// Decode D3200 fixed 160-B Opus frames → PCM16 LE for low-latency streaming.
///
/// Device stream is bare concatenated frames (see [OggOpus]). Trailing zero
/// padding is stripped before libopus. Output defaults to **16 kHz mono** so
/// chunks can go straight to streaming STT (`sample_rate=16000`).
class OpusPcmDecoder {
  OpusPcmDecoder({this.outputSampleRate = 16000, this.channels = 1});

  /// Decoder / PCM sample rate (8000 / 12000 / 16000 / 24000 / 48000).
  final int outputSampleRate;
  final int channels;

  SimpleOpusDecoder? _decoder;
  bool _initFailed = false;
  int _framesOk = 0;
  int _framesFail = 0;

  /// libopus symbols live in the app process (Apple) or the packaged
  /// `libopus.so` (Android), so the FFI bindings are initialized once.
  static bool _nativeInitialized = false;

  /// Samples per 20 ms channel at [outputSampleRate].
  int get samplesPerFrame =>
      (outputSampleRate * OggOpus.samplesPerFrame) ~/ OggOpus.sampleRate;

  bool get isReady => _decoder != null && !_decoder!.destroyed;
  bool get initFailed => _initFailed;
  int get framesDecoded => _framesOk;
  int get framesFailed => _framesFail;

  /// Ensure native decoder exists. Returns false if libopus unavailable.
  bool ensureStarted() {
    if (isReady) return true;
    if (_initFailed) return false;
    try {
      _ensureNativeLibrary();
      _decoder = SimpleOpusDecoder(
        sampleRate: outputSampleRate,
        channels: channels,
      );
      debugPrint(
        '[OpusPcm] ready rate=$outputSampleRate ch=$channels '
        'frameSamples=$samplesPerFrame opus=${getOpusVersion()}',
      );
      return true;
    } catch (e) {
      _initFailed = true;
      debugPrint('[OpusPcm] create error: $e');
      return false;
    }
  }

  /// Decode one 160-B (or shorter) raw frame → PCM16 LE bytes, or null.
  Uint8List? decodeFrame(Uint8List rawFrame) {
    if (!ensureStarted()) return null;
    final packet = trimOpusPacket(rawFrame);
    if (packet.isEmpty) return null;

    try {
      // The wrapper decodes up to libopus' 120 ms packet maximum internally.
      final pcm = _decoder!.decode(input: packet);
      if (pcm.isEmpty) {
        _framesFail++;
        return null;
      }
      _framesOk++;
      return _pcm16Le(pcm);
    } catch (e) {
      _framesFail++;
      if (_framesFail <= 5 || _framesFail % 50 == 0) {
        debugPrint('[OpusPcm] decode fail #$_framesFail: $e');
      }
      return null;
    }
  }

  /// Decode many raw frames and concatenate PCM.
  Uint8List? decodeFrames(Iterable<Uint8List> frames) {
    final out = BytesBuilder(copy: false);
    for (final f in frames) {
      final pcm = decodeFrame(f);
      if (pcm != null) out.add(pcm);
    }
    if (out.isEmpty) return null;
    return out.toBytes();
  }

  /// Split a raw file of concatenated 160-B frames and decode all.
  Uint8List? decodeRawFileBytes(Uint8List raw) {
    if (raw.isEmpty) return null;
    final frames = <Uint8List>[];
    var o = 0;
    while (o + OggOpus.frameSize <= raw.length) {
      frames.add(Uint8List.sublistView(raw, o, o + OggOpus.frameSize));
      o += OggOpus.frameSize;
    }
    if (o < raw.length) {
      frames.add(Uint8List.sublistView(raw, o));
    }
    return decodeFrames(frames);
  }

  void reset() {
    _decoder?.destroy();
    _decoder = null;
    _initFailed = false;
    _framesOk = 0;
    _framesFail = 0;
  }

  void dispose() {
    _decoder?.destroy();
    _decoder = null;
  }

  /// Strip trailing zero padding used in fixed 160-B transport slices.
  static Uint8List trimOpusPacket(Uint8List f) {
    var n = f.length;
    while (n > 1 && f[n - 1] == 0) {
      n--;
    }
    if (n <= 0) return Uint8List(0);
    return n == f.length ? f : Uint8List.sublistView(f, 0, n);
  }

  /// Load the native library synchronously.
  ///
  /// `opus_codec`'s `load()` is async, but on Koe's targets it only wraps the
  /// same calls below. [ensureStarted] is invoked from the BLE frame callback
  /// and must stay synchronous so live transcription never drops frames.
  static void _ensureNativeLibrary() {
    if (_nativeInitialized) return;
    initOpus(_openNativeOpus());
    _nativeInitialized = true;
  }

  static DynamicLibrary _openNativeOpus() {
    if (Platform.isAndroid) {
      return DynamicLibrary.open('libopus.so');
    }
    if (Platform.isIOS || Platform.isMacOS) {
      return DynamicLibrary.process();
    }
    throw UnsupportedError(
      'Opus decoding is not supported on ${Platform.operatingSystem}',
    );
  }

  /// Test-only: bind an already-loaded libopus so native decoding can be
  /// exercised in `flutter test`, where the app's embedded framework is absent.
  @visibleForTesting
  static void debugUseOpusLibrary(DynamicLibrary library) {
    initOpus(library);
    _nativeInitialized = true;
  }

  /// `opus_codec_dart` returns host-endian Int16 samples; the streaming STT
  /// protocol and WAV writer expect little-endian bytes.
  static Uint8List _pcm16Le(Int16List samples) {
    final bytes = Uint8List(samples.length * 2);
    final view = ByteData.sublistView(bytes);
    for (var i = 0; i < samples.length; i++) {
      view.setInt16(i * 2, samples[i], Endian.little);
    }
    return bytes;
  }
}
