import 'package:device_calendar_plus/device_calendar_plus.dart';
import 'package:flutter/services.dart';

import '../state/context/todo.dart';
import 'system_tasks.dart';

/// Calendar events on Android through device_calendar_plus (CalendarContract).
/// Android has no Reminders app, so only [SystemTaskTarget.event] exists.
///
/// Mirrors `ios/Runner/SystemTasksBridge.swift`: new events go to the default
/// calendar with Koe's quote as the description, an update never recreates a
/// deleted event, and a deleted event reads back as null.
class AndroidCalendarTasks implements SystemTasks {
  const AndroidCalendarTasks({DeviceCalendar? calendar}) : _injected = calendar;

  final DeviceCalendar? _injected;
  DeviceCalendar get _calendar => _injected ?? DeviceCalendar.instance;

  static const _unsupported = SystemTasksUnavailable('此设备没有系统提醒事项');
  static const _denied = SystemTasksUnavailable('没有访问日历的权限，请在系统设置里允许 Koe 访问日历');
  static const _deleted = SystemTasksUnavailable('日历里的事件已删除');

  @override
  bool supports(SystemTaskTarget target) => target == SystemTaskTarget.event;

  Future<T> _call<T>(Future<T> Function() run) async {
    try {
      return await run();
    } on DeviceCalendarException catch (error) {
      throw switch (error.errorCode) {
        DeviceCalendarError.permissionDenied ||
        DeviceCalendarError.permissionsNotDeclared => _denied,
        DeviceCalendarError.notFound => _deleted,
        _ => const SystemTasksUnavailable('日历暂时不可用，请稍后重试'),
      };
    } on PlatformException {
      throw const SystemTasksUnavailable('日历暂时不可用，请稍后重试');
    } on ArgumentError {
      throw const SystemTasksUnavailable('日历没有接受这个时间，请检查开始和结束时间');
    }
  }

  /// Shows the system dialog the first time; after "don't ask again" Android
  /// answers denied without a dialog. Only full access counts: picking the
  /// default calendar and reading events back both need READ_CALENDAR.
  @override
  Future<bool> requestAccess(SystemTaskTarget target) async {
    if (!supports(target)) return false;
    final status = await _call(_calendar.requestPermissions);
    return status == CalendarPermissionStatus.granted;
  }

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
    if (!supports(target)) throw _unsupported;
    if (start == null) throw const SystemTasksUnavailable('日历事件需要开始时间');
    return _call(() async {
      if (existingId == null) {
        return _calendar.createEvent(
          title: title,
          startDate: start,
          endDate: end ?? start.add(const Duration(hours: 1)),
          description: notes,
        );
      }
      // A deleted event must not be silently recreated as a duplicate.
      final event = await _calendar.getEvent(existingId);
      if (event == null) throw _deleted;
      // Moving the todo moves the event and keeps its length.
      await _calendar.updateEvent(
        instanceId: existingId,
        title: title,
        startDate: start,
        endDate: start.add(event.endDate.difference(event.startDate)),
      );
      return existingId;
    });
  }

  @override
  Future<SystemSnapshot?> fetch(SystemTaskTarget target, String id) async {
    if (!supports(target)) throw _unsupported;
    final event = await _call(() => _calendar.getEvent(id));
    if (event == null) return null;
    return SystemSnapshot(
      title: event.title,
      start: event.startDate,
      end: event.endDate,
    );
  }
}
