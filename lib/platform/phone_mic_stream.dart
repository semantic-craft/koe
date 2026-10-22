import 'dart:async';
import 'dart:typed_data';

import 'package:record/record.dart';

import 'phone_recorder.dart';

/// The phone microphone as a live stream of 16 kHz mono PCM16 samples, for
/// text-only capture that never writes a recording file of its own.
abstract class PhoneMicStream {
  Future<bool> requestPermission();

  /// Platform-driven changes, such as an incoming call pausing capture.
  Stream<PhoneMicState> get states;

  /// Starts capture; the returned stream ends when capture stops.
  Future<Stream<Uint8List>> start();
  Future<void> stop();
  Future<void> dispose();
}

class DevicePhoneMicStream implements PhoneMicStream {
  final AudioRecorder _recorder = AudioRecorder();

  /// Matches what the streaming speech services expect, so samples go out
  /// unchanged. An interruption pauses capture and resumes it afterwards.
  static const config = RecordConfig(
    encoder: AudioEncoder.pcm16bits,
    sampleRate: 16000,
    numChannels: 1,
    audioInterruption: AudioInterruptionMode.pauseResume,
  );

  @override
  Future<bool> requestPermission() => _recorder.hasPermission();

  @override
  Stream<PhoneMicState> get states => _recorder.onStateChanged().map(
    (state) => switch (state) {
      RecordState.record => PhoneMicState.recording,
      RecordState.pause => PhoneMicState.paused,
      RecordState.stop => PhoneMicState.stopped,
    },
  );

  @override
  Future<Stream<Uint8List>> start() => _recorder.startStream(config);

  @override
  Future<void> stop() async {
    await _recorder.stop();
  }

  @override
  Future<void> dispose() => _recorder.dispose();
}
