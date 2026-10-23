import 'dart:collection';

/// Something about the microphone's level worth telling the user while
/// recording (#401).
enum InputLevelHint {
  /// Only digital silence for over ten seconds: muted, taken by another app,
  /// or the wrong input.
  silent,

  /// Someone speaks, but quietly, for a minute.
  quiet,

  /// The background stays loud for 45 seconds.
  noisy,
}

/// Watches a take's microphone level, one reading per [interval], and decides
/// when to warn. The rules are Shiyin's (`Capture/Recorder.swift:384-401`,
/// MIT): over the last 30 seconds the 90th percentile is the speech level and
/// the 10th the background, judged once a second.
class InputLevelWatch {
  /// [loudness] judges speech and background as well as silence. Leave it off
  /// where the platform reports peak rather than average levels (Android):
  /// peaks sit well above the levels these rules were set for.
  InputLevelWatch({this.loudness = true});

  final bool loudness;

  /// How much audio each reading covers.
  static const interval = Duration(milliseconds: 100);

  /// At or below this a reading is digital silence, not a quiet room: a real
  /// microphone's own noise sits far above it. Shiyin floors levels here too.
  static const silenceFloorDb = -120.0;

  static const _perSecond = 10;
  static const _window = 30 * _perSecond;
  static const _silentReadings = 10 * _perSecond;

  final _levels = ListQueue<double>();
  final _dismissed = <InputLevelHint>{};
  int _readings = 0;
  int _silent = 0;
  int _quietSeconds = 0;
  int _noisySeconds = 0;
  InputLevelHint? _hint;

  /// The warning to show now, or null.
  InputLevelHint? get hint => _hint;

  /// Adds the level of the last [interval] in dBFS and returns whether [hint]
  /// changed.
  bool add(double db) {
    _silent = db <= silenceFloorDb ? _silent + 1 : 0;
    _levels.addLast(db < silenceFloorDb ? silenceFloorDb : db);
    if (_levels.length > _window) _levels.removeFirst();
    if (++_readings % _perSecond != 0) return false;
    if (loudness && _levels.length == _window) {
      final sorted = _levels.toList()..sort();
      final speech = sorted[((_window - 1) * 0.9).floor()];
      final background = sorted[((_window - 1) * 0.1).floor()];
      _noisySeconds = background > -36 ? _noisySeconds + 1 : 0;
      // Speech stands 4 dB above the background; a pause in a quiet room is
      // flat and does not count.
      _quietSeconds = speech < -50 && speech - background >= 4
          ? _quietSeconds + 1
          : 0;
    }
    final next = _silent > _silentReadings
        ? InputLevelHint.silent
        : _quietSeconds >= 60
        ? InputLevelHint.quiet
        : _noisySeconds >= 45
        ? InputLevelHint.noisy
        : null;
    final shown = _dismissed.contains(next) ? null : next;
    if (shown == _hint) return false;
    _hint = shown;
    return true;
  }

  /// Hides the current warning for the rest of the take.
  void dismiss() {
    final shown = _hint;
    if (shown == null) return;
    _dismissed.add(shown);
    _hint = null;
  }

  /// Starts judging afresh, as after a pause; dismissed warnings stay hidden.
  void restart() {
    _levels.clear();
    _readings = 0;
    _silent = 0;
    _quietSeconds = 0;
    _noisySeconds = 0;
    _hint = null;
  }
}
