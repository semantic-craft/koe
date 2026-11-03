import 'package:flutter/foundation.dart';
import 'meeting_apps.dart';

class MicrophoneSnapshot {
  const MicrophoneSnapshot({
    required this.available,
    required this.users,
    this.device,
  });
  final bool available;
  final List<String> users;
  final String? device;
  factory MicrophoneSnapshot.decode(dynamic value) {
    if (value is! Map ||
        value['available'] != true ||
        value['users'] is! List ||
        value['device'] is! String) {
      return const MicrophoneSnapshot(available: false, users: []);
    }
    return MicrophoneSnapshot(
      available: true,
      users: (value['users'] as List).whereType<String>().toList(),
      device: value['device'] as String,
    );
  }
}

/// Microphone usage is a hint, never a statement that a call has ended.
class MeetingEndWatch extends ChangeNotifier {
  MeetingEndWatch({required this.onStop, DateTime Function()? clock})
    : clock = clock ?? DateTime.now;
  final void Function(String session) onStop;
  final DateTime Function() clock;
  MicrophoneSnapshot _snapshot = const MicrophoneSnapshot(
    available: false,
    users: [],
  );
  DateTime? _seen, _inactive, _deadline;
  String? _session, _app;
  bool _armed = true, _fired = false;
  bool get enabled => _session != null;
  Set<String> get apps => {
    for (final id in _snapshot.users) ?MeetingAppWatch.listed(id),
  };
  bool get available =>
      _snapshot.available &&
      _snapshot.device?.isNotEmpty == true &&
      _seen != null &&
      clock().difference(_seen!) <= const Duration(seconds: 5);
  int? get remainingSeconds => _deadline == null
      ? null
      : (_deadline!.difference(clock()).inMilliseconds / 1000).ceil().clamp(
          0,
          60,
        );
  String get status => !available
      ? '会议检测不可用，自动结束不会触发'
      : apps.length > 1
      ? '多个会议应用正在使用麦克风，自动结束暂停'
      : _deadline != null
      ? '会议可能已结束，$remainingSeconds秒后停止并保存'
      : enabled
      ? '本场自动结束已开启；静默检测不可用'
      : '自动结束默认关闭；静默检测不可用';
  void observe(MicrophoneSnapshot next) {
    final changedDevice = _snapshot.device != next.device;
    _snapshot = next;
    _seen = clock();
    if (!available || changedDevice || apps.length > 1) {
      _inactive = null;
      _deadline = null;
    }
    if (available && apps.contains(_app)) {
      _armed = true;
      _inactive = null;
      _deadline = null;
    }
    notifyListeners();
  }

  bool bind(String session) {
    if (!available || apps.length != 1) return false;
    _session = session;
    _app = apps.single;
    _armed = true;
    _fired = false;
    _inactive = null;
    _deadline = null;
    notifyListeners();
    return true;
  }

  void unbind() {
    _session = null;
    _app = null;
    _inactive = null;
    _deadline = null;
    notifyListeners();
  }

  void cancelCountdown() {
    _deadline = null;
    _inactive = null;
    _armed = false;
    notifyListeners();
  }

  void tick({bool paused = false}) {
    if (!enabled || _fired) return;
    if (!available || paused || apps.length > 1) {
      _inactive = null;
      _deadline = null;
      notifyListeners();
      return;
    }
    if (apps.contains(_app)) {
      _inactive = null;
      _deadline = null;
      _armed = true;
      return;
    }
    if (!_armed) return;
    _inactive ??= clock();
    if (clock().difference(_inactive!) >= const Duration(seconds: 30)) {
      _deadline ??= clock().add(const Duration(seconds: 60));
    }
    final id = _session;
    if (_deadline != null && !clock().isBefore(_deadline!) && id != null) {
      _fired = true;
      onStop(id);
    }
    notifyListeners();
  }
}
