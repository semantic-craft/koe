import 'package:device_calendar_plus/device_calendar_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:koe/platform/android_calendar_tasks.dart';
import 'package:koe/platform/system_tasks.dart';
import 'package:koe/state/context/context_item.dart';
import 'package:koe/state/context/todo_store.dart';
import 'package:koe/state/context/todo_system_sync.dart';

/// An in-memory CalendarContract behind device_calendar_plus. Like the real
/// plugin, `getEvent` reads a deleted event as null (DELETED rows skipped).
class _Calendar implements DeviceCalendar {
  _Calendar({this.status = CalendarPermissionStatus.granted});

  CalendarPermissionStatus status;
  final Map<String, Event> events = {};
  var _next = 0;

  @override
  Future<CalendarPermissionStatus> requestPermissions({
    CalendarAccessLevel level = CalendarAccessLevel.full,
  }) async => status;

  void _guard() {
    if (status != CalendarPermissionStatus.granted) {
      throw const DeviceCalendarException(
        errorCode: DeviceCalendarError.permissionDenied,
        message: 'denied',
      );
    }
  }

  Event _event(
    String id,
    String title,
    DateTime start,
    DateTime end, [
    String? description,
  ]) => Event(
    eventId: id,
    instanceId: id,
    calendarId: '1',
    title: title,
    description: description,
    startDate: start,
    endDate: end,
    isAllDay: false,
    availability: EventAvailability.busy,
    status: EventStatus.confirmed,
    isRecurring: false,
  );

  @override
  Future<String> createEvent({
    String? calendarId,
    required String title,
    required DateTime startDate,
    required DateTime endDate,
    bool isAllDay = false,
    String? description,
    String? location,
    String? url,
    String? timeZone,
    EventAvailability availability = EventAvailability.busy,
    RecurrenceRule? recurrenceRule,
    List<Duration>? reminders,
    EventOptionsAndroid? android,
  }) async {
    _guard();
    final id = '${++_next}';
    events[id] = _event(id, title, startDate, endDate, description);
    return id;
  }

  @override
  Future<Event?> getEvent(String id) async {
    _guard();
    return events[id];
  }

  @override
  Future<void> updateEvent({
    required String instanceId,
    String? title,
    DateTime? startDate,
    DateTime? endDate,
    Patch<String>? description,
    Patch<String>? location,
    Patch<String>? url,
    bool? isAllDay,
    String? timeZone,
    EventAvailability? availability,
    Patch<List<Duration>>? reminders,
    EventUpdateOptionsAndroid? android,
  }) async {
    _guard();
    final old = events[instanceId];
    if (old == null) {
      throw const DeviceCalendarException(
        errorCode: DeviceCalendarError.notFound,
        message: 'gone',
      );
    }
    events[instanceId] = _event(
      instanceId,
      title ?? old.title,
      startDate ?? old.startDate,
      endDate ?? old.endDate,
      old.description,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Todo _todo() => Todo(
  id: 't1',
  kind: TodoKind.mine,
  title: '交季度报告',
  source: const ContextSource(recordingKey: 'r1'),
  quote: '周五前把季度报告交了',
  createdAt: DateTime(2026, 10, 20),
  updatedAt: DateTime(2026, 10, 20),
);

void main() {
  test('on Android the default system tasks offer Calendar, not Reminders', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    const tasks = ChannelSystemTasks();
    expect(tasks.supports(SystemTaskTarget.event), isTrue);
    expect(tasks.supports(SystemTaskTarget.reminder), isFalse);
  });

  test(
    'a denied calendar permission explains itself and writes nothing',
    () async {
      final calendar = _Calendar(status: CalendarPermissionStatus.denied);
      final store = TodoStore(inMemory: true);
      await store.put(_todo());
      final sync = TodoSystemSync(
        store,
        AndroidCalendarTasks(calendar: calendar),
      );
      final start = DateTime(2026, 10, 24, 9);

      await expectLater(
        sync.exportToCalendar(
          't1',
          start: start,
          end: start.add(const Duration(hours: 1)),
        ),
        throwsA(
          isA<SystemTasksUnavailable>().having(
            (e) => e.message,
            'message',
            contains('系统设置'),
          ),
        ),
      );
      expect(calendar.events, isEmpty);
      expect(store.todoById('t1')?.calendar, isNull);
    },
  );

  test(
    'an exported event updates in place and a deleted one is let go',
    () async {
      final calendar = _Calendar();
      final store = TodoStore(inMemory: true);
      await store.put(_todo());
      final sync = TodoSystemSync(
        store,
        AndroidCalendarTasks(calendar: calendar),
      );
      final start = DateTime(2026, 10, 24, 9);

      await sync.exportToCalendar(
        't1',
        start: start,
        end: start.add(const Duration(minutes: 30)),
      );
      final id = store.todoById('t1')!.calendar!.externalId;
      expect(calendar.events[id]?.title, '交季度报告');
      expect(calendar.events[id]?.description, contains('周五前把季度报告交了'));

      // Renamed and moved in Koe → the same event follows, keeping its length.
      final later = DateTime(2026, 10, 25, 14);
      await store.put(
        store.todoById('t1')!.copyWith(title: '交季度报告终稿', due: later),
      );
      await sync.pushLinks('t1');
      expect(calendar.events.keys, [id]);
      expect(calendar.events[id]?.title, '交季度报告终稿');
      expect(calendar.events[id]?.startDate, later);
      expect(
        calendar.events[id]?.endDate,
        later.add(const Duration(minutes: 30)),
      );

      // Deleted in the calendar → only the link goes, the todo stays.
      calendar.events.remove(id);
      await sync.syncAll();
      expect(store.todoById('t1')?.calendar, isNull);
      expect(store.todoById('t1')?.title, '交季度报告终稿');
      expect(sync.notice, contains('已删除'));
      expect(calendar.events, isEmpty);
    },
  );
}
