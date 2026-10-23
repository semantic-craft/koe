import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart'
    show TargetPlatform, debugPrint, defaultTargetPlatform;
import 'package:record/record.dart';

import '../state/atomic_file.dart';

export '../audio/input_level_watch.dart' show InputLevelHint, InputLevelWatch;

/// What the microphone is doing, as reported by the platform.
enum PhoneMicState { recording, paused, stopped }

/// Isolates the phone microphone behind the controller-facing calls Koe uses.
abstract class PhoneRecorder {
  Future<bool> requestPermission();

  /// Platform-driven changes, such as an incoming call pausing the take.
  Stream<PhoneMicState> get states;

  /// Starts writing a 16-bit PCM WAV file at [path].
  Future<void> start(String path);
  Future<void> pause();
  Future<void> resume();
  Future<void> stop();

  /// Stops and deletes the take.
  Future<void> cancel();
  Future<void> dispose();
}

/// A microphone that reports its input level while it records (#401); the
/// levels are judged by [InputLevelWatch].
abstract interface class PhoneMicLevels {
  /// The input level of each [interval] of the take in dBFS, where 0 is full
  /// scale and digital silence -160.
  Stream<double> levels(Duration interval);
}

/// A microphone the system offers to record from (#402).
class MicInput {
  const MicInput({required this.id, required this.label});

  /// What the system knows the input by; on macOS its Core Audio UID, which
  /// stays the same when it is unplugged and plugged back in.
  final String id;
  final String label;

  /// This input as the record plugin selects it.
  InputDevice get device => InputDevice(id: id, label: label);

  /// The input kept in [file], or null when there is none or it cannot be
  /// read.
  static Future<MicInput?> read(File file) async {
    try {
      if (!await file.exists()) return null;
      final json = jsonDecode(await file.readAsString());
      if (json case {'id': final String id, 'label': final String label}) {
        return MicInput(id: id, label: label);
      }
    } catch (error) {
      debugPrint('[MicInput] read failed: $error');
    }
    return null;
  }

  /// Keeps [input] in [file]; null removes it.
  static Future<void> write(File file, MicInput? input) async {
    if (input == null) {
      if (await file.exists()) await file.delete();
      return;
    }
    await file.parent.create(recursive: true);
    await writeFileAtomically(
      file,
      jsonEncode({'id': input.id, 'label': input.label}),
    );
  }
}

/// A microphone that can record from an input other than the system default
/// (#402).
abstract interface class PhoneMicInputs {
  /// The inputs connected now.
  Future<List<MicInput>> inputs();

  /// Starts the takes that follow from [input]; null is the system default.
  void useInput(MicInput? input);
}

/// The inputs [recorder] can record from, each once.
Future<List<MicInput>> micInputsOf(AudioRecorder recorder) async {
  final seen = <String>{};
  return [
    for (final device in await recorder.listInputDevices())
      if (device.id.isNotEmpty && seen.add(device.id))
        MicInput(id: device.id, label: device.label),
  ];
}

class DevicePhoneRecorder
    implements PhoneRecorder, PhoneMicLevels, PhoneMicInputs {
  DevicePhoneRecorder();

  final AudioRecorder _recorder = AudioRecorder();
  InputDevice? _input;

  /// WAV keeps every sample written before a crash readable; speech-rate mono
  /// keeps an hour near 115 MB.
  ///
  /// A call pauses the take. On Android every short sound that takes audio
  /// focus (a notification, a navigation prompt) also counts as one, so there
  /// the take resumes when focus comes back instead of staying paused behind
  /// the lock screen; a pause the user made is kept by the controller.
  static RecordConfig get config => RecordConfig(
    encoder: AudioEncoder.wav,
    sampleRate: 16000,
    numChannels: 1,
    audioInterruption: defaultTargetPlatform == TargetPlatform.android
        ? AudioInterruptionMode.pauseResume
        : AudioInterruptionMode.pause,
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
  Future<void> start(String path) =>
      _recorder.start(config.copyWith(device: (value: _input)), path: path);

  @override
  Future<List<MicInput>> inputs() => micInputsOf(_recorder);

  @override
  void useInput(MicInput? input) => _input = input?.device;

  /// Apple platforms report the average power of each interval, Android its
  /// peak.
  @override
  Stream<double> levels(Duration interval) => _recorder
      .onAmplitudeChanged(interval)
      .map(
        (amplitude) => amplitude.current.isFinite ? amplitude.current : -160,
      );

  @override
  Future<void> pause() => _recorder.pause();

  @override
  Future<void> resume() => _recorder.resume();

  @override
  Future<void> stop() async {
    await _recorder.stop();
  }

  @override
  Future<void> cancel() => _recorder.cancel();

  @override
  Future<void> dispose() => _recorder.dispose();
}

/// Rewrites the RIFF and data chunk sizes of a PCM WAV file from its actual
/// length, so a take cut off by a crash plays back to its last written sample.
/// Walks the chunk list because platform writers may pad before `data`.
/// Returns false when the file is not a WAV or has no audio after the header.
Future<bool> repairWavSizes(String path) async {
  final raf = await File(path).open(mode: FileMode.append);
  try {
    final length = await raf.length();
    await raf.setPosition(0);
    final head = await raf.read(length < 16384 ? length : 16384);
    if (head.length < 12) return false;
    final view = ByteData.sublistView(head);
    String tag(int at) => String.fromCharCodes(head.sublist(at, at + 4));
    if (tag(0) != 'RIFF' || tag(8) != 'WAVE') return false;
    var offset = 12;
    while (offset + 8 <= head.length) {
      if (tag(offset) == 'data') {
        final dataStart = offset + 8;
        if (length <= dataStart) return false;
        await _writeUint32(raf, 4, length - 8);
        await _writeUint32(raf, offset + 4, length - dataStart);
        await raf.flush();
        return true;
      }
      final size = view.getUint32(offset + 4, Endian.little);
      offset += 8 + size + (size.isOdd ? 1 : 0);
    }
    return false;
  } finally {
    await raf.close();
  }
}

Future<void> _writeUint32(RandomAccessFile raf, int at, int value) async {
  final bytes = ByteData(4)..setUint32(0, value, Endian.little);
  await raf.setPosition(at);
  await raf.writeFrom(bytes.buffer.asUint8List());
}
