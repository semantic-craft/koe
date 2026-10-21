// Shared by the microphone scenarios: the native service's status, leaving
// the screen and locking it, and a tone the phone plays into its own
// microphone so there is sound to record and recognize unattended.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:audio_session/audio_session.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:koe/platform/place_capture.dart';
import 'package:koe/state/recording_library.dart';

const native = MethodChannel('com.anker.anker_recorder/background_sync');

Future<Map<String, Object?>> serviceStatus() async =>
    Map<String, Object?>.from((await native.invokeMapMethod('status'))!);

/// Polls the service until [ready] holds or [within] passes; returns the
/// last status either way, for the caller's expectations.
Future<Map<String, Object?>> serviceStatusWhen(
  bool Function(Map<String, Object?>) ready, {
  Duration within = const Duration(seconds: 10),
}) async {
  final deadline = DateTime.now().add(within);
  var status = await serviceStatus();
  while (!ready(status) && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 200));
    status = await serviceStatus();
  }
  return status;
}

/// Waits in real time: no frames are drawn while Koe is off screen.
Future<void> waitUntil(
  bool Function() done, {
  Duration within = const Duration(seconds: 20),
}) async {
  final deadline = DateTime.now().add(within);
  while (!done() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
}

/// Leaves Koe the way the Home gesture does, then has `scripts/android-check`
/// turn the screen off as the power button does, and waits until it is.
Future<void> leaveAndLockScreen() async {
  expect(await native.invokeMethod<bool>('moveTaskToBack'), isTrue);
  // ignore: avoid_print
  print('KOE_ADB: lock-screen');
  final locked = await serviceStatusWhen(
    (s) => s['screenInteractive'] == false,
    within: const Duration(seconds: 15),
  );
  expect(
    locked['screenInteractive'],
    isFalse,
    reason: 'scripts/android-check did not turn the screen off',
  );
}

/// Turns the screen back on and dismisses a non-secure keyguard, so later
/// scenarios start on screen. android-check does this at the end too.
void wakeScreen() {
  // ignore: avoid_print
  print('KOE_ADB: wake-screen');
}

class NoPlace implements PlaceCapture {
  @override
  Future<RecordingPlace?> capture() async => null;
}

/// A 440 Hz tone looped through the speaker, without taking audio focus
/// (taking it would pause the microphone, as a call does).
class Tone {
  Tone._(this._player, this._file, this._volume);

  final AudioPlayer _player;
  final File _file;
  final int _volume;

  static Future<Tone> play() async {
    final file = File(
      '${(await Directory.systemTemp.createTemp('koe-tone-')).path}/tone.wav',
    );
    await file.writeAsBytes(_toneWav());
    final audio = AndroidAudioManager();
    final volume = await audio.getStreamVolume(AndroidStreamType.music);
    final max = await audio.getStreamMaxVolume(AndroidStreamType.music);
    // About half volume: loud enough to count as speech, not to startle.
    for (var v = volume; v < max ~/ 2; v++) {
      await audio.adjustStreamVolume(
        AndroidStreamType.music,
        AndroidAudioAdjustment.raise,
        AndroidAudioVolumeFlags(0),
      );
    }
    final player = AudioPlayer(handleAudioSessionActivation: false);
    await player.setFilePath(file.path);
    await player.setLoopMode(LoopMode.one);
    unawaited(player.play());
    return Tone._(player, file, volume);
  }

  Future<void> stop() async {
    await _player.dispose();
    final audio = AndroidAudioManager();
    var now = await audio.getStreamVolume(AndroidStreamType.music);
    for (; now > _volume; now--) {
      await audio.adjustStreamVolume(
        AndroidStreamType.music,
        AndroidAudioAdjustment.lower,
        AndroidAudioVolumeFlags(0),
      );
    }
    try {
      await _file.parent.delete(recursive: true);
    } catch (_) {}
  }

  /// Two seconds of a 440 Hz sine at half scale, 16 kHz mono PCM16.
  static Uint8List _toneWav() {
    const rate = 16000;
    const samples = rate * 2;
    final bytes = ByteData(44 + samples * 2);
    void tag(int at, String value) {
      for (var i = 0; i < 4; i++) {
        bytes.setUint8(at + i, value.codeUnitAt(i));
      }
    }

    tag(0, 'RIFF');
    bytes.setUint32(4, 36 + samples * 2, Endian.little);
    tag(8, 'WAVE');
    tag(12, 'fmt ');
    bytes.setUint32(16, 16, Endian.little);
    bytes.setUint16(20, 1, Endian.little);
    bytes.setUint16(22, 1, Endian.little);
    bytes.setUint32(24, rate, Endian.little);
    bytes.setUint32(28, rate * 2, Endian.little);
    bytes.setUint16(32, 2, Endian.little);
    bytes.setUint16(34, 16, Endian.little);
    tag(36, 'data');
    bytes.setUint32(40, samples * 2, Endian.little);
    for (var i = 0; i < samples; i++) {
      final v = 16000 * math.sin(2 * math.pi * 440 * i / rate);
      bytes.setInt16(44 + i * 2, v.round(), Endian.little);
    }
    return bytes.buffer.asUint8List();
  }
}

/// Mean absolute PCM16 level of [pcm], and the share of samples that are
/// exactly zero: Android hands a background app without microphone access
/// digital silence, which room sound never is.
(double level, double zeros) pcmLevel(Uint8List pcm) {
  final view = ByteData.sublistView(pcm);
  final count = pcm.length ~/ 2;
  if (count == 0) return (0, 1);
  var sum = 0;
  var zeros = 0;
  for (var i = 0; i < count; i++) {
    final v = view.getInt16(i * 2, Endian.little);
    if (v == 0) zeros++;
    sum += v < 0 ? -v : v;
  }
  return (sum / count, zeros / count);
}

/// Stands in for the DashScope realtime recognition endpoint on the phone
/// itself, over a real WebSocket: it answers the client's run-task, counts
/// the audio it receives and recognizes a sentence per two seconds of it.
/// No key or account is involved.
class StandInRecognizer {
  StandInRecognizer._(this._server);

  final HttpServer _server;
  int audioBytes = 0;
  final sentences = <String>[];
  int _next = 0;

  /// What the next recognized sentences are tagged with, so the scenario
  /// can tell those heard behind the lock screen.
  String phase = '亮屏';

  Uri get endpoint => Uri.parse(
    'ws://${_server.address.address}:${_server.port}/api-ws/v1/inference',
  );

  static Future<StandInRecognizer> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final recognizer = StandInRecognizer._(server);
    server.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(request);
      recognizer._serve(socket);
    });
    return recognizer;
  }

  void _serve(WebSocket socket) {
    String? task;
    var id = 0;
    var heard = 0;
    void send(String event, [Map<String, Object?>? payload]) => socket.add(
      jsonEncode({
        'header': {'event': event, 'task_id': task},
        'payload': ?payload,
      }),
    );
    socket.listen((data) {
      if (data is String) {
        final header = (jsonDecode(data) as Map)['header'] as Map;
        task = header['task_id'] as String?;
        switch (header['action']) {
          case 'run-task':
            send('task-started');
          case 'finish-task':
            send('task-finished');
            unawaited(socket.close());
        }
        return;
      }
      final bytes = (data as List<int>).length;
      audioBytes += bytes;
      heard += bytes;
      while (heard >= 64000) {
        heard -= 64000;
        final text = '$phase第${++_next}句。';
        sentences.add(text);
        send('result-generated', {
          'output': {
            'sentence': {
              'sentence_id': id++,
              'text': text,
              'sentence_end': true,
            },
          },
        });
      }
    });
  }

  Future<void> close() => _server.close(force: true);
}
