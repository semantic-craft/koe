import 'dart:async';
import 'dart:math';
import 'package:flutter/foundation.dart';
import '../platform/mac_interpreting.dart';
import 'live_minutes_store.dart';

enum InterpretingPhase {
  off,
  ready,
  preparing,
  capturing,
  recognizing,
  translating,
  synthesizing,
  speaking,
  error,
}

typedef InterpretTranslation =
    Future<String> Function(
      String source,
      Future<void> abort,
      bool Function() current,
    );

class MacInterpretingState extends ChangeNotifier {
  MacInterpretingState({
    required this.bridge,
    required this.store,
    required this.translate,
    required this.configuration,
  });
  final MacInterpreting bridge;
  final LiveMinutesStore store;
  final InterpretTranslation translate;
  final String Function() configuration;
  StreamSubscription<Map<String, dynamic>>? _subscription;
  InterpretingPhase phase = InterpretingPhase.off;
  String source = '',
      translation = '',
      message = '',
      sourceLanguage = 'zh-CN',
      targetLanguage = 'en';
  String _session = '', _token = '', _fingerprint = '';
  String? _heldBy;
  int _generation = 0;
  bool enabled = false, autoInput = false, _disposed = false, _restored = false;
  Completer<void>? _abort;
  Future<void>? _enabling;
  bool get busy => ![
    InterpretingPhase.off,
    InterpretingPhase.ready,
    InterpretingPhase.error,
  ].contains(phase);
  static String _id() {
    final r = Random.secure();
    return List.generate(
      16,
      (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }

  Map<String, dynamic> get _args => {'session': _session, 'token': _token};
  void _show(InterpretingPhase value) {
    phase = value;
    if (!_disposed) notifyListeners();
  }

  Future<void> restore() async {
    if (_restored) return;
    final value = await store.read('interpreting/latest');
    if (value != null) {
      if (value['schemaVersion'] != 1) throw StateError('不支持的同传记录版本，已保留原记录');
      source = value['source'] as String? ?? '';
      translation = value['translation'] as String? ?? '';
      message = '上次结果仅供查看，不会自动重发或重播';
    }
    _restored = true;
    if (!_disposed) notifyListeners();
  }

  Future<void> enable({
    required String input,
    required String output,
    bool automatic = false,
  }) async {
    if (_enabling != null || enabled || _disposed) return;
    final g = ++_generation;
    _session = _id();
    _show(InterpretingPhase.preparing);
    final task = () async {
      try {
        await restore();
        _subscription ??= bridge.events.listen(
          _event,
          onError: (Object _) {
            unawaited(disable().catchError((Object _) {}));
          },
        );
        if (g != _generation) return;
        await bridge.call('enable', {
          ..._args,
          'inputUID': input,
          'outputUID': output,
          'autoInput': automatic,
        });
        if (g != _generation) {
          await bridge.call('disable');
          return;
        }
        enabled = true;
        autoInput = automatic;
        message = '';
        _show(InterpretingPhase.ready);
      } catch (e) {
        if (g == _generation) {
          message = '$e';
          _show(InterpretingPhase.error);
        }
      }
    }();
    _enabling = task;
    try {
      await task;
    } finally {
      _enabling = null;
    }
  }

  Future<void> press({String origin = 'button'}) async {
    if (!enabled || busy || _disposed) return;
    final g = ++_generation;
    _heldBy = origin;
    _token = _id();
    _fingerprint = configuration();
    _abort = Completer<void>();
    source = '';
    translation = '';
    message = '';
    _show(InterpretingPhase.preparing);
    try {
      await bridge.call('begin', {..._args, 'locale': sourceLanguage});
      if (g != _generation) return;
      _show(InterpretingPhase.capturing);
    } catch (e) {
      if (g == _generation) await _fail(e);
    }
  }

  bool _current(int g) =>
      !_disposed &&
      enabled &&
      g == _generation &&
      configuration() == _fingerprint;
  Future<void> release({String origin = 'button'}) async {
    if (_heldBy != origin) return;
    if (phase == InterpretingPhase.preparing) {
      await cancel();
      return;
    }
    if (phase != InterpretingPhase.capturing) return;
    final g = _generation;
    final args = {..._args};
    _show(InterpretingPhase.recognizing);
    try {
      final text = await bridge.call('finish', args);
      if (!_current(g)) {
        if (g == _generation) await _fail(StateError('配置已变化，请重新按住说话'));
        return;
      }
      source = (text as String).trim();
      if (source.isEmpty || source.length > 12000) {
        throw StateError('未识别到有效的短句');
      }
      await _save('pending');
      if (!_current(g)) {
        if (g == _generation) await _fail(StateError('配置已变化，请重新按住说话'));
        return;
      }
      _show(InterpretingPhase.translating);
      final result = await translate(
        source,
        _abort!.future,
        () => _current(g),
      ).timeout(const Duration(seconds: 30));
      if (!_current(g)) {
        if (g == _generation) await _fail(StateError('配置已变化，请重新按住说话'));
        return;
      }
      translation = result.trim();
      if (translation.isEmpty || translation.length > 12000) {
        throw StateError('译文为空或过长');
      }
      await _save('translated');
      if (!_current(g)) {
        if (g == _generation) await _fail(StateError('配置已变化，请重新按住说话'));
        return;
      }
      _show(InterpretingPhase.synthesizing);
      await bridge
          .call('speak', {
            ...args,
            'text': translation,
            'language': targetLanguage,
          })
          .timeout(const Duration(seconds: 125));
      if (!_current(g)) {
        if (g == _generation) await _fail(StateError('配置已变化，请重新按住说话'));
        return;
      }
      await _save('complete');
      if (_current(g)) _show(InterpretingPhase.ready);
    } catch (e) {
      if (g == _generation) await _fail(e);
    }
  }

  Future<void> _save(String status) => store.write('interpreting/latest', {
    'schemaVersion': 1,
    'kind': 'interpreting',
    'token': _token,
    'status': status,
    'sourceLanguage': sourceLanguage,
    'targetLanguage': targetLanguage,
    'fingerprint': _fingerprint,
    'at': DateTime.now().toIso8601String(),
    'source': source,
    'translation': translation,
  });
  Future<void> _fail(Object e) async {
    message = '$e';
    final next = _generation + 1;
    await cancel();
    if (_generation == next && enabled) _show(InterpretingPhase.error);
  }

  Future<void> cancel({bool notify = true}) async {
    ++_generation;
    _heldBy = null;
    if (_abort?.isCompleted == false) _abort!.complete();
    phase = enabled ? InterpretingPhase.ready : InterpretingPhase.off;
    if (notify) {
      if (!_disposed) notifyListeners();
    } else {
      scheduleMicrotask(() {
        if (!_disposed) notifyListeners();
      });
    }
    try {
      await bridge.call('cancel', _args);
    } catch (e) {
      message = '$e';
    }
  }

  Future<void> disable() async {
    final g = ++_generation;
    _heldBy = null;
    enabled = false;
    if (_abort?.isCompleted == false) _abort!.complete();
    _show(InterpretingPhase.off);
    // Errors propagate to capture coordination: never capture after failed restoration.
    try {
      await bridge.call('disable');
      if (g == _generation) autoInput = false;
    } catch (e) {
      if (g == _generation) {
        message = '$e';
        _show(InterpretingPhase.error);
      }
      rethrow;
    }
  }

  void configurationChanged() {
    if (enabled &&
        busy &&
        _fingerprint.isNotEmpty &&
        configuration() != _fingerprint) {
      message = '配置已变化，本句已取消';
      unawaited(cancel());
    }
  }

  void _event(Map<String, dynamic> event) {
    if (event['session'] != _session || _disposed) return;
    if (event['type'] == 'disabled' || event['type'] == 'error') {
      message = event['message'] as String? ?? '同传已停止，请重新启用';
      unawaited(disable().catchError((Object _) {}));
      return;
    }
    if (event['token'] != _token) return;
    if (event['type'] == 'finishRequested' && _heldBy != null) {
      unawaited(release(origin: _heldBy!));
    }
    if (event['type'] == 'playbackStarted' &&
        phase == InterpretingPhase.synthesizing) {
      _show(InterpretingPhase.speaking);
    }
  }

  @override
  void dispose() {
    _disposed = true;
    ++_generation;
    if (_abort?.isCompleted == false) _abort!.complete();
    unawaited(_subscription?.cancel());
    unawaited(bridge.call('disable').catchError((Object _) => null));
    super.dispose();
  }
}
