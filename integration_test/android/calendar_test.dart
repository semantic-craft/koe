// Android calendar scenario: Koe's system tasks write one test event into the
// Pixel's default calendar, read it back, update it in place, and see it as
// gone once deleted. Only the event created here is touched. Run with
// `scripts/android-check`, which grants READ/WRITE_CALENDAR first.
import 'package:device_calendar_plus/device_calendar_plus.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:koe/platform/calendar_meetings.dart';
import 'package:koe/platform/system_tasks.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const systemTasksChannel = MethodChannel('com.semanticcraft.koe/system_tasks');

  testWidgets('writes, reads back and loses a test calendar event', (
    tester,
  ) async {
    const tasks = ChannelSystemTasks();
    const event = SystemTaskTarget.event;
    expect(tasks.supports(event), isTrue);
    expect(tasks.supports(SystemTaskTarget.reminder), isFalse);
    expect(await tasks.requestAccess(event), isTrue);

    // A minute-aligned slot a year out, so it never sits among real plans.
    final now = DateTime.now();
    final start = DateTime(now.year + 1, now.month, now.day, 9, now.minute);
    final title = 'Koe 测试事件 ${now.millisecondsSinceEpoch}';
    final id = await tasks.save(
      event,
      title: title,
      start: start,
      end: start.add(const Duration(minutes: 30)),
      notes: '来自 Koe 真机验收，会自动删除',
    );
    var deleted = false;
    addTearDown(() async {
      if (!deleted) await DeviceCalendar.instance.deleteEvent(instanceId: id);
    });

    final read = await tasks.fetch(event, id);
    expect(read?.title, title);
    expect(read?.start, start);
    expect(read?.end, start.add(const Duration(minutes: 30)));

    // Verify phone calendar meeting discovery & reminder scheduling (#373) on
    // the real Android CalendarContract and KoePlatformPlugin.
    const meetings = ChannelCalendarMeetings();
    expect(await meetings.requestAccess(), isTrue);
    final upcoming = await meetings.upcomingMeetings(
      start.subtract(const Duration(minutes: 5)),
      start.add(const Duration(hours: 1)),
    );
    final matched = upcoming.where((m) => m.title == title).toList();
    expect(matched, hasLength(1));
    final named = await meetings.meetingAt(
      start.subtract(const Duration(minutes: 2)),
    );
    expect(named?.title, title);

    // 1. Scheduling a future meeting registers a real OS PendingIntent alarm;
    //    clearing reminders removes the scheduled alarm.
    await meetings.syncPhoneReminders(
      matched,
      now: start.subtract(const Duration(minutes: 2)),
    );
    final statusWithAlarm = Map<String, Object?>.from(
      (await systemTasksChannel.invokeMapMethod('meetingReminderStatus'))!,
    );
    expect(statusWithAlarm['scheduledIds'], [matched.single.id]);

    await meetings.syncPhoneReminders(const [], now: start);
    final statusCleared = Map<String, Object?>.from(
      (await systemTasksChannel.invokeMapMethod('meetingReminderStatus'))!,
    );
    expect(statusCleared['scheduledIds'], isEmpty);

    // 2. Scheduling a meeting at its start instant posts the system reminder
    //    notification in NotificationManager.
    await meetings.syncPhoneReminders(matched, now: start);
    final statusPosted = Map<String, Object?>.from(
      (await systemTasksChannel.invokeMapMethod('meetingReminderStatus'))!,
    );
    expect(statusPosted['postedTitles'], contains('「$title」开始了'));
    await systemTasksChannel.invokeMethod<void>(
      'clearMeetingReminderNotifications',
    );

    final later = start.add(const Duration(hours: 2));
    expect(
      await tasks.save(
        event,
        existingId: id,
        title: '$title 改',
        start: later,
        end: read?.end,
      ),
      id,
    );
    final moved = await tasks.fetch(event, id);
    expect(moved?.title, '$title 改');
    expect(moved?.start, later);
    expect(moved?.end, later.add(const Duration(minutes: 30)));

    await DeviceCalendar.instance.deleteEvent(instanceId: id);
    deleted = true;
    expect(await tasks.fetch(event, id), isNull);
    await expectLater(
      tasks.save(event, existingId: id, title: title, start: start),
      throwsA(isA<SystemTasksUnavailable>()),
    );
  });
}
