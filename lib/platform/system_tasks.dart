import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../state/context/todo.dart';
import 'android_calendar_tasks.dart';
import 'device_kind.dart';

enum SystemTaskTarget { reminder, event }

/// The system app refused or is unavailable (no permission, unsupported
/// platform). Koe's own record is unaffected.
class SystemTasksUnavailable implements Exception {
  const SystemTasksUnavailable(this.message);
  final String message;

  @override
  String toString() => message;
}

/// Reads and writes the one Reminders/Calendar item Koe created for a todo.
/// Nothing here runs without an explicit user action.
abstract class SystemTasks {
  /// Whether this device has the system app at all. The UI says so instead
  /// of offering an export that can only fail.
  bool supports(SystemTaskTarget target);

  /// Asks for access when not yet decided; false when denied.
  Future<bool> requestAccess(SystemTaskTarget target);

  /// Creates the item, or updates [existingId] in place. Returns its id.
  Future<String> save(
    SystemTaskTarget target, {
    String? existingId,
    required String title,
    DateTime? start,
    DateTime? end,
    bool hasTime = true,
    bool done = false,
    String? notes,
  });

  /// The current values, or null when the item was deleted in the system app.
  Future<SystemSnapshot?> fetch(SystemTaskTarget target, String id);
}

/// EventKit bridge on iOS and macOS (`darwin/SystemTasksBridge.swift`); on
/// Android it hands over to [AndroidCalendarTasks] (Calendar only). Other
/// platforms have no handler: [supports] is false and calls report
/// [SystemTasksUnavailable].
class ChannelSystemTasks implements SystemTasks {
  const ChannelSystemTasks();

  static const SystemTasks _android = AndroidCalendarTasks();

  static bool get _onAndroid =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  @override
  bool supports(SystemTaskTarget target) =>
      _onAndroid ? _android.supports(target) : runsOnApple;

  static const _channel = MethodChannel('com.semanticcraft.koe/system_tasks');

  Future<T?> _call<T>(String method, Map<String, Object?> arguments) async {
    try {
      return await _channel.invokeMethod<T>(method, arguments);
    } on MissingPluginException {
      throw const SystemTasksUnavailable('当前设备暂不支持写入系统提醒事项和日历');
    } on PlatformException catch (error) {
      throw SystemTasksUnavailable(
        error.code == 'denied' ? '没有访问权限，请在系统设置里允许 Koe 访问' : '系统应用暂时不可用，请稍后重试',
      );
    }
  }

  @override
  Future<bool> requestAccess(SystemTaskTarget target) async => _onAndroid
      ? _android.requestAccess(target)
      : await _call<bool>('access', {'target': target.name}) ?? false;

  @override
  Future<String> save(
    SystemTaskTarget target, {
    String? existingId,
    required String title,
    DateTime? start,
    DateTime? end,
    bool hasTime = true,
    bool done = false,
    String? notes,
  }) async {
    if (_onAndroid) {
      return _android.save(
        target,
        existingId: existingId,
        title: title,
        start: start,
        end: end,
        hasTime: hasTime,
        done: done,
        notes: notes,
      );
    }
    final id = await _call<String>('save', {
      'target': target.name,
      'id': ?existingId,
      'title': title,
      'start': ?start?.millisecondsSinceEpoch,
      'end': ?end?.millisecondsSinceEpoch,
      'hasTime': hasTime,
      'done': done,
      'notes': ?notes,
    });
    if (id == null || id.isEmpty) {
      throw const SystemTasksUnavailable('系统应用没有返回条目');
    }
    return id;
  }

  @override
  Future<SystemSnapshot?> fetch(SystemTaskTarget target, String id) async {
    if (_onAndroid) return _android.fetch(target, id);
    final value = await _call<Map>('fetch', {'target': target.name, 'id': id});
    if (value == null) return null;
    DateTime? time(Object? ms) =>
        ms is int ? DateTime.fromMillisecondsSinceEpoch(ms) : null;
    return SystemSnapshot(
      title: value['title'] as String? ?? '',
      start: time(value['start']),
      end: time(value['end']),
      done: value['done'] == true,
    );
  }
}
