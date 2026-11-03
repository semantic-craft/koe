import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../state/atomic_file.dart';
import '../state/live_segments.dart';
import '../ai/cloud_stt_stream.dart' show speechRequestId;
import 'dual_recording_text.dart';
import 'phone_recorder.dart';

/// The ordinary microphone path remains the fallback on older Macs.
class MacDualRecorder
    implements PhoneRecorder, PhoneMicInputs, PhoneMicLevels, PhoneDiskSpace {
  MacDualRecorder({
    PhoneRecorder? microphone,
    MethodChannel? channel,
    Stream<dynamic>? events,
  }) : _microphone = microphone ?? DevicePhoneRecorder(),
       _channel =
           channel ??
           const MethodChannel('com.semanticcraft.koe/dual_recording'),
       _nativeEvents =
           events ??
           const EventChannel(
             'com.semanticcraft.koe/dual_recording/events',
           ).receiveBroadcastStream();
  final PhoneRecorder _microphone;
  final MethodChannel _channel;
  final Stream<dynamic> _nativeEvents;
  final _states = StreamController<PhoneMicState>.broadcast();
  final _levels = StreamController<double>.broadcast();
  final view = ValueNotifier<DualRecordingView>(const DualRecordingView());
  final _text = DualRecordingText();
  StreamSubscription<dynamic>? _events;
  StreamSubscription<PhoneMicState>? _fallbackStates;
  StreamSubscription<double>? _fallbackLevels;
  bool enabled = false;
  String sourceLanguage = 'zh-CN';
  String? _sessionId;
  LiveSegmentCollector? _confirmed;
  bool _native = false;
  bool _started = false;
  String? _path;
  MicInput? _input;
  Future<void> _writes = Future.value();
  static String systemPath(String path) => '$path.system.wav';
  static String textPath(String path) => '$path.dual.txt';

  @override
  Future<bool> requestPermission() => _microphone.requestPermission();
  @override
  Stream<PhoneMicState> get states => _states.stream;
  @override
  Stream<double> levels(Duration interval) => _levels.stream;
  @override
  Future<List<MicInput>> inputs() => (_microphone as PhoneMicInputs).inputs();
  @override
  void useInput(MicInput? input) {
    _input = input;
    (_microphone as PhoneMicInputs).useInput(input);
  }

  @override
  Future<int?> availableSpace(String path) =>
      (_microphone as PhoneDiskSpace).availableSpace(path);
  @override
  Future<void> start(String path) async {
    _path = path;
    _sessionId = speechRequestId();
    _confirmed = LiveSegmentCollector(_sessionId!);
    _text.clear();
    view.value = const DualRecordingView();
    _native = enabled && await _channel.invokeMethod<bool>('supported') == true;
    if (!_native) {
      if (enabled) {
        view.value = const DualRecordingView(
          notice: '此 Mac 需要 macOS 14.2 或更新版本；本次仅录麦克风',
        );
      }
      _fallbackStates ??= _microphone.states.listen(_states.add);
      _fallbackLevels ??= (_microphone as PhoneMicLevels)
          .levels(const Duration(milliseconds: 100))
          .listen(_levels.add);
      await _microphone.start(path);
      _started = true;
      return;
    }
    _events ??= _nativeEvents.listen(
      _event,
      onError: (Object error) {
        view.value = view.value.copyWith(notice: '双路录音状态读取失败：$error');
      },
    );
    await _channel.invokeMethod<void>('start', {
      'path': path,
      'session': _sessionId,
      'locale': sourceLanguage == 'auto' ? 'zh-CN' : sourceLanguage,
      'input': _input?.id,
    });
    _started = true;
    view.value = view.value.copyWith(active: true);
    _states.add(PhoneMicState.recording);
  }

  void _event(dynamic raw) {
    if (!_native || raw is! Map) return;
    if (raw['session'] != _sessionId) return;
    final lane = raw['lane'];
    if (raw['level'] case final num level) {
      if (lane == 'microphone') {
        _levels.add(level.toDouble());
      } else {
        view.value = view.value.copyWith(
          systemLevel: ((level + 60) / 60).clamp(0.0, 1.0),
        );
      }
    }
    if (raw['notice'] case final String notice) {
      view.value = lane == 'system'
          ? view.value.copyWith(systemNotice: notice)
          : view.value.copyWith(notice: notice);
    }
    if (raw['speechNotice'] case final String notice) {
      view.value = view.value.copyWith(speechNotice: notice);
    }
    if (raw['text'] case final String text) {
      if (lane is! String ||
          raw['offset'] is! num ||
          raw['requestId'] is! String) {
        return;
      }
      final id = '$lane/${raw['requestId']}';
      final finalAlready = _confirmed!.segments.any((s) => s.id == id);
      if (raw['final'] != true && finalAlready) return;
      _text.update(lane, (raw['offset'] as num).toDouble(), text);
      if (raw['final'] == true) {
        _confirmed!.acceptFinal(
          session: _sessionId!,
          id: id,
          text: text,
          sourceLanguage: raw['sourceLanguage'] as String? ?? sourceLanguage,
          provider: 'Apple',
        );
      }
      view.value = view.value.copyWith(
        text: _text.text,
        segments: _confirmed!.segments,
        stale: _confirmed!.stale,
      );
      final path = _path;
      final snapshot = _text.text;
      if (path != null) {
        _writes = _writes
            .then((_) => writeFileAtomically(File(textPath(path)), snapshot))
            .then<void>((_) {})
            .catchError((Object error) {
              view.value = view.value.copyWith(
                speechNotice: '实时文字暂未写入磁盘；录音原件仍在保存',
              );
            });
      }
    }
    if (raw['error'] case final String error) {
      view.value = view.value.copyWith(notice: error);
    }
    if (raw['stopped'] == true) _states.add(PhoneMicState.stopped);
  }

  @override
  Future<void> pause() async {
    if (!_native) return _microphone.pause();
    await _channel.invokeMethod<void>('pause');
    _states.add(PhoneMicState.paused);
  }

  @override
  Future<void> resume() async {
    if (!_native) return _microphone.resume();
    await _channel.invokeMethod<void>('resume');
    _states.add(PhoneMicState.recording);
  }

  @override
  Future<void> stop() async {
    if (!_started) return;
    try {
      if (!_native) {
        await _microphone.stop();
        return;
      }
      await _channel.invokeMethod<void>('stop');
    } finally {
      _started = false;
      await _writes;
    }
    view.value = view.value.copyWith(active: false);
    _states.add(PhoneMicState.stopped);
  }

  @override
  Future<void> cancel() async {
    if (!_native) {
      try {
        await _microphone.cancel();
      } finally {
        _started = false;
      }
      return;
    }
    final path = _path;
    if (path == null) return;
    // A failed stop/delete must never resurrect a discarded companion lane.
    final marker = File('$path.discarded');
    await marker.writeAsString('discarded');
    try {
      await stop();
    } finally {
      Object? error;
      for (final item in [path, systemPath(path), textPath(path)]) {
        try {
          if (await File(item).exists()) await File(item).delete();
        } catch (failure) {
          error = failure;
        }
      }
      if (error == null && await marker.exists()) await marker.delete();
      if (error != null) throw error;
    }
  }

  @override
  Future<void> dispose() async {
    await stop();
    await _events?.cancel();
    await _fallbackStates?.cancel();
    await _fallbackLevels?.cancel();
    await _microphone.dispose();
    await _states.close();
    await _levels.close();
    view.dispose();
  }
}

class DualRecordingView {
  const DualRecordingView({
    this.active = false,
    this.systemLevel = 0,
    this.notice = '',
    this.systemNotice = '',
    this.speechNotice = '',
    this.text = '',
    this.segments = const [],
    this.stale = false,
  });
  final bool active, stale;
  final List<LiveSegment> segments;
  final double systemLevel;
  final String notice, systemNotice, speechNotice, text;
  DualRecordingView copyWith({
    bool? active,
    double? systemLevel,
    String? notice,
    String? systemNotice,
    String? speechNotice,
    String? text,
    List<LiveSegment>? segments,
    bool? stale,
  }) => DualRecordingView(
    active: active ?? this.active,
    systemLevel: systemLevel ?? this.systemLevel,
    notice: notice ?? this.notice,
    systemNotice: systemNotice ?? this.systemNotice,
    speechNotice: speechNotice ?? this.speechNotice,
    text: text ?? this.text,
    segments: segments ?? this.segments,
    stale: stale ?? this.stale,
  );
}
